// MARK: – ConversationModelDownloadFeature.swift

// TCA reducer for managing MoshiKit conversation model download.
// Uses the ConversationClient to download models from HuggingFace.

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore

private let logger = HexLog.settings

// MARK: – Domain

@Reducer
public struct ConversationModelDownloadFeature {
    @ObservableState
    public struct State: Equatable {
        // Shared state
        @Shared(.hexSettings) var hexSettings: HexSettings
        @Shared(.conversationModelBootstrapState) var bootstrapState: ConversationModelBootstrapState

        // UI state
        public var isDownloading = false
        public var downloadProgress: Double = 0
        public var downloadError: String?
        public var isModelDownloaded = false

        // Cancellation tracking
        var activeDownloadID: UUID?

        // Model info
        public let modelName = "Moshi"
        public let modelIdentifier = "kyutai/moshiko-mlx-bf16"
        public let modelSize = "~3 GB"

        public init() {}
    }

    // MARK: Actions

    public enum Action: BindableAction {
        case binding(BindingAction<State>)

        // Lifecycle
        case task
        case checkModelStatus

        // Download actions
        case downloadModel
        case downloadProgress(Double)
        case downloadCompleted(Result<Void, Error>)
        case cancelDownload

        // Status updates
        case modelStatusChecked(Bool)

        // UI
        case openModelLocation
    }

    // MARK: Dependencies

    @Dependency(\.conversation) var conversation
    @Dependency(\.continuousClock) var clock

    public init() {}

    // MARK: Reducer

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce(reduce)
    }

    private func reduce(state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .binding:
            return .none

        case .task:
            return .send(.checkModelStatus)

        case .checkModelStatus:
            return .run { send in
                let isReady = await conversation.isModelReady()
                await send(.modelStatusChecked(isReady))
            }

        case let .modelStatusChecked(isReady):
            state.isModelDownloaded = isReady
            state.$bootstrapState.withLock {
                $0.isModelReady = isReady
                if isReady {
                    $0.progress = 1.0
                    $0.lastError = nil
                }
            }
            return .none

        // MARK: – Download

        case .downloadModel:
            guard !state.isDownloading else { return .none }

            state.downloadError = nil
            state.isDownloading = true
            state.downloadProgress = 0
            state.activeDownloadID = UUID()
            let downloadID = state.activeDownloadID!

            state.$bootstrapState.withLock {
                $0.isDownloading = true
                $0.progress = 0
                $0.lastError = nil
            }

            logger.info("Starting conversation model download")

            return .run { send in
                do {
                    try await conversation.prepareModel { progress in
                        Task {
                            await send(.downloadProgress(progress.fractionCompleted))
                        }
                    }
                    await send(.downloadCompleted(.success(())))
                } catch {
                    await send(.downloadCompleted(.failure(error)))
                }
            }
            .cancellable(id: downloadID)

        case let .downloadProgress(progress):
            state.downloadProgress = progress
            state.$bootstrapState.withLock { $0.progress = progress }
            return .none

        case let .downloadCompleted(result):
            state.isDownloading = false
            state.activeDownloadID = nil

            switch result {
            case .success:
                state.isModelDownloaded = true
                state.downloadError = nil
                state.$bootstrapState.withLock {
                    $0.isModelReady = true
                    $0.isDownloading = false
                    $0.progress = 1.0
                    $0.lastError = nil
                }
                logger.info("Conversation model download completed successfully")

            case let .failure(error):
                let message = error.localizedDescription
                state.downloadError = message
                state.$bootstrapState.withLock {
                    $0.isModelReady = false
                    $0.isDownloading = false
                    $0.lastError = message
                    $0.progress = 0
                }
                logger.error("Conversation model download failed: \(message)")
            }
            return .none

        case .cancelDownload:
            guard let id = state.activeDownloadID else { return .none }

            state.isDownloading = false
            state.activeDownloadID = nil
            state.$bootstrapState.withLock {
                $0.isDownloading = false
                $0.progress = 0
                $0.lastError = "Download cancelled"
            }
            logger.info("Conversation model download cancelled")
            return .cancel(id: id)

        case .openModelLocation:
            return .run { _ in
                let fm = FileManager.default

                // MoshiKit stores models in the app container's cache
                let base: URL
                if let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "com.kitlangton.Hex") {
                    base = containerURL
                        .appendingPathComponent("Library/Application Support/MoshiKit/Models", isDirectory: true)
                } else {
                    base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("MoshiKit/Models", isDirectory: true)
                }

                if !fm.fileExists(atPath: base.path) {
                    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
                }
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: base.path)
            }
        }
    }
}
