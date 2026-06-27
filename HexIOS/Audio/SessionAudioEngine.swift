//
//  SessionAudioEngine.swift
//  HexIOS
//
//  Continuous-capture engine for the Flow Session. Unlike AudioRecorder (one
//  discrete recording), this keeps an AVAudioEngine running for the whole
//  session so the app stays alive in the background (UIBackgroundModes: audio)
//  and the keyboard can trigger snippet captures without re-launching the app.
//
//  Between captures the input is discarded (engine still running → app stays
//  alive). beginCapture() opens a file the tap writes into; endCapture() closes
//  it and returns the URL for transcription.
//
//  Self-healing: iOS deactivates our audio session and stops the engine on
//  interruptions (calls, Siri, other apps), audio route/config changes (common
//  when the user switches apps), and media-services resets. We observe all three
//  and restart the engine so a backgrounded session doesn't silently die — the
//  bug where tapping the keyboard mic "did nothing" and then surfaced a generic
//  ObjC error from transcribing an empty capture (#flow-session-recovery).
//

import AVFoundation
import Foundation
import HexCore
import os

final class SessionAudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var captureFile: AVAudioFile?
    private var observerTokens: [NSObjectProtocol] = []
    /// Intent flag: true between start() and stop(). Distinct from the engine's
    /// real `isRunning` so recovery handlers only fire for a session we *want*
    /// alive, and never fight an explicit stop.
    private var shouldBeRunning = false
    private let log = HexLog.logger(.recording)

    /// The engine's *actual* run state (not just our intent). Callers use this to
    /// detect a session iOS killed out from under us.
    var isRunning: Bool { engine.isRunning }

    /// Configure the audio session + start the engine. Must be called while the
    /// app is in the foreground; it then continues in the background.
    func start() throws {
        installObserversIfNeeded()
        shouldBeRunning = true
        try configureSessionAndStart()
    }

    /// Make sure the engine is genuinely running before a capture. If iOS killed
    /// it while we were backgrounded (interruption/route change we somehow missed),
    /// attempt one restart. Returns whether the engine is live afterward.
    @discardableResult
    func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        guard shouldBeRunning else { return false }
        restart(reason: "ensureRunning (engine was not running)")
        return engine.isRunning
    }

    /// Begin accumulating audio into a fresh file; returns its URL.
    func beginCapture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-session-\(UUID().uuidString).caf")
        let format = engine.inputNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        lock.lock()
        captureFile = file
        lock.unlock()
        return url
    }

    /// Stop accumulating; returns the captured file URL (nil if not capturing).
    @discardableResult
    func endCapture() -> URL? {
        lock.lock()
        let url = captureFile?.url
        captureFile = nil
        lock.unlock()
        return url
    }

    func stop() {
        shouldBeRunning = false
        endCapture()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("Session audio engine stopped")
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Engine setup

    /// Activate the session and (re)install the tap + start the engine. Safe to
    /// call repeatedly — used for both the initial start and recovery, so the tap
    /// is reinstalled with the *current* input format after a route/config change.
    private func configureSessionAndStart() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let file = self.captureFile
            self.lock.unlock()
            try? file?.write(from: buffer)
        }

        engine.prepare()
        try engine.start()
        log.info("Session audio engine started")
    }

    private func restart(reason: String) {
        guard shouldBeRunning else { return }
        do {
            engine.stop()
            try configureSessionAndStart()
            log.info("Session audio engine recovered: \(reason, privacy: .public)")
        } catch {
            // Couldn't recover right now (e.g., an active call). The next mic tap
            // calls ensureRunning() and retries; if that also fails, the session
            // is torn down so the keyboard re-bounces for a fresh one.
            log.error("Session audio engine recovery failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Interruption / route / reset recovery

    private func installObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }
        let nc = NotificationCenter.default
        observerTokens = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                self?.handleInterruption(note)
            },
            // Fires when the engine's I/O config changes (e.g., audio route change
            // when switching apps). The engine stops itself; we must restart it.
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.restart(reason: "engine configuration change")
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                self?.restart(reason: "media services reset")
            },
        ]
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            log.info("Audio session interrupted")
        case .ended:
            // Resume whenever we still intend to be running. The system's
            // .shouldResume hint is advisory; if reactivation fails (e.g. a call
            // is still up) restart() logs and the next tap retries via ensureRunning().
            restart(reason: "interruption ended")
        @unknown default:
            break
        }
    }
}
