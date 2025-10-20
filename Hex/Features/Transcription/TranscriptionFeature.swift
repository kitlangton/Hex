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

    // Transcription result flow
    case transcriptionResult(String)
    case transcriptionError(Error)
  }

  enum CancelID {
    case delayedRecord
    case metering
    case transcription
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect

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
          startHotKeyMonitoringEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Then queue up a
        // "startRecording" after minimumKeyTime if the user keeps holding the hotkey.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing, minimumKeyTime: state.hexSettings.minimumKeyTime)

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
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option()]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming key events
      keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // If Escape is pressed with no modifiers while idle, let’s treat that as `cancel`.
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
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool, minimumKeyTime: Double) -> Effect<Action> {
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none

    // We wait minimumKeyTime before actually sending `.startRecording`
    // so the user can do a quick press => do something else
    // (like a double-tap).
    let delayedStart = Effect.run { send in
      try await Task.sleep(for: .seconds(minimumKeyTime))
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
      await recording.startRecording()
      await soundEffect.play(.startRecording)
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

      guard (durationIsLongEnough && state.hexSettings.hotkey.key == nil) else {
      // If the user recorded for less than minimumKeyTime, just discard
      // unless the hotkey includes a regular key, in which case, we can assume it was intentional
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

    state.isPrewarming = true
    
    return .run { send in
      do {
        await soundEffect.play(.stopRecording)
        let audioURL = await recording.stopRecording()

        // Create transcription options with the selected language
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad
        )
        
        let result = try await transcription.transcribe(audioURL, model, decodeOptions) { _ in }
        
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
    return finalizeRecordingAndStoreTranscript(
      result: result,
      duration: duration,
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

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) -> Effect<Action> {
    .run { send in
      do {
        let originalURL = await recording.stopRecording()
        
        @Shared(.hexSettings) var hexSettings: HexSettings

        // Check if we should save to history
        if hexSettings.saveTranscriptionHistory {
          // Move the file to a permanent location
          let fm = FileManager.default
          let supportDir = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
          )
          let ourAppFolder = supportDir.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
          let recordingsFolder = ourAppFolder.appendingPathComponent("Recordings", isDirectory: true)
          try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)

          // Create a unique file name
          let filename = "\(Date().timeIntervalSince1970).wav"
          let finalURL = recordingsFolder.appendingPathComponent(filename)

          // Move temp => final
          try fm.moveItem(at: originalURL, to: finalURL)

          // Build a transcript object
          let transcript = Transcript(
            timestamp: Date(),
            text: result,
            audioPath: finalURL,
            duration: duration
          )

          // Append to the in-memory shared history
          transcriptionHistory.withLock { history in
            history.history.insert(transcript, at: 0)
            
            // Trim history if max entries is set
            if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
              while history.history.count > maxEntries {
                if let removedTranscript = history.history.popLast() {
                  // Delete the audio file
                  try? FileManager.default.removeItem(at: removedTranscript.audioPath)
                }
              }
            }
          }
        } else {
          // If not saving history, just delete the temp audio file
          try? FileManager.default.removeItem(at: originalURL)
        }

        // Paste text (and copy if enabled via pasteWithClipboard)
        await pasteboard.paste(result)
        await soundEffect.play(.pasteTranscript)
      } catch {
        await send(.transcriptionError(error))
      }
    }
  }
}

// MARK: - Cancel Handler

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.delayedRecord),
      .run { _ in
        await soundEffect.play(.cancel)
      }
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
