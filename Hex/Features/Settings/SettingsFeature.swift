import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

private let settingsLogger = HexLog.settings

private enum HotKeyCaptureTarget {
  case recording
  case pasteLastTranscript
  case cycleTone
  case refineSelection
}

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }
  
  static var isSettingPasteLastTranscriptHotkey: Self {
    Self[.inMemory("isSettingPasteLastTranscriptHotkey"), default: false]
  }

  static var isRemappingScratchpadFocused: Self {
    Self[.inMemory("isRemappingScratchpadFocused"), default: false]
  }

  static var isSettingCycleToneHotkey: Self {
    Self[.inMemory("isSettingCycleToneHotkey"), default: false]
  }

  static var isSettingRefineSelectionHotkey: Self {
    Self[.inMemory("isSettingRefineSelectionHotkey"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool = false
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.isSettingCycleToneHotkey) var isSettingCycleToneHotkey: Bool = false
    @Shared(.isSettingRefineSelectionHotkey) var isSettingRefineSelectionHotkey: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var currentPasteLastModifiers: Modifiers = .init(modifiers: [])
    var currentCycleToneModifiers: Modifiers = .init(modifiers: [])
    var currentRefineSelectionModifiers: Modifiers = .init(modifiers: [])
    var remappingScratchpadText: String = ""
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []
    var defaultInputDeviceName: String?

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
    var shouldFlashModelSection = false

  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case startSettingPasteLastTranscriptHotkey
    case clearPasteLastTranscriptHotkey
    case startSettingCycleToneHotkey
    case clearCycleToneHotkey
    case startSettingRefineSelectionHotkey
    case clearRefineSelectionHotkey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case toggleShowDockIcon(Bool)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)
    case setGeminiAPIKey(String?)
    case toggleSuperFastMode(Bool)

    // Permission delegation (forwarded to AppFeature)
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice], String?)

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)
    
    // History Management
    case toggleSaveTranscriptionHistory(Bool)

    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Word remappings
    case addWordRemoval
    case removeWordRemoval(UUID)
    case addWordRemapping
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.permissions) var permissions
  @Dependency(\.transcriptPersistence) var transcriptPersistence

  private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
    .run { [transcriptPersistence] _ in
      for transcript in transcripts {
        try? await transcriptPersistence.deleteAudio(transcript)
      }
    }
  }

  private func beginCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = true }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = true }
      state.currentPasteLastModifiers = .init(modifiers: [])
    case .cycleTone:
      state.$isSettingCycleToneHotkey.withLock { $0 = true }
      state.currentCycleToneModifiers = .init(modifiers: [])
    case .refineSelection:
      state.$isSettingRefineSelectionHotkey.withLock { $0 = true }
      state.currentRefineSelectionModifiers = .init(modifiers: [])
    }
  }

  private func endCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = false }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
      state.currentPasteLastModifiers = .init(modifiers: [])
    case .cycleTone:
      state.$isSettingCycleToneHotkey.withLock { $0 = false }
      state.currentCycleToneModifiers = .init(modifiers: [])
    case .refineSelection:
      state.$isSettingRefineSelectionHotkey.withLock { $0 = false }
      state.currentRefineSelectionModifiers = .init(modifiers: [])
    }
  }

  private func captureModifiers(for target: HotKeyCaptureTarget, state: State) -> Modifiers {
    switch target {
    case .recording:
      state.currentModifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers
    case .cycleTone:
      state.currentCycleToneModifiers
    case .refineSelection:
      state.currentRefineSelectionModifiers
    }
  }

  private func updateCaptureModifiers(_ modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.currentModifiers = modifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers = modifiers
    case .cycleTone:
      state.currentCycleToneModifiers = modifiers
    case .refineSelection:
      state.currentRefineSelectionModifiers = modifiers
    }
  }

  private func applyCapturedHotKey(key: Key?, modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$hexSettings.withLock {
        $0.hotkey.key = key
        $0.hotkey.modifiers = modifiers.erasingSides()
      }
    case .pasteLastTranscript:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.pasteLastTranscriptHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    case .cycleTone:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.cycleToneHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    case .refineSelection:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.refineSelectionHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    }
  }

  private func handleCapture(_ keyEvent: KeyEvent, for target: HotKeyCaptureTarget, state: inout State) -> Effect<Action> {
    if keyEvent.key == .escape {
      endCapture(target, state: &state)
      return .none
    }

    let updatedModifiers = keyEvent.modifiers.union(captureModifiers(for: target, state: state))
    updateCaptureModifiers(updatedModifiers, for: target, state: &state)

    if (target == .pasteLastTranscript || target == .cycleTone || target == .refineSelection), keyEvent.key != nil, updatedModifiers.isEmpty {
      return .none
    }

    if let key = keyEvent.key {
      applyCapturedHotKey(key: key, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
      return .none
    }

    if target == .recording, keyEvent.modifiers.isEmpty {
      applyCapturedHotKey(key: nil, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
    }

    return .none
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        let didNormalizeDoubleTapOnly = !state.hexSettings.doubleTapLockEnabled && state.hexSettings.useDoubleTapOnly
        if didNormalizeDoubleTapOnly {
          state.$hexSettings.withLock {
            $0.useDoubleTapOnly = false
          }
        }

        return .none

      case .task:
        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          settingsLogger.error("Failed to load languages JSON from bundle")
        }

        // Listen for key events and load microphones (existing + new)
        return .run { send in
          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)
          
          // Set up periodic refresh of available devices (every 120 seconds)
          // Using a longer interval to reduce resource usage
          let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(120)) {
              // Only refresh when the app is active to save resources
              if NSApplication.shared.isActive {
                send(.loadAvailableInputDevices)
              }
            }
          }
          
          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          
          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }
          
          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
          }

          for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
            await send(.keyEvent(keyEvent))
          }
          
          deviceRefreshTask.cancel()
        }

      case .startSettingHotKey:
        beginCapture(.recording, state: &state)
        return .none

      case .addWordRemoval:
        state.$hexSettings.withLock {
          $0.wordRemovals.append(.init(pattern: ""))
        }
        return .none

      case let .removeWordRemoval(id):
        state.$hexSettings.withLock {
          $0.wordRemovals.removeAll { $0.id == id }
        }
        return .none

      case .addWordRemapping:
        state.$hexSettings.withLock {
          $0.wordRemappings.append(.init(match: "", replacement: ""))
        }
        return .none

      case let .removeWordRemapping(id):
        state.$hexSettings.withLock {
          $0.wordRemappings.removeAll { $0.id == id }
        }
        return .none

      case let .setRemappingScratchpadFocused(isFocused):
        state.$isRemappingScratchpadFocused.withLock { $0 = isFocused }
        return .none

      case .startSettingPasteLastTranscriptHotkey:
        beginCapture(.pasteLastTranscript, state: &state)
        return .none

      case .clearPasteLastTranscriptHotkey:
        state.$hexSettings.withLock { $0.pasteLastTranscriptHotkey = nil }
        return .none

      case .startSettingCycleToneHotkey:
        beginCapture(.cycleTone, state: &state)
        return .none

      case .clearCycleToneHotkey:
        state.$hexSettings.withLock { $0.cycleToneHotkey = nil }
        return .none

      case .startSettingRefineSelectionHotkey:
        beginCapture(.refineSelection, state: &state)
        return .none

      case .clearRefineSelectionHotkey:
        state.$hexSettings.withLock { $0.refineSelectionHotkey = nil }
        return .none

      case let .keyEvent(keyEvent):
        if state.isSettingRefineSelectionHotkey {
          return handleCapture(keyEvent, for: .refineSelection, state: &state)
        }

        if state.isSettingCycleToneHotkey {
          return handleCapture(keyEvent, for: .cycleTone, state: &state)
        }

        if state.isSettingPasteLastTranscriptHotkey {
          return handleCapture(keyEvent, for: .pasteLastTranscript, state: &state)
        }

        guard state.isSettingHotKey else { return .none }
        return handleCapture(keyEvent, for: .recording, state: &state)

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .toggleShowDockIcon(enabled):
        state.$hexSettings.withLock { $0.showDockIcon = enabled }
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .updateAppMode, object: nil)
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      case let .setGeminiAPIKey(key):
        state.$hexSettings.withLock { $0.geminiAPIKey = key }
        return .none

      case let .toggleSuperFastMode(enabled):
        state.$hexSettings.withLock { $0.superFastModeEnabled = enabled }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      // Permission requests
      case .requestMicrophone:
        settingsLogger.info("User requested microphone permission from settings")
        return .run { _ in
          _ = await permissions.requestMicrophone()
        }

      case .requestAccessibility:
        settingsLogger.info("User requested accessibility permission from settings")
        return .run { _ in
          await permissions.requestAccessibility()
        }

      case .requestInputMonitoring:
        settingsLogger.info("User requested input monitoring permission from settings")
        return .run { _ in
          _ = await permissions.requestInputMonitoring()
        }

      // Model Management
      case let .modelDownload(.selectModel(newModel)):
        // Also store it in hexSettings:
        state.$hexSettings.withLock {
          $0.selectedModel = newModel
        }
        // Then continue with the child's normal logic:
        return .none

      case .modelDownload:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          let defaultName = await recording.getDefaultInputDeviceName()
          await send(.availableInputDevicesLoaded(devices, defaultName))
        }
        
      case let .availableInputDevicesLoaded(devices, defaultName):
        state.availableInputDevices = devices
        state.defaultInputDeviceName = defaultName
        return .none
        
      case let .toggleSaveTranscriptionHistory(enabled):
        state.$hexSettings.withLock { $0.saveTranscriptionHistory = enabled }
        
        // If disabling history, delete all existing entries
        if !enabled {
          let transcripts = state.transcriptionHistory.history
          
          // Clear the history
          state.$transcriptionHistory.withLock { history in
            history.history.removeAll()
          }

          return deleteAudioEffect(for: transcripts)
        }
        
        return .none

      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      }
    }
  }
}
