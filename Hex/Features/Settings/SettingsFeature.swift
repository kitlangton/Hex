import AVFoundation
import ComposableArchitecture
import Dependencies
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])

    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []

    // Permissions
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case togglePreventSystemSleep(Bool)
    case togglePauseMediaOnRecord(Bool)
    case checkPermissions
    case setMicrophonePermission(PermissionStatus)
    case setAccessibilityPermission(PermissionStatus)
    case requestMicrophonePermission
    case requestAccessibilityPermission
    case accessibilityStatusDidChange

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice])

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)

    // History Management
    case toggleSaveTranscriptionHistory(Bool)
  }

  enum CancelID {
    case deviceNotifications
    case keyEvents
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: NSNotification.Name("UpdateAppMode"), object: nil)
          }
        }

      case .task:
        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          print("Failed to load languages")
        }

        // Kick off initial loads, device notifications, and key event listening
        return .merge(
          .run { send in
            await send(.checkPermissions)
            await send(.modelDownload(.fetchModels))
            await send(.loadAvailableInputDevices)
          },
          deviceNotificationsEffect(),
          keyPressListenerEffect()
        )

      case .startSettingHotKey:
        state.$isSettingHotKey.withLock { $0 = true }
        return .none

      case let .keyEvent(keyEvent):
        guard state.isSettingHotKey else { return .none }

        if keyEvent.key == .escape {
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
          return .none
        }

        state.currentModifiers = keyEvent.modifiers.union(state.currentModifiers)
        let currentModifiers = state.currentModifiers
        if let key = keyEvent.key {
          state.$hexSettings.withLock {
            $0.hotkey.key = key
            $0.hotkey.modifiers = currentModifiers
          }
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
        } else if keyEvent.modifiers.isEmpty {
          state.$hexSettings.withLock {
            $0.hotkey.key = nil
            $0.hotkey.modifiers = currentModifiers
          }
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
        }
        return .none

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .togglePauseMediaOnRecord(enabled):
        state.$hexSettings.withLock { $0.pauseMediaOnRecord = enabled }
        return .none

      // Permissions
      case .checkPermissions:
        // Check microphone
        return .merge(
          .run { send in
            let currentStatus = await checkMicrophonePermission()
            await send(.setMicrophonePermission(currentStatus))
          },
          .run { send in
            let currentStatus = checkAccessibilityPermission()
            await send(.setAccessibilityPermission(currentStatus))
          }
        )

      case let .setMicrophonePermission(status):
        state.microphonePermission = status
        return .none

      case let .setAccessibilityPermission(status):
        state.accessibilityPermission = status
        if status == .granted {
          return .run { _ in
            await keyEventMonitor.startMonitoring()
          }
        } else {
          return .none
        }

      case .requestMicrophonePermission:
        return .run { send in
          let granted = await requestMicrophonePermissionImpl()
          let status: PermissionStatus = granted ? .granted : .denied
          await send(.setMicrophonePermission(status))
        }

      case .requestAccessibilityPermission:
        return .run { send in
          // First, prompt the user with the system dialog
          let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
          _ = AXIsProcessTrustedWithOptions(options)

          // Open System Settings
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
          )

          // Poll for changes every second until granted
          for await _ in self.clock.timer(interval: .seconds(0.5)) {
            let newStatus = checkAccessibilityPermission()
            await send(.setAccessibilityPermission(newStatus))

            // If permission is granted, we can stop polling
            if newStatus == .granted {
              break
            }
          }
        }

      case .accessibilityStatusDidChange:
        let newStatus = checkAccessibilityPermission()
        state.accessibilityPermission = newStatus
        return .none

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
          await send(.availableInputDevicesLoaded(devices))
        }

      case let .availableInputDevicesLoaded(devices):
        state.availableInputDevices = devices
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

          // Delete all audio files
          return .run { _ in
            for transcript in transcripts {
              try? FileManager.default.removeItem(at: transcript.audioPath)
            }
          }
        }

        return .none
      }
    }
  }
}

// MARK: - Permissions Helpers

// MARK: - Effects

private extension SettingsFeature {
  func deviceNotificationsEffect() -> Effect<Action> {
    .run { send in
      @Dependency(\.continuousClock) var clock
      // Debounce helper using an actor to avoid Swift 6 concurrent capture issues
      actor DeviceUpdateTaskBox {
        private var task: Task<Void, Never>?
        func set(_ newTask: Task<Void, Never>?) {
          task?.cancel()
          task = newTask
        }
        func cancel() { task?.cancel(); task = nil }
      }
      let taskBox = DeviceUpdateTaskBox()
      func debounceDeviceUpdate() {
        Task {
          await taskBox.set(Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled {
              await MainActor.run { send(.loadAvailableInputDevices) }
            }
          })
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

      await withTaskCancellationHandler {
        for await _ in AsyncStream<Never>.never {}
      } onCancel: {
        Task { await taskBox.cancel() }
        NotificationCenter.default.removeObserver(deviceConnectionObserver)
        NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
      }
    }
    .cancellable(id: CancelID.deviceNotifications, cancelInFlight: true)
  }

  func keyPressListenerEffect() -> Effect<Action> {
    .run { send in
      for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
        await send(.keyEvent(keyEvent))
      }
    }
    .cancellable(id: CancelID.keyEvents, cancelInFlight: true)
  }
}

/// Check current microphone permission
private func checkMicrophonePermission() async -> PermissionStatus {
  switch AVCaptureDevice.authorizationStatus(for: .audio) {
  case .authorized:
    return .granted
  case .denied, .restricted:
    return .denied
  case .notDetermined:
    return .notDetermined
  @unknown default:
    return .denied
  }
}

/// Request microphone permission
private func requestMicrophonePermissionImpl() async -> Bool {
  await withCheckedContinuation { continuation in
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      continuation.resume(returning: granted)
    }
  }
}

/// Check Accessibility permission on macOS
/// This implementation checks the actual trust status without showing a prompt
private func checkAccessibilityPermission() -> PermissionStatus {
  let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
  let trusted = AXIsProcessTrustedWithOptions(options)
  return trusted ? .granted : .denied
}

// MARK: - Permission Status

enum PermissionStatus: Equatable {
  case notDetermined
  case granted
  case denied
}
