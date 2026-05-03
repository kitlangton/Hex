import ComposableArchitecture
import Foundation
import HexCore
import WhisperKit

private let openCodeCommandLogger = HexLog.opencode

@Reducer
struct OpenCodeCommandFeature {
  @ObservableState
  struct State: Equatable {
    var isRecording: Bool = false
    var isProcessing: Bool = false
    var recordingStartTime: Date?
    var error: String?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var runtimeStatus: OpenCodeRuntimeStatus = .idle
    var isDismissingOverlay: Bool = false
    var draftActivity: OpenCodeSessionActivity?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    mutating func updateLocalActivity(id: String, _ update: (inout OpenCodeSessionActivity) -> Void) {
      if var draft = draftActivity, draft.id == id {
        update(&draft)
        draftActivity = draft
      }
      if let index = runtimeStatus.activities.firstIndex(where: { $0.id == id }) {
        update(&runtimeStatus.activities[index])
      } else if let draft = draftActivity, draft.id == id {
        runtimeStatus.activities.insert(draft, at: 0)
        // Cap at 5
        if runtimeStatus.activities.count > 5 {
          runtimeStatus.activities = Array(runtimeStatus.activities.prefix(5))
        }
      }
    }
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)
    case hotKeyPressed
    case hotKeyReleased
    case startRecording
    case stopRecording
    case cancel
    case discard
    case draftCommandRecognized(String)
    case processingFinished(playSuccessSound: Bool)
    case processingFailed(String, URL?)
    case runtimeStatusChanged(OpenCodeRuntimeStatus)
    case dismissOverlay
    case dismissOverlayStep
    case finishOverlayDismiss
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingCleanup
    case processing
    case overlayDismiss
  }

  @Dependency(\.recording) var recording
  @Dependency(\.transcription) var transcription
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.openCode) var openCode
  @Dependency(\.date.now) var now

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          observeMeteringEffect(),
          startHotKeyMonitoringEffect(),
          observeRuntimeStatusEffect()
        )

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      case .hotKeyPressed:
        return .send(.startRecording)

      case .hotKeyReleased:
        return state.isRecording ? .send(.stopRecording) : .none

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      case let .draftCommandRecognized(command):
        if let draftID = state.draftActivity?.id {
          state.updateLocalActivity(id: draftID) {
            $0.command = command
            $0.status = .queued
            $0.responseText = "Sending to OpenCode"
          }
        }
        return .none

      case .cancel:
        guard state.isRecording || state.isProcessing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)

      case let .processingFinished(playSuccessSound):
        state.isProcessing = false
        state.recordingStartTime = nil
        state.error = nil
        state.draftActivity = nil
        if playSuccessSound {
          soundEffect.play(.pasteTranscript)
        }
        return .none

      case let .processingFailed(message, audioURL):
        state.isProcessing = false
        state.recordingStartTime = nil
        state.error = message
        if let draftID = state.draftActivity?.id {
          state.updateLocalActivity(id: draftID) {
            $0.status = .error(message)
            $0.responseText = message
          }
          state.draftActivity = nil
        }

        if let audioURL {
          FileManager.default.removeItemIfExists(at: audioURL)
        }

        soundEffect.play(.cancel)
        return .none

      case let .runtimeStatusChanged(status):
        // Merge server activities while preserving local-only activities (drafts)
        var merged = status.activities
        for local in state.runtimeStatus.activities {
          if !merged.contains(where: { $0.id == local.id }) {
            // Keep local activities that the server doesn't know about yet
            if local.status == .listening || local.status == .transcribing || local.status == .queued {
              merged.append(local)
            }
          }
        }
        state.runtimeStatus = status
        state.runtimeStatus.activities = merged
        if let draftID = state.draftActivity?.id,
           status.activities.contains(where: { $0.id == draftID }) {
          state.draftActivity = nil
        }
        let isDone = status.activeSessions == 0 && status.queuedCommands == 0
        let hasActivities = !status.activities.isEmpty
        if isDone && hasActivities {
          return .run { send in
            try await Task.sleep(for: .seconds(8))
            await send(.dismissOverlay)
          }
          .cancellable(id: CancelID.overlayDismiss, cancelInFlight: true)
        } else if !isDone {
          state.isDismissingOverlay = false
          return .cancel(id: CancelID.overlayDismiss)
        }
        return .none

      case .dismissOverlay:
        guard !state.runtimeStatus.activities.isEmpty else {
          return .none
        }
        state.isDismissingOverlay = true
        return .send(.dismissOverlayStep)

      case .dismissOverlayStep:
        guard !state.runtimeStatus.activities.isEmpty else {
          return .none
        }
        state.runtimeStatus.activities.removeLast()
        guard !state.runtimeStatus.activities.isEmpty else {
          return .run { send in
            try await Task.sleep(for: .milliseconds(180))
            await send(.finishOverlayDismiss)
          }
          .cancellable(id: CancelID.overlayDismiss, cancelInFlight: true)
        }
        return .run { send in
          try await Task.sleep(for: .milliseconds(70))
          await send(.dismissOverlayStep)
        }
        .cancellable(id: CancelID.overlayDismiss, cancelInFlight: true)

      case .finishOverlayDismiss:
        state.isDismissingOverlay = false
        return .none

      case .modelMissing:
        return .none
      }
    }
  }
}

private extension OpenCodeCommandFeature {
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor = HotKeyProcessor(
        hotkey: OpenCodeExperimentalSettings.defaultHotkey,
        useDoubleTapOnly: false,
        doubleTapLockEnabled: false
      )
      @Shared(.isSettingOpenCodeHotKey) var isSettingOpenCodeHotKey: Bool
      @Shared(.suppressStandardTranscriptionHotKey) var suppressStandardTranscriptionHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      let token = keyEventMonitor.handleInputEvent { inputEvent in
        if case let .keyboard(keyEvent) = inputEvent,
           keyEvent.key == nil,
           keyEvent.modifiers.isEmpty,
           suppressStandardTranscriptionHotKey
        {
          $suppressStandardTranscriptionHotKey.withLock { $0 = false }
        }

        if isSettingOpenCodeHotKey {
          return false
        }

        let configuration = hexSettings.openCodeExperimental
        guard configuration.isEnabled else {
          return false
        }

        hotKeyProcessor.hotkey = configuration.hotkey
        hotKeyProcessor.useDoubleTapOnly = false
        hotKeyProcessor.doubleTapLockEnabled = false
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case let .keyboard(keyEvent):
          let output = hotKeyProcessor.process(keyEvent: keyEvent)
          if output != nil || hotKeyProcessor.state != .idle {
            $suppressStandardTranscriptionHotKey.withLock { $0 = true }
          }

          switch output {
          case .startRecording:
            Task { await send(.hotKeyPressed) }
            return configuration.hotkey.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false

          case .none:
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers {
              return true
            }
            return false
          }

        case .mouseClick:
          let output = hotKeyProcessor.processMouseClick()
          if output != nil || hotKeyProcessor.state != .idle {
            $suppressStandardTranscriptionHotKey.withLock { $0 = true }
          }

          switch output {
          case .cancel:
            Task { await send(.cancel) }
            return false
          case .discard:
            Task { await send(.discard) }
            return false
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

  func observeMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  func observeRuntimeStatusEffect() -> Effect<Action> {
    .run { send in
      for await status in await openCode.observeStatus() {
        await send(.runtimeStatusChanged(status))
      }
    }
  }

  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard !state.isRecording, !state.isProcessing else {
      return .none
    }

    guard state.hexSettings.openCodeExperimental.isEnabled else {
      return .none
    }

    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }

    state.isRecording = true
    state.recordingStartTime = now
    state.error = nil
    state.isDismissingOverlay = false
    let draftID = UUID().uuidString
    let draft = OpenCodeSessionActivity(
      id: draftID,
      sessionID: nil,
      command: "Voice action",
      status: .listening,
      toolCalls: [],
      responseText: "Listening for action"
    )
    state.draftActivity = draft
    state.runtimeStatus.activities.insert(draft, at: 0)
    if state.runtimeStatus.activities.count > 5 {
      state.runtimeStatus.activities = Array(state.runtimeStatus.activities.prefix(5))
    }

    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .cancel(id: CancelID.overlayDismiss),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        soundEffect.play(.startRecording)
        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex OpenCode Voice Command")
        }
        await recording.startRecording()
      }
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false

    let stopTime = now
    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.openCodeExperimental.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    guard decision == .proceedToTranscription else {
      openCodeCommandLogger.notice("Discarding short OpenCode voice command recording")
      state.recordingStartTime = nil
      if let draftID = state.draftActivity?.id {
        state.runtimeStatus.activities.removeAll { $0.id == draftID }
      }
      state.draftActivity = nil
      return .run { _ in
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        FileManager.default.removeItemIfExists(at: url)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    }

    state.isProcessing = true
    let draftActivityID = state.draftActivity?.id ?? UUID().uuidString
    state.updateLocalActivity(id: draftActivityID) {
      $0.status = .transcribing
      $0.responseText = "Transcribing command"
    }
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let openCodeSettings = state.hexSettings.openCodeExperimental

    return .run { [sleepManagement] send in
      await sleepManagement.allowSleep()

      var audioURL: URL?
      do {
        let capturedURL = await recording.stopRecording()
        guard !Task.isCancelled else { return }

        if capturedURL.isHexIgnoredStopRecording {
          FileManager.default.removeItemIfExists(at: capturedURL)
          await send(.processingFinished(playSuccessSound: false))
          return
        }

        soundEffect.play(.stopRecording)
        audioURL = capturedURL

        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil,
          chunkingStrategy: .vad
        )
        let transcript = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        FileManager.default.removeItemIfExists(at: capturedURL)
        audioURL = nil

        guard !command.isEmpty else {
          await send(.processingFinished(playSuccessSound: false))
          return
        }

        await send(.draftCommandRecognized(command))
        try await openCode.enqueueVoiceCommand(draftActivityID, command, openCodeSettings)
        await send(.processingFinished(playSuccessSound: true))
      } catch {
        openCodeCommandLogger.error("OpenCode voice command failed: \(error.localizedDescription, privacy: .public)")
        await send(.processingFailed(error.localizedDescription, audioURL))
      }
    }
    .cancellable(id: CancelID.processing)
  }

  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isProcessing = false
    state.recordingStartTime = nil
    if let draftID = state.draftActivity?.id {
      state.runtimeStatus.activities.removeAll { $0.id == draftID }
    }
    state.draftActivity = nil

    return .merge(
      .cancel(id: CancelID.processing),
      .run { [sleepManagement] _ in
        await sleepManagement.allowSleep()
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
    state.recordingStartTime = nil
    if let draftID = state.draftActivity?.id {
      state.runtimeStatus.activities.removeAll { $0.id == draftID }
    }
    state.draftActivity = nil

    return .run { [sleepManagement] _ in
      await sleepManagement.allowSleep()
      let url = await recording.stopRecording()
      guard !Task.isCancelled else { return }
      FileManager.default.removeItemIfExists(at: url)
    }
    .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
  }
}
