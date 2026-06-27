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

import AVFoundation
import Foundation

final class SessionAudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var captureFile: AVAudioFile?
    private(set) var isRunning = false

    /// Configure the audio session + start the engine. Must be called while the
    /// app is in the foreground; it then continues in the background.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)

        let input = engine.inputNode
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
        isRunning = true
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
        endCapture()
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
