//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    /// URL of the audio file currently being transcribed. Set after `recording.stopRecording()`
    /// returns inside `handleStopRecording`'s effect, cleared on every terminal action so a
    /// late-arriving result/error from a cancelled transcription can be detected and dropped.
    var activeTranscriptionAudioURL: URL?
    /// Recording duration captured at stop time (does NOT include transcription latency).
    /// Paired with `activeTranscriptionAudioURL`; both set and cleared together.
    var activeTranscriptionDuration: TimeInterval?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionAudioCaptured(URL, TimeInterval)
    case transcriptionResult(String, URL)
    case transcriptionError(Error, URL?)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingCleanup
    case transcription
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionAudioCaptured(audioURL, duration):
        state.activeTranscriptionAudioURL = audioURL
        state.activeTranscriptionDuration = duration
        return .none

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          // Process the key event
          switch hotKeyProcessor.process(keyEvent: keyEvent) {
          case .startRecording:
            // If double-tap lock is triggered, we start recording immediately
            if hotKeyProcessor.state == .doubleTapLock {
              Task { await send(.startRecording) }
            } else {
              Task { await send(.hotKeyPressed) }
            }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none
    let startRecording = Effect.send(Action.startRecording)
    return .merge(maybeCancel, startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        await recording.startRecording()
      }
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // Recording was below minimum duration. If it captured at least 1.0s of audio we still
      // persist it as a cancelled entry so the user can retry; otherwise discard silently
      // (covers accidental modifier-only taps).
      transcriptionFeatureLogger.notice("Short recording per decision \(String(describing: decision)); duration=\(String(format: "%.3f", duration))s")
      let sourceAppBundleID = state.sourceAppBundleID
      let sourceAppName = state.sourceAppName
      let transcriptionHistory = state.$transcriptionHistory
      return .run { [duration, sleepManagement] _ in
        await sleepManagement.allowSleep()
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        await persistOrDiscard(
          status: .cancelled,
          audioURL: url,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          transcriptionHistory: transcriptionHistory
        )
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .run { [duration, sleepManagement] send in
      // Allow system to sleep again
      await sleepManagement.allowSleep()

      var audioURL: URL?
      do {
        let capturedURL = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        soundEffect.play(.stopRecording)
        audioURL = capturedURL

        // Synchronously plumb the captured URL + accurate duration into state so cancel
        // and ownership-guard paths can see them.
        await send(.transcriptionAudioCaptured(capturedURL, duration))

        // Create transcription options with the selected language
        // Note: cap concurrency to avoid audio I/O overloads on some Macs
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad,
        )

        let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }

        transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
        await send(.transcriptionResult(result, capturedURL))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL
  ) -> Effect<Action> {
    // Ownership guard MUST be first: drop late-arriving results from a cancelled transcription
    // before any state mutation, force-quit detection, empty-result handling, post-processing,
    // or side effects.
    guard state.activeTranscriptionAudioURL == audioURL else {
      return .none
    }
    let duration = state.activeTranscriptionDuration
      ?? state.recordingStartTime.map { Date().timeIntervalSince($0) }
      ?? 0
    state.activeTranscriptionAudioURL = nil
    state.activeTranscriptionDuration = nil

    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // Empty raw text: clean up the temp WAV so we don't leak files for silent recordings.
    guard !result.isEmpty else {
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
      }
    }

    transcriptionFeatureLogger.info("Raw transcription: '\(result)'")
    let modifiedResult = TranscriptTextProcessor.process(
      result,
      settings: state.hexSettings,
      bypassFilters: state.isRemappingScratchpadFocused
    )
    if modifiedResult != result {
      transcriptionFeatureLogger.info("Applied word filters; processed length=\(modifiedResult.count)")
    } else if state.isRemappingScratchpadFocused {
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    }

    // Empty after post-processing: same cleanup as empty raw.
    guard !modifiedResult.isEmpty else {
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
      }
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { _ in
      await finalizeRecordingAndStoreTranscript(
        result: modifiedResult,
        duration: duration,
        sourceAppBundleID: sourceAppBundleID,
        sourceAppName: sourceAppName,
        audioURL: audioURL,
        transcriptionHistory: transcriptionHistory
      )
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    // Ownership guard FIRST when we have a URL: drop late-arriving errors after cancel.
    if let audioURL, state.activeTranscriptionAudioURL != audioURL {
      return .none
    }
    let duration = state.activeTranscriptionDuration
      ?? state.recordingStartTime.map { Date().timeIntervalSince($0) }
      ?? 0
    state.activeTranscriptionAudioURL = nil
    state.activeTranscriptionDuration = nil

    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription

    guard let audioURL else {
      return .none
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { _ in
      await persistOrDiscard(
        status: .failed,
        audioURL: audioURL,
        duration: duration,
        sourceAppBundleID: sourceAppBundleID,
        sourceAppName: sourceAppName,
        transcriptionHistory: transcriptionHistory
      )
    }
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  /// Storage failures are logged but do not block the paste — the transcription succeeded
  /// from the user's perspective and they should still get their text.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      do {
        _ = try await persistHistoryEntry(
          text: result,
          audioURL: audioURL,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          status: .completed,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        // Storage failure on the success path: log, clean up the temp file (still at original
        // location since save threw before move-item completed), but DO NOT mark as failed —
        // the transcription itself succeeded and the user should still get their text.
        transcriptionFeatureLogger.error(
          "Failed to persist completed transcript: \(error.localizedDescription, privacy: .private)"
        )
        try? FileManager.default.removeItem(at: audioURL)
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }

    await pasteboard.paste(result)
    soundEffect.play(.pasteTranscript)
  }

  /// Persist an entry in history (move audio + insert + prune to maxHistoryEntries).
  /// Returns nil if `saveTranscriptionHistory` is disabled (caller is responsible for cleanup).
  /// Throws on storage failure.
  func persistHistoryEntry(
    text: String,
    audioURL: URL,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    status: TranscriptStatus,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws -> Transcript? {
    @Shared(.hexSettings) var hexSettings: HexSettings

    guard hexSettings.saveTranscriptionHistory else { return nil }

    let transcript = try await transcriptPersistence.save(
      text,
      audioURL,
      duration,
      sourceAppBundleID,
      sourceAppName,
      status
    )

    transcriptionHistory.withLock { history in
      history.history.insert(transcript, at: 0)

      if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
        while history.history.count > maxEntries {
          if let removedTranscript = history.history.popLast() {
            Task { [transcriptPersistence] in
              try? await transcriptPersistence.deleteAudio(removedTranscript)
            }
          }
        }
      }
    }
    return transcript
  }

  /// Persist an incomplete recording (cancelled or failed) when duration meets the 1.0s
  /// threshold and history is enabled; otherwise delete the temp WAV. Storage failures
  /// fall back to deleting the temp file so we don't leak.
  func persistOrDiscard(
    status: TranscriptStatus,
    audioURL: URL,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async {
    @Shared(.hexSettings) var hexSettings: HexSettings

    // Floor at the user's minimumKeyTime so high-threshold users don't see sub-threshold
    // recordings persisted, with 1.0s as an absolute lower bound to keep storage bounded
    // against rapid modifier taps from users with very low minimumKeyTime values.
    let meetsMinimumDuration = duration >= max(hexSettings.minimumKeyTime, 1.0)
    let shouldPersist = meetsMinimumDuration
      && hexSettings.saveTranscriptionHistory
      && hexSettings.saveCancelledRecordings

    guard shouldPersist else {
      try? FileManager.default.removeItem(at: audioURL)
      return
    }

    do {
      _ = try await persistHistoryEntry(
        text: "",
        audioURL: audioURL,
        duration: duration,
        sourceAppBundleID: sourceAppBundleID,
        sourceAppName: sourceAppName,
        status: status,
        transcriptionHistory: transcriptionHistory
      )
    } catch {
      transcriptionFeatureLogger.error(
        "Failed to persist incomplete transcript (\(String(describing: status))): \(error.localizedDescription, privacy: .private)"
      )
      try? FileManager.default.removeItem(at: audioURL)
    }
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false

    // Snapshot any captured transcription metadata before clearing — handleCancel during
    // transcription owns the audio file because the in-flight transcribe effect is being killed.
    let activeURL = state.activeTranscriptionAudioURL
    let activeDuration = state.activeTranscriptionDuration
    state.activeTranscriptionAudioURL = nil
    state.activeTranscriptionDuration = nil

    let recordingStartTime = state.recordingStartTime
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .merge(
      .cancel(id: CancelID.transcription),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        soundEffect.play(.cancel)

        if let activeURL {
          // Cancel during transcription — recording was already stopped, persist the captured URL.
          await persistOrDiscard(
            status: .cancelled,
            audioURL: activeURL,
            duration: activeDuration ?? 0,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            transcriptionHistory: transcriptionHistory
          )
        } else {
          // Cancel during recording — stop recording to get the temp URL.
          let url = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
          await persistOrDiscard(
            status: .cancelled,
            audioURL: url,
            duration: duration,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            transcriptionHistory: transcriptionHistory
          )
        }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .run { [sleepManagement] _ in
      // Allow system to sleep again
      await sleepManagement.allowSleep()
      let url = await recording.stopRecording()
      guard !Task.isCancelled else { return }
      try? FileManager.default.removeItem(at: url)
    }
    .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
