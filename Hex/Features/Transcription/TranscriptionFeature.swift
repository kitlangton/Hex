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

extension SharedReaderKey where Self == InMemoryKey<Bool>.Default {
  /// Mirrors `TranscriptionFeature.State.isTranscribing` for hotkey monitor access.
  static var isTranscriptionBusy: Self {
    Self[.inMemory("isTranscriptionBusy"), default: false]
  }
}

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
    var liveTranscript: String = ""
    var sourceAppBundleID: String?
    var sourceAppName: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.isTranscriptionBusy) var isTranscriptionBusy: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

    mutating func setTranscribing(_ value: Bool) {
      isTranscribing = value
      $isTranscriptionBusy.withLock { $0 = value }
    }
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)
    case liveTranscriptUpdated(String)

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
    case transcriptionResult(String, URL, TimeInterval)
    case transcriptionError(Error, URL?)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
    case liveTranscription
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.liveTranscription) var liveTranscription
  @Dependency(\.liveTextInsertion) var liveTextInsertion
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
        // 4) Preloading live transcription models when Parakeet is selected
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect(),
          warmUpLiveTranscriptionEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      case let .liveTranscriptUpdated(text):
        state.liveTranscript = text
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // Ignore presses while a prior recording is still being transcribed.
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

      case let .transcriptionResult(result, audioURL, duration):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL, duration: duration)

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

  /// Preloads Parakeet models so live preview and final transcription start quickly.
  func warmUpLiveTranscriptionEffect() -> Effect<Action> {
    .run { _ in
      @Shared(.hexSettings) var hexSettings: HexSettings
      let model = hexSettings.selectedModel
      guard ParakeetModel(rawValue: model) != nil else { return }
      // Snapshot live preview and final transcription share the batch Parakeet client.
      try? await transcription.downloadModel(model) { _ in }
    }
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.isTranscriptionBusy) var isTranscriptionBusy: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: hexSettings.hotkey)

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

        // Skip hotkey state while Hex is injecting live preview keystrokes.
        if liveTextInsertion.isKeystrokeUpdateInFlight() {
          return false
        }

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
            guard !isTranscriptionBusy else { return false }
            let isDoubleTapLock = hotKeyProcessor.state == .doubleTapLock
            Task {
              await recording.prewarmCapture()
              if hexSettings.livePreviewDisplayMode == .cursor {
                _ = liveTextInsertion.prepareNow()
              }
              if isDoubleTapLock {
                await send(.startRecording)
              } else {
                await send(.hotKeyPressed)
              }
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
    guard !isTranscribing else { return .none }
    return .send(.startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard !state.isRecording, !state.isTranscribing else { return .none }
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    state.liveTranscript = ""
    let startTime = now
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    let model = state.hexSettings.selectedModel
    let useLiveTranscription = ParakeetModel(rawValue: model) != nil
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }

        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            await recording.startRecording(requiresLiveAudio: useLiveTranscription)
          }

          if useLiveTranscription {
            group.addTask {
              await runSnapshotLivePreview(model: model, send: send)
            }
          }
        }

        soundEffect.play(.startRecording)
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
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return handleDiscard(&state)
    }

    // Otherwise, proceed to transcription
    state.setTranscribing(true)
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let useLiveTranscription = ParakeetModel(rawValue: model) != nil

    state.isPrewarming = !useLiveTranscription
    let liveTranscriptSnapshot = state.liveTranscript

    return .concatenate(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement, useLiveTranscription, liveTranscriptSnapshot] send in
        await recording.setLiveAudioConsumer(nil)
        await liveTranscription.cancel()

        // Allow system to sleep again
        await sleepManagement.allowSleep()

        // Let the cancelled preview loop finish any in-flight Parakeet work before final pass.
        await transcription.waitForParakeetIdle()
        try? await transcription.reinitializeParakeetTranscriber()

        var audioURL: URL?
        defer {
          if let audioURL {
            FileManager.default.removeItemIfExists(at: audioURL)
          }
        }
        do {
          let capturedURL = await recording.stopRecording()
          audioURL = capturedURL
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)

          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            chunkingStrategy: .vad,
          )

          var result = ""
          transcriptionFeatureLogger.notice(
            "Final Parakeet transcribing capture file file=\(capturedURL.lastPathComponent)"
          )
          result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
          if result.isEmpty {
            transcriptionFeatureLogger.notice(
              "Final Parakeet returned empty; reinitializing and retrying file=\(capturedURL.lastPathComponent)"
            )
            try? await transcription.reinitializeParakeetTranscriber()
            result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
          }
          if result.isEmpty, !liveTranscriptSnapshot.isEmpty, duration < 1.5 {
            result = liveTranscriptSnapshot
            transcriptionFeatureLogger.notice(
              "Using live preview transcript as final fallback chars=\(result.count) duration=\(String(format: "%.2f", duration))s"
            )
          }

          transcriptionFeatureLogger.notice(
            "Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)"
          )
          audioURL = nil
          await send(.transcriptionResult(result, capturedURL, duration))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, nil))
        }
      }
      .cancellable(id: CancelID.transcription),
    )
  }

  /// Feeds capture-engine audio into FluidAudio streaming ASR (~350ms chunks).
  /// Reserved for future use; live preview currently uses batch snapshots for accuracy.
  func runStreamingLivePreview(model: String, send: Send<Action>) async {
    @Shared(.hexSettings) var hexSettings: HexSettings
    let insertAtCursor = hexSettings.livePreviewDisplayMode == .cursor
    do {
      try await liveTranscription.start(model)
      transcriptionFeatureLogger.notice("Streaming live preview started model=\(model)")

      await recording.setLiveAudioConsumer { buffer in
        await liveTranscription.feedAudio(buffer)
      }

      var previewGate = LivePreviewUpdateGate()
      for await update in await liveTranscription.observeUpdates() {
        guard !Task.isCancelled else { break }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        await applyLivePreviewText(
          text,
          insertAtCursor: insertAtCursor,
          previewGate: &previewGate,
          send: send
        )
      }
    } catch {
      transcriptionFeatureLogger.error(
        "Streaming live preview failed: \(error.localizedDescription)"
      )
    }
    await recording.setLiveAudioConsumer(nil)
  }

  /// Batch Parakeet on growing in-memory WAV snapshots (reliable live cursor updates).
  func runSnapshotLivePreview(model: String, send: Send<Action>) async {
    @Shared(.hexSettings) var hexSettings: HexSettings
    let insertAtCursor = hexSettings.livePreviewDisplayMode == .cursor
    var previewGate = LivePreviewUpdateGate()
    var transcribeScheduler = LivePreviewTranscriptionScheduler()
    var pollCount = 0
    var inFlightTranscribe = false

    while !Task.isCancelled {
      let keystrokeBusy = liveTextInsertion.isKeystrokeUpdateInFlight()
      let pollDelayMs: Int = {
        if previewGate.lastApplied.isEmpty { return 60 }
        if keystrokeBusy { return 300 }
        if insertAtCursor { return 220 }
        return 240
      }()
      if pollCount > 0 {
        try? await Task.sleep(for: .milliseconds(pollDelayMs))
      }
      pollCount += 1

      guard !Task.isCancelled else { break }
      guard !inFlightTranscribe else { continue }
      guard !keystrokeBusy else { continue }

      let currentDuration = await recording.previewRecordingDuration()
      guard transcribeScheduler.shouldScheduleTranscribe(
        snapshotDuration: currentDuration,
        hasInFlightTranscribe: inFlightTranscribe
      ) else { continue }

      guard !Task.isCancelled else { break }

      guard let snapshotURL = await recording.snapshotRecordingForPreview() else { continue }
      defer { try? FileManager.default.removeItem(at: snapshotURL) }

      let capturedDuration = currentDuration
      inFlightTranscribe = true
      defer { inFlightTranscribe = false }

      let text: String?
      do {
        let rawText = try await transcription.transcribePreview(snapshotURL, model)
        text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      } catch is CancellationError {
        break
      } catch {
        if Task.isCancelled { break }
        text = nil
      }

      guard !Task.isCancelled else { break }

      // Always advance the scheduler after a completed preview pass, even when Parakeet
      // returns empty — otherwise we re-transcribe every poll and overload audio + ASR.
      transcribeScheduler.markTranscribed(duration: capturedDuration)

      let nowDuration = await recording.previewRecordingDuration()
      guard let text, !text.isEmpty else { continue }

      if transcribeScheduler.shouldApplyResult(
        resultDuration: capturedDuration,
        currentDuration: nowDuration
      ) {
        await applyLivePreviewText(
          text,
          insertAtCursor: insertAtCursor,
          previewGate: &previewGate,
          send: send
        )
      } else {
        transcribeScheduler.noteSkippedStaleResult(at: capturedDuration)
        transcriptionFeatureLogger.debug(
          "Discarded stale live preview transcribe result captured=\(String(format: "%.3f", capturedDuration))s current=\(String(format: "%.3f", nowDuration))s"
        )
      }
    }
  }

  func applyLivePreviewUpdate(_ text: String, send: Send<Action>) async -> Bool {
    @Shared(.hexSettings) var hexSettings: HexSettings
    let insertAtCursor = hexSettings.livePreviewDisplayMode == .cursor
    guard !text.isEmpty else { return false }

    if insertAtCursor {
      guard await liveTextInsertion.update(text) else {
        transcriptionFeatureLogger.debug("Live preview apply failed chars=\(text.count)")
        return false
      }
      transcriptionFeatureLogger.notice("Live preview applied chars=\(text.count)")
    } else {
      transcriptionFeatureLogger.notice("Live preview overlay updated chars=\(text.count)")
    }
    await send(.liveTranscriptUpdated(text))
    return true
  }

  func applyLivePreviewText(
    _ text: String,
    insertAtCursor: Bool,
    previewGate: inout LivePreviewUpdateGate,
    send: Send<Action>
  ) async {
    guard previewGate.shouldApply(next: text) else { return }

    if insertAtCursor {
      guard await liveTextInsertion.update(text) else {
        transcriptionFeatureLogger.debug("Live preview apply failed chars=\(text.count)")
        return
      }
      transcriptionFeatureLogger.notice("Live preview applied chars=\(text.count)")
    } else {
      transcriptionFeatureLogger.notice("Live preview overlay updated chars=\(text.count)")
    }

    previewGate.markApplied(text)
    await send(.liveTranscriptUpdated(text))
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.setTranscribing(false)
    state.isPrewarming = false
    state.liveTranscript = ""

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, revert any live preview that was inserted at the cursor.
    guard !result.isEmpty else {
      return .run { _ in
        await Self.revertLivePreviewIfNeeded(liveTextInsertion: liveTextInsertion)
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .private)'")
    let remappings = state.hexSettings.wordRemappings
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = result
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = result
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      modifiedResult = remappedResult
    }

    guard !modifiedResult.isEmpty else {
      return .run { _ in
        await Self.revertLivePreviewIfNeeded(liveTextInsertion: liveTextInsertion)
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: modifiedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory,
          liveTextInsertion: liveTextInsertion,
          pasteboard: pasteboard,
          soundEffect: soundEffect
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.setTranscribing(false)
    state.isPrewarming = false
    state.liveTranscript = ""
    state.error = error.localizedDescription
    
    if let audioURL {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    return .run { _ in
      await Self.revertLivePreviewIfNeeded(liveTextInsertion: liveTextInsertion)
    }
  }

  static func revertLivePreviewIfNeeded(liveTextInsertion: LiveTextInsertionClient) async {
    guard await liveTextInsertion.isActive() else { return }
    await liveTextInsertion.revert()
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>,
    liveTextInsertion: LiveTextInsertionClient,
    pasteboard: PasteboardClient,
    soundEffect: SoundEffectsClient
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    if await liveTextInsertion.isActive() {
      if await liveTextInsertion.finalize(result) {
        soundEffect.play(.pasteTranscript)
      } else {
        await liveTextInsertion.revert()
        await pasteboard.paste(result)
        soundEffect.play(.pasteTranscript)
      }
    } else {
      await pasteboard.paste(result)
      soundEffect.play(.pasteTranscript)
    }
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    state.setTranscribing(false)
    state.isRecording = false
    state.isPrewarming = false
    state.liveTranscript = ""

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.liveTranscription),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        await liveTranscription.cancel()
        await Self.revertLivePreviewIfNeeded(liveTextInsertion: liveTextInsertion)
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        FileManager.default.removeItemIfExists(at: url)
        soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false
    state.liveTranscript = ""

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.liveTranscription),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        await liveTranscription.cancel()
        await Self.revertLivePreviewIfNeeded(liveTextInsertion: liveTextInsertion)
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        FileManager.default.removeItemIfExists(at: url)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @Shared(.hexSettings) var hexSettings: HexSettings
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
      meter: store.meter,
      liveTranscript: store.liveTranscript,
      livePreviewDisplayMode: hexSettings.livePreviewDisplayMode
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
