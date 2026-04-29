import AVFoundation
import AppKit
import ComposableArchitecture
import CoreAudio
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

private let settingsLogger = HexLog.settings
private typealias SettingsAudioPropertyListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

private enum HotKeyCaptureTarget {
  case recording
  case pasteLastTranscript
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
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var currentPasteLastModifiers: Modifiers = .init(modifiers: [])
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
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case toggleShowDockIcon(Bool)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)
    case toggleSuperFastMode(Bool)
    case setUseClipboardPaste(Bool)
    case setCopyToClipboard(Bool)
    case setDoubleTapLockEnabled(Bool)
    case setUseDoubleTapOnly(Bool)
    case setMinimumKeyTime(Double)
    case setOutputLanguage(String?)
    case setSelectedMicrophoneID(String?)
    case setSoundEffectsEnabled(Bool)
    case setSoundEffectsVolume(Double)

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
    case setMaxHistoryEntries(Int?)

    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Whisper prompt
    case setWhisperPrompt(String?)

    // Word remappings
    case setWordRemovalsEnabled(Bool)
    case addWordRemoval
    case updateWordRemoval(WordRemoval)
    case removeWordRemoval(UUID)
    case addWordRemapping
    case updateWordRemapping(WordRemapping)
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.permissions) var permissions
  @Dependency(\.soundEffects) var soundEffects
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
    }
  }

  private func captureModifiers(for target: HotKeyCaptureTarget, state: State) -> Modifiers {
    switch target {
    case .recording:
      state.currentModifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers
    }
  }

  private func updateCaptureModifiers(_ modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.currentModifiers = modifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers = modifiers
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
    }
  }

  private func handleCapture(_ keyEvent: KeyEvent, for target: HotKeyCaptureTarget, state: inout State) -> Effect<Action> {
    if keyEvent.key == .escape {
      endCapture(target, state: &state)
      return .none
    }

    let updatedModifiers = keyEvent.modifiers.union(captureModifiers(for: target, state: state))
    updateCaptureModifiers(updatedModifiers, for: target, state: &state)

    if target == .pasteLastTranscript, keyEvent.key != nil, updatedModifiers.isEmpty {
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
          func audioPropertyAddress(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
          ) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
              mSelector: selector,
              mScope: scope,
              mElement: element
            )
          }

          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)

          // Set up periodic refresh of available devices (every 120 seconds)
          // Using a longer interval to reduce resource usage
          let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(120)) {
              // Only refresh when the app is active to save resources
              if NSApplication.shared.isActive {
                await send(.loadAvailableInputDevices)
              }
            }
          }

          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          var audioHardwareObservers: [(AudioObjectPropertySelector, SettingsAudioPropertyListenerBlock)] = []

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

          func installAudioHardwareObserver(_ selector: AudioObjectPropertySelector) {
            let listener: SettingsAudioPropertyListenerBlock = { _, _ in
              debounceDeviceUpdate()
            }
            var address = audioPropertyAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(
              AudioObjectID(kAudioObjectSystemObject),
              &address,
              DispatchQueue.main,
              listener
            )

            if status == noErr {
              audioHardwareObservers.append((selector, listener))
            } else {
              settingsLogger.error("Failed to observe audio hardware selector \(selector): \(status)")
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

          let appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          installAudioHardwareObserver(kAudioHardwarePropertyDefaultInputDevice)
          installAudioHardwareObserver(kAudioHardwarePropertyDevices)

          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)

            for (selector, listener) in audioHardwareObservers {
              var address = audioPropertyAddress(selector)
              let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
              )
              if status != noErr {
                settingsLogger.error("Failed to remove audio hardware observer for selector \(selector): \(status)")
              }
            }
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

      case let .updateWordRemoval(removal):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemovals.firstIndex(where: { $0.id == removal.id }) else { return }
          $0.wordRemovals[index] = removal
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

      case let .updateWordRemapping(remapping):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemappings.firstIndex(where: { $0.id == remapping.id }) else { return }
          $0.wordRemappings[index] = remapping
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

      case let .keyEvent(keyEvent):
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

      case let .setUseClipboardPaste(enabled):
        state.$hexSettings.withLock { $0.useClipboardPaste = enabled }
        return .none

      case let .setCopyToClipboard(enabled):
        state.$hexSettings.withLock { $0.copyToClipboard = enabled }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      case let .toggleSuperFastMode(enabled):
        state.$hexSettings.withLock { $0.superFastModeEnabled = enabled }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      case let .setDoubleTapLockEnabled(enabled):
        state.$hexSettings.withLock {
          $0.doubleTapLockEnabled = enabled
          if !enabled {
            $0.useDoubleTapOnly = false
          }
        }
        return .none

      case let .setUseDoubleTapOnly(enabled):
        state.$hexSettings.withLock {
          $0.useDoubleTapOnly = enabled && $0.doubleTapLockEnabled
        }
        return .none

      case let .setMinimumKeyTime(value):
        state.$hexSettings.withLock { $0.minimumKeyTime = value }
        return .none

      case let .setOutputLanguage(language):
        state.$hexSettings.withLock { $0.outputLanguage = language }
        return .none

      case let .setSelectedMicrophoneID(deviceID):
        state.$hexSettings.withLock { $0.selectedMicrophoneID = deviceID }
        return .none

      case let .setSoundEffectsEnabled(enabled):
        state.$hexSettings.withLock { $0.soundEffectsEnabled = enabled }
        return .run { _ in
          await soundEffects.setEnabled(enabled)
        }

      case let .setSoundEffectsVolume(volume):
        state.$hexSettings.withLock { $0.soundEffectsVolume = volume }
        return .none

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

      case let .setMaxHistoryEntries(maxHistoryEntries):
        state.$hexSettings.withLock { $0.maxHistoryEntries = maxHistoryEntries }
        return .none

      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      case let .setWhisperPrompt(prompt):
        state.$hexSettings.withLock { $0.whisperPrompt = prompt?.isEmpty == true ? nil : prompt }
        return .none

      case let .setWordRemovalsEnabled(enabled):
        state.$hexSettings.withLock { $0.wordRemovalsEnabled = enabled }
        return .none

      }
    }
  }
}
