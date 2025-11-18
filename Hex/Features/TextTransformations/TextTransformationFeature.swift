import AppKit
import ComposableArchitecture
import Foundation
import HexCore

@Reducer
struct TextTransformationFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.textTransformations) var textTransformations: TextTransformationsState
        var configFileError: String?
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case startWatchingConfigFile
        case configFileChanged
        case configFileErrorOccurred(String)
    }

    var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .startWatchingConfigFile:
                let url = URL.textTransformationsURL
                return .run { send in
                    guard let descriptor = url.path.withCString({ path -> Int32? in
                        let fd = open(path, O_EVTONLY)
                        return fd >= 0 ? fd : nil
                    }) else {
                        await send(.configFileErrorOccurred("Unable to watch configuration file."))
                        return
                    }

                    let source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: descriptor,
                        eventMask: [.write, .delete, .rename],
                        queue: .main
                    )

                    source.setEventHandler {
                        Task { await send(.configFileChanged) }
                    }

                    source.setCancelHandler {
                        close(descriptor)
                    }

                    source.resume()

                    // Keep the source alive
                    for await _ in AsyncStream<Never>.never {}
                }

            case .configFileChanged:
                let url = URL.textTransformationsURL
                guard let data = try? Data(contentsOf: url) else {
                    return .send(.configFileErrorOccurred("Could not read configuration file."))
                }

                guard let decoded = try? JSONDecoder().decode(TextTransformationsState.self, from: data) else {
                    return .send(.configFileErrorOccurred("Invalid JSON format."))
                }

                state.$textTransformations.withLock { storage in
                    storage = decoded
                }
                state.configFileError = nil
                return .none

            case let .configFileErrorOccurred(message):
                state.configFileError = message
                return .none
            }
        }
    }
}
