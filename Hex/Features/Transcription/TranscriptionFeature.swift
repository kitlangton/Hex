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
  enum RecordingSource: Equatable {
    case regular
    case refined
  }

  @ObservableState
  struct State: Equatable {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
	var isRefining: Bool = false
		var isCapturingSelectedTextForRefinement = false
		var refinedHotKeyReleasedWhileCapturingSelection = false
		var selectedTextForRefinement: SelectedTextCapture?
    var isPrewarming: Bool = false
		var forcedRefinementMode: RefinementMode?
		var activeRecordingHotkey: HotKey?
		var activeMinimumKeyTime: Double?
		var activeRecordingSource: RecordingSource?
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
    case hotKeyReleased(RecordingSource)
			case refinedHotKeyPressed
			case selectedTextCaptured(SelectedTextCapture)
			case selectedTextCaptureUnavailable

    // Recording flow
    case startRecording
		case startRefinedRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)
		case hotKeyCancelled(RecordingSource)
		case hotKeyDiscarded(RecordingSource)

    // Transcription result flow
    case transcriptionAudioCaptured(URL, TimeInterval)
    case transcriptionResult(String, URL)
	case refinementResult(String, URL, TimeInterval)
    case transcriptionError(Error, URL?)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    /// Trivial cleanup work that owns no temp WAV (the discard path's removeItem call).
    /// Safe to cancel when a new recording starts.
    case recordingCleanup
    /// Post-stop work that owns a temp WAV and persists it through transcriptPersistence.
    /// Must NOT be cancelled by handleStartRecording or we leak the temp file or lose the row.
    case recordingFinalize
    case transcription
		case selectedTextRefinement
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence
	@Dependency(\.refinement) var refinement

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
        // If we're transcribing or refining, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
		return handleHotKeyPressed(isBusy: state.isTranscribing || state.isRefining)

      case .hotKeyReleased(.regular):
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording, source: .regular, activeSource: state.activeRecordingSource)

		case .hotKeyReleased(.refined):
				if state.isCapturingSelectedTextForRefinement,
					!(state.hexSettings.refinedDoubleTapLockEnabled && state.hexSettings.refinedUseDoubleTapOnly)
				{
					state.refinedHotKeyReleasedWhileCapturingSelection = true
					return .none
				}
				return handleHotKeyReleased(isRecording: state.isRecording, source: .refined, activeSource: state.activeRecordingSource)

			case .refinedHotKeyPressed:
				guard !(state.isTranscribing || state.isRefining) else {
					return handleHotKeyPressed(isBusy: true, startAction: .startRefinedRecording)
				}
				guard state.hexSettings.includeSelectedTextInRefinement else {
					return .send(.startRefinedRecording)
				}
				state.isRefining = false
				state.isCapturingSelectedTextForRefinement = true
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				return .run { [pasteboard] send in
					let selectedText = await pasteboard.captureSelectedText()
					guard !Task.isCancelled else {
						await selectedText?.cancel()
						return
					}
					if let selectedText {
						await send(.selectedTextCaptured(selectedText))
					} else {
						await send(.selectedTextCaptureUnavailable)
					}
				}
				.cancellable(id: CancelID.selectedTextRefinement, cancelInFlight: true)

			case .selectedTextCaptureUnavailable:
				let refinedHotKeyWasReleased = state.refinedHotKeyReleasedWhileCapturingSelection
				state.isCapturingSelectedTextForRefinement = false
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				return refinedHotKeyWasReleased ? .none : .send(.startRefinedRecording)

			case let .selectedTextCaptured(selectedText):
				let refinedHotKeyWasReleased = state.refinedHotKeyReleasedWhileCapturingSelection
				state.isCapturingSelectedTextForRefinement = false
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				guard !refinedHotKeyWasReleased else {
					return .run { _ in await selectedText.cancel() }
				}
				state.selectedTextForRefinement = selectedText
				return .send(.startRefinedRecording)

      // MARK: - Recording Flow

      case .startRecording:
		return handleStartRecording(&state, source: .regular)

		case .startRefinedRecording:
			return handleStartRecording(&state, forcedRefinementMode: .refined, source: .refined)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionAudioCaptured(audioURL, duration):
        state.activeTranscriptionAudioURL = audioURL
        state.activeTranscriptionDuration = duration
        return .none

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

	  case let .refinementResult(result, audioURL, duration):
		return handleRefinementResult(&state, result: result, audioURL: audioURL, duration: duration)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing || state.isRefining || state.isCapturingSelectedTextForRefinement else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)

		case let .hotKeyCancelled(source):
			guard state.activeRecordingSource == source
				|| (source == .refined && state.isCapturingSelectedTextForRefinement)
			else { return .none }
			return handleCancel(&state)

		case let .hotKeyDiscarded(source):
			guard state.activeRecordingSource == source, state.isRecording else { return .none }
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
		var refinedHotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: []))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
		@Shared(.isSettingRefinedHotKey) var isSettingRefinedHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
		if isSettingHotKey || isSettingRefinedHotKey {
          return false
        }

		let refinedHotkey = hexSettings.refinedHotkey
		let shouldMonitorRefinedHotkey = refinedHotkey.map { !$0.conflicts(with: hexSettings.hotkey) } ?? false
		if let refinedHotkey, shouldMonitorRefinedHotkey {
			refinedHotKeyProcessor.hotkey = refinedHotkey
			refinedHotKeyProcessor.doubleTapLockEnabled = hexSettings.refinedDoubleTapLockEnabled
			refinedHotKeyProcessor.useDoubleTapOnly = hexSettings.refinedDoubleTapLockEnabled && hexSettings.refinedUseDoubleTapOnly
			refinedHotKeyProcessor.minimumKeyTime = hexSettings.refinedMinimumKeyTime
		}

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
			if shouldMonitorRefinedHotkey {
				switch refinedHotKeyProcessor.process(keyEvent: keyEvent) {
				case .startRecording:
					Task { await send(.refinedHotKeyPressed) }
					return refinedHotKeyProcessor.useDoubleTapOnly || keyEvent.key != nil
				case .stopRecording:
					Task { await send(.hotKeyReleased(.refined)) }
					return false
				case .cancel:
					Task { await send(.hotKeyCancelled(.refined)) }
					return true
				case .discard:
					Task { await send(.hotKeyDiscarded(.refined)) }
					return false
				case .none:
					break
				}
			}
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
			Task { await send(.hotKeyPressed) }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

		  case .stopRecording:
			Task { await send(.hotKeyReleased(.regular)) }
            return false // or `true` if you want to intercept

		  case .cancel:
			Task { await send(.hotKeyCancelled(.regular)) }
            return true

		  case .discard:
			Task { await send(.hotKeyDiscarded(.regular)) }
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
			if shouldMonitorRefinedHotkey, refinedHotKeyProcessor.state != .idle {
				switch refinedHotKeyProcessor.processMouseClick() {
				case .cancel: Task { await send(.hotKeyCancelled(.refined)) }
				case .discard: Task { await send(.hotKeyDiscarded(.refined)) }
				case .startRecording, .stopRecording, .none: break
				}
				return false
			}
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
		  case .cancel:
			Task { await send(.hotKeyCancelled(.regular)) }
            return false // Don't intercept the click itself
		  case .discard:
			Task { await send(.hotKeyDiscarded(.regular)) }
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
  func handleHotKeyPressed(isBusy: Bool, startAction: Action = .startRecording) -> Effect<Action> {
	// If already transcribing or refining, cancel first. Otherwise start recording immediately.
	guard isBusy else { return .send(startAction) }
    return .concatenate(
      .send(.cancel),
		.send(startAction)
    )
  }

  func handleHotKeyReleased(isRecording: Bool, source: RecordingSource, activeSource: RecordingSource?) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording && source == activeSource ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State, forcedRefinementMode: RefinementMode? = nil, source: RecordingSource) -> Effect<Action> {
    guard !state.isRecording else { return .none }
    guard state.modelBootstrapState.isModelReady else {
		let selectedText = state.selectedTextForRefinement
		state.selectedTextForRefinement = nil
      return .merge(
        .send(.modelMissing),
			.run { _ in
				await selectedText?.cancel()
				soundEffect.play(.cancel)
			}
      )
    }
    state.isRecording = true
		state.forcedRefinementMode = forcedRefinementMode
		state.activeRecordingHotkey = forcedRefinementMode == nil ? state.hexSettings.hotkey : state.hexSettings.refinedHotkey
		state.activeMinimumKeyTime = forcedRefinementMode == nil ? state.hexSettings.minimumKeyTime : state.hexSettings.refinedMinimumKeyTime
		state.activeRecordingSource = source
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
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        await recording.startRecording()
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
			hotkey: state.activeRecordingHotkey ?? state.hexSettings.hotkey,
			minimumKeyTime: state.activeMinimumKeyTime ?? state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
		let minimumKeyTime = state.activeMinimumKeyTime ?? state.hexSettings.minimumKeyTime
		let hotkeyHasKey = (state.activeRecordingHotkey ?? state.hexSettings.hotkey).key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
		let selectedText = state.selectedTextForRefinement
		state.selectedTextForRefinement = nil
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
      // Recording was below minimum duration. If it captured at least 1.0s of audio we still
      // persist it as a cancelled entry so the user can retry; otherwise discard silently
      // (covers accidental modifier-only taps).
      transcriptionFeatureLogger.notice("Short recording per decision \(String(describing: decision)); duration=\(String(format: "%.3f", duration))s")
      let sourceAppBundleID = state.sourceAppBundleID
      let sourceAppName = state.sourceAppName
      let transcriptionHistory = state.$transcriptionHistory
      return .merge(
        .cancel(id: CancelID.recordingStart),
        .run { [duration, sleepManagement] _ in
			await selectedText?.cancel()
          await sleepManagement.allowSleep()
          let stopResult = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          guard case let .captured(url) = stopResult else { return }
          await persistOrDiscard(
            status: .cancelled,
            audioURL: url,
            duration: duration,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            transcriptionHistory: transcriptionHistory
          )
        }
        // Don't cancelInFlight here: a second finalize firing (rare hotkey-release + ESC
        // race) must not abort an already-running persist between recording.stopRecording()
        // and persistOrDiscard completing, or we leak the temp WAV / lose the row.
        .cancellable(id: CancelID.recordingFinalize)
      )
    }

    let model = state.hexSettings.selectedModel
    guard !model.isEmpty else {
      // Defense-in-depth: handleStartRecording already blocks recording when the
      // bootstrap state says no model is ready, but settings can change while a
      // recording is in flight (or the in-memory bootstrap default can race a
      // cold launch). Never hand an empty model name to the transcriber: it
      // silently produces nothing (or junk like "[BLANK_AUDIO]").
      transcriptionFeatureLogger.error("Recording stopped with no transcription model selected; discarding audio")
      return .merge(
        handleDiscard(&state),
        .send(.modelMissing)
      )
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [duration, sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        var unownedAudioURL: URL?
        var capturedAudioURL: URL?
        defer {
          if let unownedAudioURL {
            FileManager.default.removeItemIfExists(at: unownedAudioURL)
          }
        }
        do {
          let stopResult = await recording.stopRecording()
          let capturedURL: URL
          switch stopResult {
          case let .captured(url):
            capturedURL = url
          case .ignored(.staleSession):
            transcriptionFeatureLogger.notice("Ignoring transcription stop superseded by a newer recording session")
            return
          case .ignored(.noActiveRecording):
            transcriptionFeatureLogger.error("Recording stopped without captured audio")
            await send(.transcriptionError(RecordingFailure.noCapturedAudio, nil))
            return
          case let .failed(error):
            transcriptionFeatureLogger.error("Recording stop failed: \(error.localizedDescription)")
            await send(.transcriptionError(error, nil))
            return
          }
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)
          unownedAudioURL = capturedURL
          capturedAudioURL = capturedURL

          // Synchronously plumb the captured URL + accurate duration into state so cancel
          // and ownership-guard paths can see them.
          await send(.transcriptionAudioCaptured(capturedURL, duration))
          unownedAudioURL = nil
          guard !Task.isCancelled else { return }

          // Create transcription options with the selected language
          // Note: cap concurrency to avoid audio I/O overloads on some Macs
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil, // Only auto-detect if no language specified
            chunkingStrategy: .vad,
          )

          let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }

          transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent, privacy: .private) to text length \(result.count)")
          await send(.transcriptionResult(result, capturedURL))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription, privacy: .private)")
          await send(.transcriptionError(error, capturedAudioURL))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
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
      ?? state.recordingStartTime.map { now.timeIntervalSince($0) }
      ?? 0

    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
	  state.activeTranscriptionAudioURL = nil
	  state.activeTranscriptionDuration = nil
	  state.forcedRefinementMode = nil
	  state.activeRecordingHotkey = nil
	  state.activeMinimumKeyTime = nil
	  state.activeRecordingSource = nil
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    let selectedText = state.selectedTextForRefinement

    // A silent selected-text recording still has useful work to do: apply the configured
    // refinement prompt to the captured selection without an extra spoken instruction.
    guard !result.isEmpty || selectedText != nil else {
	  state.activeTranscriptionAudioURL = nil
	  state.activeTranscriptionDuration = nil
	  state.forcedRefinementMode = nil
	  state.activeRecordingHotkey = nil
	  state.activeMinimumKeyTime = nil
	  state.activeRecordingSource = nil
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    if !result.isEmpty {
      transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .private)'")
    }
    let modifiedResult = result.isEmpty ? "" : TranscriptTextProcessor.process(
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
    guard !modifiedResult.isEmpty || selectedText != nil else {
	  state.activeTranscriptionAudioURL = nil
	  state.activeTranscriptionDuration = nil
	  state.forcedRefinementMode = nil
	  state.activeRecordingHotkey = nil
	  state.activeMinimumKeyTime = nil
	  state.activeRecordingSource = nil
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

		// The ordinary hotkey always produces the normal transcription. Only the
		// dedicated refined-transcription hotkey enables downstream AI processing.
		let refinementMode = state.forcedRefinementMode ?? .raw
			let refinementSettings = state.hexSettings
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

	// Refinement is intentionally downstream-only: it receives the existing final transcript
	// text and never participates in capture, transcription, or audio ownership.
	guard refinementMode != .raw else {
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
		state.activeTranscriptionAudioURL = nil
		state.activeTranscriptionDuration = nil
		return finalizeTranscriptEffect(
			result: modifiedResult,
			duration: duration,
			sourceAppBundleID: sourceAppBundleID,
			sourceAppName: sourceAppName,
			audioURL: audioURL,
			transcriptionHistory: transcriptionHistory,
			selectedText: selectedText
		)
	}

	let refinementInput = selectedText?.text ?? modifiedResult
	let spokenInstruction = selectedText == nil ? nil : modifiedResult
	state.isRefining = true
	return .run { [refinement] send in
		do {
				let refinedResult = try await refinement.refine(
					refinementSettings.refinementRequest(
						for: refinementInput,
						mode: refinementMode,
						spokenInstruction: spokenInstruction
					)
				)
			try Task.checkCancellation()
			await send(.refinementResult(refinedResult, audioURL, duration))
		} catch is CancellationError {
			// Cancellation is terminally handled by the existing cancel action, which also owns audio cleanup.
			return
		} catch {
			transcriptionFeatureLogger.warning("Refinement failed: \(error.localizedDescription, privacy: .private)")
			await send(.transcriptionError(error, audioURL))
		}
	}
	.cancellable(id: CancelID.transcription)
  }

  func handleRefinementResult(
	_ state: inout State,
	result: String,
	audioURL: URL,
	duration: TimeInterval
  ) -> Effect<Action> {
	// The audio URL remains owned by the active session while refinement runs. This makes
	// cancellation retain the exact same persistence semantics as a normal transcription.
	guard state.activeTranscriptionAudioURL == audioURL else { return .none }
	state.activeTranscriptionAudioURL = nil
	state.activeTranscriptionDuration = nil
	state.isRefining = false
		state.isCapturingSelectedTextForRefinement = false
		state.refinedHotKeyReleasedWhileCapturingSelection = false
		let selectedText = state.selectedTextForRefinement
		state.selectedTextForRefinement = nil
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil

	let sourceAppBundleID = state.sourceAppBundleID
	let sourceAppName = state.sourceAppName
	let transcriptionHistory = state.$transcriptionHistory
	return finalizeTranscriptEffect(
		result: result,
		duration: duration,
		sourceAppBundleID: sourceAppBundleID,
		sourceAppName: sourceAppName,
		audioURL: audioURL,
		transcriptionHistory: transcriptionHistory,
		selectedText: selectedText
	)
  }

	func finalizeTranscriptEffect(
		result: String,
		duration: TimeInterval,
		sourceAppBundleID: String?,
		sourceAppName: String?,
		audioURL: URL,
		transcriptionHistory: Shared<TranscriptionHistory>,
		selectedText: SelectedTextCapture? = nil
	) -> Effect<Action> {
		.run { _ in
			await finalizeRecordingAndStoreTranscript(
				result: result,
				duration: duration,
				sourceAppBundleID: sourceAppBundleID,
				sourceAppName: sourceAppName,
				audioURL: audioURL,
				transcriptionHistory: transcriptionHistory,
				selectedText: selectedText
			)
		}
		.cancellable(id: CancelID.transcription)
	}

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    // Ownership guard FIRST: drop late-arriving errors that don't belong to the
    // active session. Symmetric optional comparison covers all four nil/non-nil
    // pairings — most importantly it stops a stale nil-URL error from clearing
    // a newer session's activeTranscriptionAudioURL.
    guard state.activeTranscriptionAudioURL == audioURL else {
      return .none
    }
    let duration = state.activeTranscriptionDuration
      ?? state.recordingStartTime.map { now.timeIntervalSince($0) }
      ?? 0
    state.activeTranscriptionAudioURL = nil
    state.activeTranscriptionDuration = nil

    state.isTranscribing = false
	state.isRefining = false
		let selectedText = state.selectedTextForRefinement
		state.selectedTextForRefinement = nil
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
    state.isPrewarming = false
    state.error = error.localizedDescription

    guard let audioURL else {
      return .run { _ in await selectedText?.cancel() }
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { _ in
		await selectedText?.cancel()
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
		transcriptionHistory: Shared<TranscriptionHistory>,
		selectedText: SelectedTextCapture? = nil
  ) async {
    @Shared(.hexSettings) var hexSettings: HexSettings

	let selectionReplacementResult: SelectedTextReplacementResult? = if let selectedText {
		await selectedText.replace(with: result)
	} else {
		nil
	}

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
      FileManager.default.removeItemIfExists(at: audioURL)
    }

	if selectedText == nil {
		await pasteboard.paste(result)
		soundEffect.play(.pasteTranscript)
		return
	}

	switch selectionReplacementResult {
	case .replaced:
		soundEffect.play(.pasteTranscript)
	case .clipboardChanged:
		transcriptionFeatureLogger.notice("Skipped selected-text replacement because the source app or clipboard changed")
	case .pasteFailed:
		transcriptionFeatureLogger.warning("Selected-text replacement failed after refinement")
	case nil:
		break
	}
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
    let wasRecording = state.isRecording
    state.isTranscribing = false
	state.isRefining = false
		state.isCapturingSelectedTextForRefinement = false
		state.refinedHotKeyReleasedWhileCapturingSelection = false
		let selectedText = state.selectedTextForRefinement
		state.selectedTextForRefinement = nil
    state.isRecording = false
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
    state.isPrewarming = false

    // Snapshot any captured transcription metadata before clearing — handleCancel during
    // transcription owns the audio file because the in-flight transcribe effect is being killed.
    let activeURL = state.activeTranscriptionAudioURL
    let activeDuration = state.activeTranscriptionDuration
    state.activeTranscriptionAudioURL = nil
    state.activeTranscriptionDuration = nil

    // Capture the cancel time at action-processing time so the duration reflects
    // when the user pressed cancel, not when the .run block actually executes.
    // Also keeps the timing path test-injectable via @Dependency(\.date.now).
    let cancelTime = now
    let recordingStartTime = state.recordingStartTime
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .merge(
      .cancel(id: CancelID.transcription),
			.cancel(id: CancelID.selectedTextRefinement),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
		await selectedText?.cancel()
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
        } else if wasRecording {
          // Cancel during recording — stop recording to get the temp URL.
          let stopResult = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          guard case let .captured(url) = stopResult else { return }
          let duration = recordingStartTime.map { cancelTime.timeIntervalSince($0) } ?? 0
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
      .cancellable(id: CancelID.recordingFinalize)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false
	state.forcedRefinementMode = nil
	state.activeRecordingHotkey = nil
	state.activeMinimumKeyTime = nil
	state.activeRecordingSource = nil
		let selectedText = state.selectedTextForRefinement
		state.selectedTextForRefinement = nil

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
		await selectedText?.cancel()
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
	if store.isRefining {
	  return .refining
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
