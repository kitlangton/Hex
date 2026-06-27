//
//  DictationModel.swift
//  HexIOS
//
//  Observable orchestrator: model loading, mic permission, record → transcribe →
//  history, and the keyboard Flow Session. Transcription uses the shared engine
//  (TranscriptionClient) so iOS gets Whisper + Parakeet, matching macOS.
//

import Dependencies
import Foundation
import HexCore
import Observation
import WhisperKit

struct DictationEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

/// How long a Flow Session stays hot after the last activity (product spec: 5/15/60/never).
enum SessionLength: Int, CaseIterable, Identifiable {
    case five = 5
    case fifteen = 15
    case sixty = 60
    case never = 0

    var id: Int { rawValue }
    /// nil = no timeout ("never").
    var duration: TimeInterval? { self == .never ? nil : TimeInterval(rawValue * 60) }
    var label: String { self == .never ? "Never" : "\(rawValue) min" }
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

    /// Default transcription model. Parakeet v3 (multilingual) matches the macOS
    /// default; the shared engine also supports Whisper sizes (user-selectable later).
    let modelName = ParakeetModel.multilingualV3.identifier

    private(set) var modelState: ModelState = .loading
    /// 0…1 progress of the first-run model download/load (Parakeet is large).
    private(set) var modelProgress: Double = 0
    private(set) var phase: Phase = .idle
    /// Rolling mic input levels (0…1) for the recording waveform.
    private(set) var levels: [CGFloat] = []
    /// When the current in-app note recording started (for the recording modal timer).
    private(set) var recordingStartedAt: Date?
    private(set) var entries: [DictationEntry] = []
    var errorMessage: String?

    /// Set after a keyboard session starts, prompting the user to swipe back to
    /// their app where the keyboard will insert dictated text.
    private(set) var awaitingSwipeBack = false

    /// Whether a continuous Flow Session is active (mic stays hot; keyboard can
    /// dictate without re-bouncing).
    private(set) var sessionActive = false
    private(set) var sessionExpiresAt: Date?

    /// Session auto-ends this long after the last activity (persisted in the App Group).
    var sessionLength: SessionLength = .fifteen {
        didSet { UserDefaults(suiteName: HexAppGroup.identifier)?.set(sessionLength.rawValue, forKey: Self.sessionLengthKey) }
    }
    @ObservationIgnored private static let sessionLengthKey = "hex.sessionLengthMinutes"

    private let recorder = AudioRecorder()
    @ObservationIgnored @Dependency(\.transcription) private var transcription
    private let ipc = KeyboardIPC(appGroupIdentifier: HexAppGroup.identifier)
    private var prepareTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

    private let sessionEngine = SessionAudioEngine()
    private var captureObserverTask: Task<Void, Never>?
    private var captureObserver: DarwinSignalObserver?
    private var sessionTimeoutTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var sessionCaptureURL: URL?

    init() {
        if let raw = UserDefaults(suiteName: HexAppGroup.identifier)?.object(forKey: Self.sessionLengthKey) as? Int,
           let value = SessionLength(rawValue: raw) {
            sessionLength = value
        }
    }

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
            try await transcription.downloadModel(modelName) { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in self?.modelProgress = fraction }
            }
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

    private func startRecording() async {
        guard modelState == .ready else { return }
        guard await recorder.requestPermission() else {
            errorMessage = AudioRecorder.RecorderError.permissionDenied.localizedDescription
            return
        }
        do {
            _ = try recorder.start()
            recordingStartedAt = Date()
            phase = .recording
            startMetering()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Discard the in-progress note recording without transcribing (swipe-up-to-cancel).
    func cancelRecording() {
        guard phase == .recording else { return }
        stopMetering()
        if let url = recorder.stop() { try? FileManager.default.removeItem(at: url) }
        recordingStartedAt = nil
        phase = .idle
    }

    // MARK: - Waveform metering

    private func startMetering() {
        let barCount = 32
        levels = Array(repeating: 0, count: barCount)
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .recording else { break }
                var next = self.levels
                next.removeFirst()
                next.append(self.recorder.level())
                self.levels = next
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        levels = []
    }

    private func stopAndTranscribe() async {
        stopMetering()
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        recordingStartedAt = nil
        phase = .transcribing
        defer { phase = .idle }
        do {
            let text = try await transcription.transcribe(url, modelName, DecodingOptions()) { _ in }
            try? FileManager.default.removeItem(at: url)
            guard !text.isEmpty else { return }
            entries.insert(DictationEntry(text: text, date: Date()), at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
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
            startHeartbeat()
            awaitingSwipeBack = true
        } catch {
            errorMessage = error.localizedDescription
            endSession()
        }
    }

    func endSession() {
        sessionTimeoutTask?.cancel(); sessionTimeoutTask = nil
        captureObserverTask?.cancel(); captureObserverTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        captureObserver = nil
        sessionEngine.stop()
        sessionCaptureURL = nil
        sessionActive = false
        sessionExpiresAt = nil
        publishSessionState(active: false, expiresAt: nil)
    }

    /// Refresh the session heartbeat while the app is genuinely alive, so the
    /// keyboard can detect a crash/suspension (heartbeat goes stale) and bounce
    /// instead of posting capture signals into the void.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.sessionActive else { break }
                self.publishSessionState(active: true, expiresAt: self.sessionExpiresAt, notify: false)
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
            let text = try await transcription.transcribe(url, modelName, DecodingOptions()) { _ in }
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
        sessionActive = true
        sessionTimeoutTask?.cancel()

        guard let duration = sessionLength.duration else {
            // "Never": keep the session hot with no auto-timeout.
            sessionExpiresAt = nil
            sessionTimeoutTask = nil
            publishSessionState(active: true, expiresAt: nil)
            return
        }

        let expires = Date().addingTimeInterval(duration)
        sessionExpiresAt = expires
        publishSessionState(active: true, expiresAt: expires)
        sessionTimeoutTask = Task { [weak self] in
            let seconds = expires.timeIntervalSinceNow
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.endSession()
        }
    }

    private func publishSessionState(active: Bool, expiresAt: Date?, notify: Bool = true) {
        guard let ipc else { return }
        // heartbeat defaults to now in the initializer.
        try? ipc.sessionMailbox.write(DictationSessionState(isActive: active, expiresAt: expiresAt))
        if notify { DarwinSignal.post(.sessionChanged) }
    }
}
