import ComposableArchitecture

/// Bootstrap state for conversation mode models (MoshiKit).
/// Tracks download progress and model readiness separately from transcription models.
struct ConversationModelBootstrapState: Equatable {
    /// Whether the conversation model is downloaded and ready to use
    var isModelReady: Bool = false

    /// Download/load progress (0.0 - 1.0)
    var progress: Double = 0

    /// Last error message, if any
    var lastError: String?

    /// Model identifier (e.g., "kyutai/moshiko-mlx-bf16")
    var modelIdentifier: String = "kyutai/moshiko-mlx-bf16"

    /// Display name for UI
    var modelDisplayName: String = "Moshi"

    /// Estimated model size for display
    var modelSize: String = "~3 GB"

    /// Whether a download is currently in progress
    var isDownloading: Bool = false
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
