// MARK: – ConversationModelDownloadFeature.swift

// TCA reducer for managing conversation model downloads (Moshi, PersonaPlex).
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

        // Per-model download state
        public var modelDownloadStates: [ConversationModelType: ModelDownloadState] = [:]

        // Active downloads keyed by model type
        var activeDownloadIDs: [ConversationModelType: UUID] = [:]

        public init() {
            // Initialize download states for all model types
            for modelType in ConversationModelType.allCases {
                modelDownloadStates[modelType] = ModelDownloadState()
            }
        }

        // MARK: - Per-model state

        public struct ModelDownloadState: Equatable {
            public var isDownloading = false
            public var downloadProgress: Double = 0
            public var downloadError: String?
            public var isModelDownloaded = false
        }

        // MARK: - Computed properties

        /// The currently selected conversation model type (read-only from state, use selectModel action to change)
        public var selectedModelType: ConversationModelType {
            ConversationModelType(rawValue: hexSettings.selectedConversationModel) ?? .moshi
        }

        /// Get state for a specific model
        public func downloadState(for modelType: ConversationModelType) -> ModelDownloadState {
            modelDownloadStates[modelType] ?? ModelDownloadState()
        }

        /// Check if any model is currently downloading
        public var isAnyDownloading: Bool {
            modelDownloadStates.values.contains { $0.isDownloading }
        }
    }

    // MARK: Actions

    public enum Action: BindableAction {
        case binding(BindingAction<State>)

        // Lifecycle
        case task
        case checkAllModelStatuses

        // Model selection
        case selectModel(ConversationModelType)

        // Download actions (per model)
        case downloadModel(ConversationModelType)
        case downloadProgress(ConversationModelType, Double)
        case downloadCompleted(ConversationModelType, Result<Void, Error>)
        case cancelDownload(ConversationModelType)

        // Status updates (per model)
        case modelStatusChecked(ConversationModelType, Bool)

        // UI
        case openModelLocation(ConversationModelType)
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
            return .send(.checkAllModelStatuses)

        case .checkAllModelStatuses:
            return .merge(
                ConversationModelType.allCases.map { modelType in
                    .run { send in
                        let isReady = await checkModelReady(modelType)
                        await send(.modelStatusChecked(modelType, isReady))
                    }
                }
            )

        case let .selectModel(modelType):
            state.$hexSettings.withLock {
                $0.selectedConversationModel = modelType.rawValue
            }
            state.$bootstrapState.withLock {
                $0.selectedModelType = modelType
            }
            return .none

        case let .modelStatusChecked(modelType, isReady):
            state.modelDownloadStates[modelType]?.isModelDownloaded = isReady
            state.$bootstrapState.withLock {
                $0.updateState(for: modelType) { downloadState in
                    downloadState.isModelReady = isReady
                    if isReady {
                        downloadState.progress = 1.0
                        downloadState.lastError = nil
                    }
                }
            }
            return .none

        // MARK: – Download

        case let .downloadModel(modelType):
            guard state.modelDownloadStates[modelType]?.isDownloading != true else { return .none }

            state.modelDownloadStates[modelType]?.downloadError = nil
            state.modelDownloadStates[modelType]?.isDownloading = true
            state.modelDownloadStates[modelType]?.downloadProgress = 0
            let downloadID = UUID()
            state.activeDownloadIDs[modelType] = downloadID

            state.$bootstrapState.withLock {
                $0.updateState(for: modelType) { downloadState in
                    downloadState.isDownloading = true
                    downloadState.progress = 0
                    downloadState.lastError = nil
                }
            }

            logger.info("Starting \(modelType.displayName) model download")

            return .run { send in
                do {
                    try await downloadModel(modelType) { progress in
                        Task {
                            await send(.downloadProgress(modelType, progress.fractionCompleted))
                        }
                    }
                    await send(.downloadCompleted(modelType, .success(())))
                } catch {
                    await send(.downloadCompleted(modelType, .failure(error)))
                }
            }
            .cancellable(id: downloadID)

        case let .downloadProgress(modelType, progress):
            state.modelDownloadStates[modelType]?.downloadProgress = progress
            state.$bootstrapState.withLock {
                $0.updateState(for: modelType) { downloadState in
                    downloadState.progress = progress
                }
            }
            return .none

        case let .downloadCompleted(modelType, result):
            state.modelDownloadStates[modelType]?.isDownloading = false
            state.activeDownloadIDs[modelType] = nil

            switch result {
            case .success:
                state.modelDownloadStates[modelType]?.isModelDownloaded = true
                state.modelDownloadStates[modelType]?.downloadError = nil
                state.$bootstrapState.withLock {
                    $0.updateState(for: modelType) { downloadState in
                        downloadState.isModelReady = true
                        downloadState.isDownloading = false
                        downloadState.progress = 1.0
                        downloadState.lastError = nil
                    }
                }
                logger.info("\(modelType.displayName) model download completed successfully")

            case let .failure(error):
                let message = error.localizedDescription
                state.modelDownloadStates[modelType]?.downloadError = message
                state.$bootstrapState.withLock {
                    $0.updateState(for: modelType) { downloadState in
                        downloadState.isModelReady = false
                        downloadState.isDownloading = false
                        downloadState.lastError = message
                        downloadState.progress = 0
                    }
                }
                logger.error("\(modelType.displayName) model download failed: \(message)")
            }
            return .none

        case let .cancelDownload(modelType):
            guard let id = state.activeDownloadIDs[modelType] else { return .none }

            state.modelDownloadStates[modelType]?.isDownloading = false
            state.activeDownloadIDs[modelType] = nil
            state.$bootstrapState.withLock {
                $0.updateState(for: modelType) { downloadState in
                    downloadState.isDownloading = false
                    downloadState.progress = 0
                    downloadState.lastError = "Download cancelled"
                }
            }
            logger.info("\(modelType.displayName) model download cancelled")
            return .cancel(id: id)

        case let .openModelLocation(modelType):
            return .run { _ in
                let fm = FileManager.default
                let base = modelStorageURL(for: modelType)

                if !fm.fileExists(atPath: base.path) {
                    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
                }
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: base.path)
            }
        }
    }

    // MARK: - Private helpers

    private func checkModelReady(_ modelType: ConversationModelType) async -> Bool {
        // For now, check if the model directory exists and has content
        // In a real implementation, this would use the ConversationClient
        switch modelType {
        case .moshi:
            return await conversation.isModelReady()
        case .personaPlex:
            // Check if PersonaPlex model exists
            let url = modelStorageURL(for: .personaPlex)
            let fm = FileManager.default
            return fm.fileExists(atPath: url.path)
        }
    }

    private func downloadModel(_ modelType: ConversationModelType, progress: @escaping (Progress) -> Void) async throws {
        switch modelType {
        case .moshi:
            try await conversation.prepareModel(progress)
        case .personaPlex:
            // PersonaPlex download would go through a similar mechanism
            // For now, use conversation client if it supports it, otherwise throw
            try await conversation.prepareModel(progress)
        }
    }

    private func modelStorageURL(for modelType: ConversationModelType) -> URL {
        let fm = FileManager.default

        switch modelType {
        case .moshi:
            if let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "com.kitlangton.Hex") {
                return containerURL
                    .appendingPathComponent("Library/Application Support/MoshiKit/Models", isDirectory: true)
            } else {
                return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("MoshiKit/Models", isDirectory: true)
            }
        case .personaPlex:
            if let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "com.kitlangton.Hex") {
                return containerURL
                    .appendingPathComponent("Library/Application Support/PersonaPlex/Models", isDirectory: true)
            } else {
                return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("PersonaPlex/Models", isDirectory: true)
            }
        }
    }
}
