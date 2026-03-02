import ComposableArchitecture
import Dependencies
import HexCore

@Reducer
struct IOSSettingsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.hexSettings) var hexSettings: HexSettings
    var modelDownload = ModelDownloadFeature.State()
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case modelDownload(ModelDownloadFeature.Action)
    case task
    case toggleSoundEffects
    case setSoundVolume(Double)
    case toggleHistory
    case setLanguage(String?)
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        return .send(.modelDownload(.fetchModels))

      case .toggleSoundEffects:
        state.$hexSettings.withLock { $0.soundEffectsEnabled.toggle() }
        return .none

      case .setSoundVolume(let volume):
        state.$hexSettings.withLock { $0.soundEffectsVolume = volume }
        return .none

      case .toggleHistory:
        state.$hexSettings.withLock { $0.saveTranscriptionHistory.toggle() }
        return .none

      case .setLanguage(let code):
        state.$hexSettings.withLock { $0.outputLanguage = code }
        return .none

      case .modelDownload:
        return .none
      }
    }
  }
}
