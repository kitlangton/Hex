import ComposableArchitecture

/// Download state for a single conversation model
struct ConversationModelDownloadState: Equatable {
    /// Whether the model is downloaded and ready to use
    var isModelReady: Bool = false

    /// Download/load progress (0.0 - 1.0)
    var progress: Double = 0

    /// Last error message, if any
    var lastError: String?

    /// Whether a download is currently in progress
    var isDownloading: Bool = false
}

/// Bootstrap state for conversation mode models.
/// Tracks download progress and model readiness for multiple model types.
struct ConversationModelBootstrapState: Equatable {
    /// Download states keyed by model type
    var modelStates: [ConversationModelType: ConversationModelDownloadState] = [:]

    /// Currently selected conversation model
    var selectedModelType: ConversationModelType = .moshi

    // MARK: - Convenience accessors for selected model

    /// Whether the selected conversation model is downloaded and ready to use
    var isModelReady: Bool {
        get { modelStates[selectedModelType]?.isModelReady ?? false }
        set {
            ensureStateExists(for: selectedModelType)
            modelStates[selectedModelType]?.isModelReady = newValue
        }
    }

    /// Download/load progress (0.0 - 1.0) for selected model
    var progress: Double {
        get { modelStates[selectedModelType]?.progress ?? 0 }
        set {
            ensureStateExists(for: selectedModelType)
            modelStates[selectedModelType]?.progress = newValue
        }
    }

    /// Last error message for selected model, if any
    var lastError: String? {
        get { modelStates[selectedModelType]?.lastError }
        set {
            ensureStateExists(for: selectedModelType)
            modelStates[selectedModelType]?.lastError = newValue
        }
    }

    /// Whether a download is currently in progress for selected model
    var isDownloading: Bool {
        get { modelStates[selectedModelType]?.isDownloading ?? false }
        set {
            ensureStateExists(for: selectedModelType)
            modelStates[selectedModelType]?.isDownloading = newValue
        }
    }

    /// Model identifier for selected model (for backward compatibility)
    var modelIdentifier: String {
        selectedModelType.primaryIdentifier
    }

    /// Display name for selected model (for backward compatibility)
    var modelDisplayName: String {
        selectedModelType.displayName
    }

    /// Estimated model size for selected model (for backward compatibility)
    var modelSize: String {
        selectedModelType.estimatedSize
    }

    // MARK: - Per-model accessors

    /// Get download state for a specific model type
    func state(for modelType: ConversationModelType) -> ConversationModelDownloadState {
        modelStates[modelType] ?? ConversationModelDownloadState()
    }

    /// Check if a specific model is ready
    func isReady(_ modelType: ConversationModelType) -> Bool {
        modelStates[modelType]?.isModelReady ?? false
    }

    /// Check if a specific model is downloading
    func isDownloading(_ modelType: ConversationModelType) -> Bool {
        modelStates[modelType]?.isDownloading ?? false
    }

    /// Get progress for a specific model
    func progress(for modelType: ConversationModelType) -> Double {
        modelStates[modelType]?.progress ?? 0
    }

    /// Get error for a specific model
    func error(for modelType: ConversationModelType) -> String? {
        modelStates[modelType]?.lastError
    }

    // MARK: - Mutating helpers

    private mutating func ensureStateExists(for modelType: ConversationModelType) {
        if modelStates[modelType] == nil {
            modelStates[modelType] = ConversationModelDownloadState()
        }
    }

    mutating func updateState(for modelType: ConversationModelType, _ update: (inout ConversationModelDownloadState) -> Void) {
        ensureStateExists(for: modelType)
        update(&modelStates[modelType]!)
    }
}

extension SharedReaderKey
    where Self == InMemoryKey<ConversationModelBootstrapState>.Default
{
    static var conversationModelBootstrapState: Self {
        Self[
            .inMemory("conversationModelBootstrapState"),
            default: .init()
        ]
    }
}
