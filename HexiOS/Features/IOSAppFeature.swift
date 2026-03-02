import ComposableArchitecture
import HexCore

@Reducer
struct IOSAppFeature {
  enum ActiveTab: Equatable {
    case record
    case history
    case settings
  }

  @ObservableState
  struct State: Equatable {
    var transcription = IOSTranscriptionFeature.State()
    var settings = IOSSettingsFeature.State()
    var history = HistoryFeature.State()
    var activeTab: ActiveTab = .record
    var microphonePermission: PermissionStatus = .notDetermined
  }

  enum Action {
    case transcription(IOSTranscriptionFeature.Action)
    case settings(IOSSettingsFeature.Action)
    case history(HistoryFeature.Action)
    case task
    case tabChanged(ActiveTab)
    case checkPermissions
    case microphoneStatusUpdated(PermissionStatus)
    case requestMicrophone
    case microphoneRequestResult(Bool)
  }

  @Dependency(\.permissions) var permissions

  var body: some ReducerOf<Self> {
    Scope(state: \.transcription, action: \.transcription) {
      IOSTranscriptionFeature()
    }
    Scope(state: \.settings, action: \.settings) {
      IOSSettingsFeature()
    }
    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Reduce { state, action in
      switch action {
      case .task:
        return .run { send in
          await send(.checkPermissions)
        }

      case .tabChanged(let tab):
        state.activeTab = tab
        return .none

      case .checkPermissions:
        return .run { send in
          let status = await permissions.microphoneStatus()
          await send(.microphoneStatusUpdated(status))
        }

      case .microphoneStatusUpdated(let status):
        state.microphonePermission = status
        return .none

      case .requestMicrophone:
        return .run { send in
          let granted = await permissions.requestMicrophone()
          await send(.microphoneRequestResult(granted))
        }

      case .microphoneRequestResult(let granted):
        state.microphonePermission = granted ? .granted : .denied
        return .none

      case .transcription, .settings, .history:
        return .none
      }
    }
  }
}
