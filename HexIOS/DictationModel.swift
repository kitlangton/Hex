//
//  DictationModel.swift
//  HexIOS
//
//  Observable orchestrator for the prototype: model loading, mic permission,
//  record → transcribe → history. UI-facing state only; the actual work is done
//  by AudioRecorder (main actor) and WhisperTranscriber (its own actor).
//

import Foundation
import HexCore
import Observation

struct DictationEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

@MainActor
@Observable
final class DictationModel {
    enum ModelState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    /// WhisperKit short model name. "base" balances size/accuracy for a first run.
    let modelName = "base"

    private(set) var modelState: ModelState = .loading
    private(set) var phase: Phase = .idle
    private(set) var entries: [DictationEntry] = []
    var errorMessage: String?

    /// True when this dictation was triggered from the keyboard (via the
    /// `hexkb://` bounce); the result is handed back through the App Group
    /// instead of (only) being kept in history.
    private(set) var keyboardMode = false
    /// Set after a keyboard-triggered transcription completes, prompting the
    /// user to swipe back to their app where the keyboard will insert the text.
    private(set) var awaitingSwipeBack = false

    /// Whether a continuous Flow Session is active (mic stays hot; keyboard can
    /// dictate without re-bouncing).
    private(set) var sessionActive = false
    private(set) var sessionExpiresAt: Date?

    /// Session auto-ends this long after the last activity.
    let sessionDuration: TimeInterval = 900

    private let recorder = AudioRecorder()
    private let transcriber = WhisperTranscriber()
    private let ipc = KeyboardIPC(appGroupIdentifier: HexAppGroup.identifier)
    private var prepareTask: Task<Void, Never>?

    private let sessionEngine = SessionAudioEngine()
    private var captureObserverTask: Task<Void, Never>?
    private var captureObserver: DarwinSignalObserver?
    private var sessionTimeoutTask: Task<Void, Never>?
    private var sessionCaptureURL: URL?

    var canRecord: Bool { modelState == .ready && phase != .transcribing }

    var recordButtonTitle: String {
        switch phase {
        case .idle: "Start Dictation"
        case .recording: "Stop"
        case .transcribing: "Transcribing…"
        }
    }

    /// Load the model + request mic permission. Idempotent: callers (the view's
    /// `.task` and the keyboard bounce) share one underlying run, so a cold launch
    /// via `hexkb://` doesn't kick off a second model load.
    func prepare() async {
        if let prepareTask { return await prepareTask.value }
        let task = Task { await self.runPrepare() }
        prepareTask = task
        await task.value
    }

    private func runPrepare() async {
        _ = await recorder.requestPermission()
        do {
            try await transcriber.load(model: modelName)
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func toggleRecording() async {
        switch phase {
        case .idle: await startRecording()
        case .recording: await stopAndTranscribe()
        case .transcribing: break
        }
    }

    /// Entry point for the keyboard bounce (`hexkb://dictate`): start a recording
    /// immediately and remember to route the result back through the App Group.
    func beginKeyboardDictation() async {
        awaitingSwipeBack = false
        keyboardMode = true
        // Cold launch via URL can beat the view's prepare(); ensure the model is ready.
        if modelState != .ready { await prepare() }
        guard modelState == .ready else {
            keyboardMode = false
            return
        }
        if phase == .idle { await startRecording() }
    }

    private func startRecording() async {
        guard modelState == .ready else { return }
        guard await recorder.requestPermission() else {
            errorMessage = AudioRecorder.RecorderError.permissionDenied.localizedDescription
            return
        }
        do {
            _ = try recorder.start()
            phase = .recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopAndTranscribe() async {
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        phase = .transcribing
        defer { phase = .idle }
        do {
            let text = try await transcriber.transcribe(url: url)
            try? FileManager.default.removeItem(at: url)
            guard !text.isEmpty else {
                keyboardMode = false
                return
            }
            entries.insert(DictationEntry(text: text, date: Date()), at: 0)
            if keyboardMode {
                handOffToKeyboard(text)
            }
        } catch {
            errorMessage = error.localizedDescription
            keyboardMode = false
        }
    }

    /// Write the transcript to the App Group mailbox and signal the keyboard,
    /// then prompt the user to swipe back so the keyboard can insert it.
    private func handOffToKeyboard(_ text: String) {
        if let ipc {
            try? ipc.resultMailbox.write(DictationResult(text: text, createdAt: Date()))
            DarwinSignal.post(.resultReady)
        }
        keyboardMode = false
        awaitingSwipeBack = true
    }

    func dismissSwipeBackHint() {
        awaitingSwipeBack = false
    }

    // MARK: - Continuous Flow Session

    /// Entry point for the keyboard's session bounce (`hexkb://startSession`):
    /// start the continuous engine in the foreground, publish session state, and
    /// listen for capture signals from the keyboard. The user then swipes back and
    /// dictates in place — no further bounces until the session ends.
    func startKeyboardSession() async {
        awaitingSwipeBack = false
        if modelState != .ready { await prepare() }
        guard modelState == .ready else { return }
        guard await recorder.requestPermission() else {
            errorMessage = AudioRecorder.RecorderError.permissionDenied.localizedDescription
            return
        }
        do {
            if !sessionEngine.isRunning { try sessionEngine.start() }
            beginObservingCaptures()
            extendSession()
            awaitingSwipeBack = true
        } catch {
            errorMessage = error.localizedDescription
            endSession()
        }
    }

    func endSession() {
        sessionTimeoutTask?.cancel(); sessionTimeoutTask = nil
        captureObserverTask?.cancel(); captureObserverTask = nil
        captureObserver = nil
        sessionEngine.stop()
        sessionCaptureURL = nil
        sessionActive = false
        sessionExpiresAt = nil
        publishSessionState(active: false, expiresAt: nil)
    }

    private func beginObservingCaptures() {
        guard captureObserverTask == nil else { return }
        let observer = DarwinSignalObserver([.captureStart, .captureStop])
        captureObserver = observer
        captureObserverTask = Task { [weak self] in
            for await signal in observer.stream() {
                await self?.handleCapture(signal)
            }
        }
    }

    private func handleCapture(_ signal: IPCSignal) async {
        switch signal {
        case .captureStart:
            guard sessionEngine.isRunning, sessionCaptureURL == nil else { return }
            sessionCaptureURL = try? sessionEngine.beginCapture()
            extendSession()
        case .captureStop:
            guard sessionCaptureURL != nil else { return }
            let url = sessionEngine.endCapture()
            sessionCaptureURL = nil
            if let url { await transcribeSessionSnippet(url) }
        default:
            break
        }
    }

    private func transcribeSessionSnippet(_ url: URL) async {
        do {
            let text = try await transcriber.transcribe(url: url)
            try? FileManager.default.removeItem(at: url)
            guard !text.isEmpty else { return }
            entries.insert(DictationEntry(text: text, date: Date()), at: 0)
            if let ipc {
                try? ipc.resultMailbox.write(DictationResult(text: text, createdAt: Date()))
                DarwinSignal.post(.resultReady)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// (Re)set the inactivity timeout and republish the session state.
    private func extendSession() {
        let expires = Date().addingTimeInterval(sessionDuration)
        sessionActive = true
        sessionExpiresAt = expires
        publishSessionState(active: true, expiresAt: expires)

        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = Task { [weak self] in
            let seconds = expires.timeIntervalSinceNow
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.endSession()
        }
    }

    private func publishSessionState(active: Bool, expiresAt: Date?) {
        guard let ipc else { return }
        try? ipc.sessionMailbox.write(DictationSessionState(isActive: active, expiresAt: expiresAt))
        DarwinSignal.post(.sessionChanged)
    }
}
