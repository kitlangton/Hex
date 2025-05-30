//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
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
    var isEnhancing: Bool = false // Add this to track when AI enhancement is active
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var assertionID: IOPMAssertionID?
    var pendingTranscription: String? // Store original transcription for fallback
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
    
    // AI Enhancement flow
    case setEnhancingState(Bool)
    case aiEnhancementResult(String)
    case aiEnhancementError(Error)
    case ollamaBecameUnavailable
    case recheckOllamaAvailability
  }

  enum CancelID {
    case delayedRecord
    case metering
    case transcription
    case aiEnhancement
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.aiEnhancement) var aiEnhancement

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
        // Only update state.meter if it's significantly different from the previous value
        // or if we're currently recording (when we need more responsive updates)
        let averageDiff = abs(meter.averagePower - state.meter.averagePower)
        let peakDiff = abs(meter.peakPower - state.meter.peakPower)
        let significantChange = averageDiff > 0.03 || peakDiff > 0.05

        if state.isRecording || significantChange {
          state.meter = meter
        }
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
        
      // MARK: - AI Enhancement Results
      
      case let .setEnhancingState(isEnhancing):
        state.isEnhancing = isEnhancing
        return .none
        
      case let .aiEnhancementResult(result):
        return handleAIEnhancement(&state, result: result)
        
      case let .aiEnhancementError(error):
        // Check if this is an Ollama connectivity error
        let nsError = error as NSError
        if nsError.domain == "AIEnhancementClient" && (nsError.code == -1001 || nsError.localizedDescription.contains("Ollama")) {
          print("AI Enhancement error due to Ollama connectivity: \(error)")
          return .send(.ollamaBecameUnavailable)
        } else {
          // For other errors, we need to:
          // 1. Log the error
          // 2. Disable AI enhancement status 
          // 3. Fall back to the original transcription that produced this action
          print("AI Enhancement error: \(error)")
          
          // In the enhance method, there's a parameter to capture the original transcription
          // We'll modify enhanceWithAI() to store the original transcription for error case
          
          // For now, use the bare minimum error message to inform the user
          state.error = "AI enhancement failed: \(error.localizedDescription). Using original transcription instead."
          
          // Continue with original transcription processing
          return .send(.transcriptionResult(state.pendingTranscription ?? ""))
        }
        
      case .ollamaBecameUnavailable:
        // When Ollama becomes unavailable, recheck availability and handle UI updates
        return .send(.recheckOllamaAvailability)
        
      case .recheckOllamaAvailability:
        // Recheck if Ollama is available and update UI accordingly
        return .run { send in
          let isAvailable = await aiEnhancement.isOllamaAvailable()
          if !isAvailable {
            print("[TranscriptionFeature] Ollama is not available. AI enhancement is disabled.")
            // Update state to show error to the user
            await send(.transcriptionError(NSError(
              domain: "TranscriptionFeature",
              code: -1002,
              userInfo: [NSLocalizedDescriptionKey: "Ollama is not available. AI enhancement is disabled."]
            )))
          }
        }

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
    // Create a separate actor to handle rate limiting safely in Swift 6
    actor MeterRateLimiter {
      private var lastUpdateTime = Date()
      private var lastMeter: Meter? = nil
      
      func shouldUpdate(meter: Meter) -> Bool {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
        
        // Always update if enough time has passed (ensures UI responsiveness)
        if timeSinceLastUpdate >= 0.05 { // Max 20 updates per second
          self.lastUpdateTime = now
          self.lastMeter = meter
          return true
        }
        // Or if there's a significant change from the last meter we actually sent
        else if let last = lastMeter {
          let averageDiff = abs(meter.averagePower - last.averagePower)
          let peakDiff = abs(meter.peakPower - last.peakPower)
          // More responsive threshold for significant changes
          let shouldUpdate = averageDiff > 0.02 || peakDiff > 0.04
          
          if shouldUpdate {
            self.lastUpdateTime = now
            self.lastMeter = meter
          }
          
          return shouldUpdate
        }
        
        self.lastUpdateTime = now
        self.lastMeter = meter
        return true // First update always passes through
      }
    }
    
    return .run { send in
      let rateLimiter = MeterRateLimiter()
      
      for await meter in await recording.observeAudioLevel() {
        // Check if we should send this update
        if await rateLimiter.shouldUpdate(meter: meter) {
          // The Effect.run captures its function as @Sendable, so we're already on an appropriate context
          // for sending actions. ComposableArchitecture handles dispatching to the main thread as needed.
            await send(.audioLevelUpdated(meter))
        }
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
    
    // Extract all required state values to local variables to avoid capturing inout parameter
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let settings = state.hexSettings
    // recordingStartTime captured in handleTranscriptionResult
    
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
        
        let result = try await transcription.transcribe(audioURL, model, decodeOptions, settings) { _ in }
        
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
    // First check if we should use AI enhancement
    if state.hexSettings.useAIEnhancement {
      // Keep state.isTranscribing = true since we're still processing
      
      // Store the original transcription for error handling/fallback
      state.pendingTranscription = result
      
      // Extract values to avoid capturing inout parameter
      let selectedAIModel = state.hexSettings.selectedAIModel
      let promptText = state.hexSettings.aiEnhancementPrompt
      let temperature = state.hexSettings.aiEnhancementTemperature
      
      return enhanceWithAI(
        result: result,
        model: selectedAIModel,
        promptText: promptText,
        temperature: temperature
      )
    } else {
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
  }
  
  // MARK: - AI Enhancement Handlers
  
  // Use AI to enhance the transcription result
  private func enhanceWithAI(
    result: String,
    model: String,
    promptText: String,
    temperature: Double
  ) -> Effect<Action> {
    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .send(.aiEnhancementResult(result)) // Just pass through empty text
    }
    
    let options = EnhancementOptions(
      prompt: promptText,
      temperature: temperature
    )
    
    print("[TranscriptionFeature] Starting AI enhancement with model: \(model)")
    
    // We need to use .send to set the enhancing state through the proper action
    return .merge(
      // First update the state to indicate enhancement is starting
      .send(.setEnhancingState(true)),
      
      // Then run the enhancement
      .run { send in
        do {
          print("[TranscriptionFeature] Calling aiEnhancement.enhance()")
          // Access the raw value directly to avoid argument label issues
          let enhanceMethod = aiEnhancement.enhance
          let enhancedText = try await enhanceMethod(result, model, options) { progress in
            // Optional: Could update UI with progress information here if needed
          }
          print("[TranscriptionFeature] AI enhancement succeeded")
          await send(.aiEnhancementResult(enhancedText))
        } catch {
          print("[TranscriptionFeature] Error enhancing text with AI: \(error)")
          // Properly handle the error through the action system
          await send(.aiEnhancementError(error))
        }
      }
    )
    // Don't make this cancellable to avoid premature cancellation
    // This may have been causing the issue with the enhancement being cancelled
  }
  
  // Handle the AI enhancement result
  private func handleAIEnhancement(
    _ state: inout State,
    result: String
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.isEnhancing = false  // Reset the enhancing state
    state.pendingTranscription = nil  // Clear the pending transcription since enhancement succeeded

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
        transcriptionHistory.withLock {
          $0.history.insert(transcript, at: 0)
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
    state.isEnhancing = false

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.delayedRecord),
      // Don't cancel AI enhancement as it might cause issues with Ollama
      // This creates a UI inconsistency where the UI shows cancellation
      // but enhancement continues in background. We intentionally allow this
      // to prevent issues with Ollama's streaming API and ensure stability.
      // TODO: Consider implementing a safer cancellation approach or state tracking
      // to properly ignore late results after cancellation.
      // .cancel(id: CancelID.aiEnhancement),
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

  var status: TranscriptionIndicatorView.Status {
    if store.isEnhancing {
      return .enhancing 
    } else if store.isTranscribing {
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
  }
}
