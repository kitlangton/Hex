//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Inject
import SwiftUI
import WhisperKit
import IOKit
import IOKit.pwr_mgt

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
    var assertionID: IOPMAssertionID?
    var lastRecordingURL: URL?
    var perfBadgeText: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
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

    // Cancel entire flow
    case cancel
    case cancelPrewarm

    // Transcription result flow
    case transcriptionResult(String)
    case transcriptionError(Error)
    case setLastRecordingURL(URL)
    case setPerfBadge(String?)
    case setPrewarming(Bool)
  }

  enum CancelID {
    case delayedRecord
    case metering
    case transcription
    case cancellationCleanup
    case prewarm
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.continuousClock) var clock
  @Dependency(\.fileClient) var fileClient
  @Dependency(\.historyStorage) var historyStorage

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          prewarmSelectedModelEffect(&state)
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Then queue up a
        // "startRecording" in 200ms if the user keeps holding the hotkey.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we’re currently recording, then stop. Otherwise, just cancel
        // the delayed “startRecording” effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result):
        return handleTranscriptionResult(&state, result: result)

      case let .transcriptionError(error):
        return handleTranscriptionError(&state, error: error)

      case let .setLastRecordingURL(url):
        state.lastRecordingURL = url
        return .none

      case let .setPerfBadge(text):
        state.perfBadgeText = text
        guard text != nil else { return .none }
        return .run { send in
          try await clock.sleep(for: .seconds(3))
          await send(.setPerfBadge(nil))
        }

      case let .setPrewarming(flag):
        state.isPrewarming = flag
        return .none

      case .cancelPrewarm:
        state.isPrewarming = false
        return .cancel(id: CancelID.prewarm)

      // MARK: - Cancel Entire Flow

      case .cancel:
        // Only cancel if we’re in the middle of recording or transcribing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)
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

      // Register the key event handler and store its UUID for cleanup
      let handlerUUID = keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
        if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
           hotKeyProcessor.state == .idle
        {
          Task { await send(.cancel) }
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        hotKeyProcessor.useDoubleTapOnly = hexSettings.useDoubleTapOnly

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
          return hexSettings.useDoubleTapOnly || keyEvent.key != nil

        case .stopRecording:
          Task { await send(.hotKeyReleased) }
          return false // or `true` if you want to intercept

        case .cancel:
          Task { await send(.cancel) }
          return true

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
      }

      // Use withTaskCancellationHandler to ensure cleanup when the effect is cancelled
      await withTaskCancellationHandler {
        // Keep the effect running indefinitely
        for await _ in AsyncStream<Never>.never {}
      } onCancel: {
        // Clean up the handler when the effect is cancelled
        keyEventMonitor.removeKeyEventHandler(handlerUUID)
      }
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none

    // We wait 200ms before actually sending `.startRecording`
    // so the user can do a quick press => do something else
    // (like a double-tap).
    let delayedStart = Effect.run { send in
      try await Task.sleep(for: .milliseconds(200))
      await send(Action.startRecording)
    }
    .cancellable(id: CancelID.delayedRecord, cancelInFlight: true)

    return .merge(maybeCancel, delayedStart)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    if isRecording {
      // We actually stop if we’re currently recording
      return .send(.stopRecording)
    } else {
      // If not recording yet, just cancel the delayed start
      return .cancel(id: CancelID.delayedRecord)
    }
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = true
    state.recordingStartTime = Date()

    // Prevent system sleep during recording
    if state.hexSettings.preventSystemSleep {
      preventSystemSleep(&state)
    }

    return .run { _ in
      // Play the start sound before the mic begins to avoid capturing it.
      await soundEffect.play(.startRecording)
      await recording.startRecording()
    }
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false

    // Allow system to sleep again by releasing the power management assertion
    // Always call this, even if the setting is off, to ensure we don’t leak assertions
    //  (e.g. if the setting was toggled off mid-recording)
    reallowSystemSleep(&state)

    let durationIsLongEnough: Bool = {
      guard let startTime = state.recordingStartTime else { return false }
      return Date().timeIntervalSince(startTime) > state.hexSettings.minimumKeyTime
    }()

    // Preserve existing behavior: allow short presses to transcribe when the
    // hotkey includes a regular key; otherwise require minimum hold duration.
    guard durationIsLongEnough || state.hexSettings.hotkey.key != nil else {
      // If the user recorded for less than minimumKeyTime, just discard
      print("Recording was too short, discarding")
      return .run { _ in
        _ = await recording.stopRecording()
      }
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let recordingDuration: TimeInterval = {
      guard let startTime = state.recordingStartTime else { return 0 }
      return Date().timeIntervalSince(startTime)
    }()

    return .run { send in
      do {
        // Stop recording first so we don't capture the stop sound in the audio file.
        let audioURL = await recording.stopRecording()
        await soundEffect.play(.stopRecording)
        await send(.setLastRecordingURL(audioURL))

        // Create transcription options with the selected language
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad
        )
        let t0 = Date()
        let result = try await transcription.transcribe(audioURL, model, decodeOptions) { _ in }
        let latency = Date().timeIntervalSince(t0)
        if recordingDuration > 0, latency > 0 {
          let rtf = recordingDuration / latency
          let ms = Int((latency * 1000).rounded())
          let badge = String(format: "RTF %.0fx • %d ms", rtf, ms)
          await send(.setPerfBadge(badge))
        }

        print("Transcribed audio from URL: \(audioURL) to text: \(result)")
        await send(.transcriptionResult(result))
      } catch {
        print("Error transcribing audio: \(error)")
        await send(.transcriptionError(error))
      }
    }
    .cancellable(id: CancelID.transcription)
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func prewarmSelectedModelEffect(_ state: inout State) -> Effect<Action> {
    let model = state.hexSettings.selectedModel
    return .run { send in
      await withTaskCancellationHandler {
        let lowercased = model.lowercased()

        // Skip Parakeet prewarm entirely to avoid network operations
        guard !lowercased.hasPrefix("parakeet-") else {
          await send(.setPrewarming(false))
          return
        }

        // Only prewarm if already downloaded locally to avoid surprise downloads
        if await transcription.isModelDownloaded(model) {
          await send(.setPrewarming(true))
          do {
            // This will only load from disk when the model is already present.
            try await transcription.downloadModel(model) { _ in }
          } catch {
            // Ignore prewarm errors; normal flow will handle on demand
          }
          await send(.setPrewarming(false))
        } else {
          // Ensure indicator is off if nothing to prewarm
          await send(.setPrewarming(false))
        }
      } onCancel: {
        // Synchronous onCancel; no async calls allowed here.
        #if DEBUG
        print("Prewarm cancelled")
        #endif
      }
    }
    .cancellable(id: CancelID.prewarm, cancelInFlight: true)
  }
  func handleTranscriptionResult(
    _ state: inout State,
    result: String
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .none
    }

    // Compute how long we recorded
    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    // Continue with storing the final result in the background
    guard let originalURL = state.lastRecordingURL else {
      return .none
    }
    return finalizeRecordingAndStoreTranscript(
      result: result,
      duration: duration,
      originalURL: originalURL,
      transcriptionHistory: state.$transcriptionHistory
    )
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription

    return .run { _ in
      await soundEffect.play(.cancel)
    }
  }

  /// Persist the transcription according to the selected history storage mode,
  /// optionally moving audio to a permanent location, then paste text and play a sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    originalURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) -> Effect<Action> {
    .run { send in
      do {
        @Shared(.hexSettings) var hexSettings: HexSettings

        // First, determine the final audio path based on storage mode
        let finalAudioURL: URL?
        switch hexSettings.historyStorageMode {
        case .off, .textOnly:
          // Delete the temporary audio file; no audio is stored.
          try? await fileClient.removeItem(originalURL)
          finalAudioURL = nil

        case .textAndAudio:
          // Move audio to a permanent location and reference it in the transcript.
          let recordingsFolder = try await ensureRecordingsDirectory()
          let filename = "\(Date().timeIntervalSince1970).wav"
          let destinationURL = recordingsFolder.appendingPathComponent(filename)
          try await fileClient.moveItem(originalURL, destinationURL)
          finalAudioURL = destinationURL
        }

        // Then, only when history is enabled, create the transcript and persist history
        if hexSettings.historyStorageMode != .off {
          let transcript = Transcript(
            timestamp: Date(),
            text: result,
            audioPath: finalAudioURL,
            duration: duration
          )

          let filesToDelete = appendTranscriptAndTrimHistory(
            transcript: transcript,
            transcriptionHistory: transcriptionHistory,
            maxEntries: hexSettings.maxHistoryEntries
          )
          // Persist history first, then delete any trimmed files. Persist even if nothing to delete.
          try? await historyStorage.persistHistoryAndDeleteFiles(transcriptionHistory, filesToDelete)
        }

        // Paste text (and copy if enabled via pasteWithClipboard)
        await pasteboard.paste(result)
        await soundEffect.play(.pasteTranscript)
      } catch {
        await send(.transcriptionError(error))
      }
    }
  }

  // MARK: - History Helpers

  /// Append a transcript to history, trim to maxEntries if provided, and return any audio files to delete.
  private func appendTranscriptAndTrimHistory(
    transcript: Transcript,
    transcriptionHistory: Shared<TranscriptionHistory>,
    maxEntries: Int?
  ) -> [URL] {
    var filesToDelete: [URL] = []
    transcriptionHistory.withLock { history in
      history.history.insert(transcript, at: 0)

      if let max = maxEntries, max > 0 {
        while history.history.count > max {
          if let removedTranscript = history.history.popLast(),
             let url = removedTranscript.audioPath
          {
            filesToDelete.append(url)
          }
        }
      }
    }
    return filesToDelete
  }


  /// Ensure the permanent recordings directory exists and return its URL.
  private func ensureRecordingsDirectory() async throws -> URL {
    let supportDir = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    let ourAppFolder = supportDir.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
    let recordingsFolder = ourAppFolder.appendingPathComponent("Recordings", isDirectory: true)
    try await fileClient.createDirectory(recordingsFolder, true)
    return recordingsFolder
  }
}

// MARK: - Cancel Handler

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    // Store whether we were recording before clearing the flag
    let wasRecording = state.isRecording

    // Clear all active state flags
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false

    // Clear any stale state that could affect future operations
    state.recordingStartTime = nil
    state.error = nil

    // Release power management assertion if one exists
    // This prevents system sleep leaks if we cancel during recording
    reallowSystemSleep(&state)

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.delayedRecord),
      .cancel(id: CancelID.prewarm),
      .run { _ in
        // Stop the recording if we were in the middle of one
        if wasRecording {
          _ = await recording.stopRecording()
        }
        await soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.cancellationCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - System Sleep Prevention

private extension TranscriptionFeature {
  func preventSystemSleep(_ state: inout State) {
    // Prevent system sleep during recording
    let reasonForActivity = "Hex Voice Recording" as CFString
    var assertionID: IOPMAssertionID = 0
    let success = IOPMAssertionCreateWithName(
      kIOPMAssertionTypeNoDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reasonForActivity,
      &assertionID
    )
    if success == kIOReturnSuccess {
      state.assertionID = assertionID
    }
  }

  func reallowSystemSleep(_ state: inout State) {
    if let assertionID = state.assertionID {
      let releaseSuccess = IOPMAssertionRelease(assertionID)
      if releaseSuccess == kIOReturnSuccess {
        state.assertionID = nil
      }
    }
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
    ZStack(alignment: .topTrailing) {
      TranscriptionIndicatorView(
        status: status,
        meter: store.meter
      )
      if let badge = store.perfBadgeText {
        Text(badge)
          .font(.caption2)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            Capsule().fill(Color.black.opacity(0.7))
          )
          .foregroundColor(.white)
          .padding(8)
      }
    }
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}
