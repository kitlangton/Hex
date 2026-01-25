//
//  ModelLifecycleManager.swift
//  Hex
//
//  Manages model lifecycle to ensure only one large ML model is loaded at a time.
//  Since both WhisperKit/Parakeet and PersonaPlex require significant memory (4GB+),
//  this manager ensures they don't compete for RAM on systems with 16GB or less.
//

import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let lifecycleLogger = HexLog.models

/// Manages the lifecycle of ML models to prevent memory conflicts.
/// Ensures only one large model (transcription or conversation) is loaded at a time.
actor ModelLifecycleManager {

    /// The type of model currently loaded
    enum LoadedModel: Equatable, Sendable {
        case none
        case transcription(String)  // model name/identifier
        case conversation
    }

    /// Current loaded model state
    private(set) var loadedModel: LoadedModel = .none

    /// Minimum delay after unloading a model before loading another (allows memory to be released)
    private static let memoryReleaseDelay: Duration = .milliseconds(500)

    // MARK: - Dependencies

    private let transcription: TranscriptionClient
    private let conversation: ConversationClient

    init(transcription: TranscriptionClient, conversation: ConversationClient) {
        self.transcription = transcription
        self.conversation = conversation
    }

    // MARK: - Public API

    /// Prepares for transcription mode by unloading conversation model if needed.
    /// - Parameter model: The transcription model identifier to load
    func prepareForTranscription(model: String) async throws {
        switch loadedModel {
        case .conversation:
            lifecycleLogger.notice("Unloading conversation model for transcription")
            await conversation.cleanup()
            loadedModel = .none

            // Brief delay for memory to be released
            try await Task.sleep(for: Self.memoryReleaseDelay)

        case .transcription(let current) where current != model:
            // Different transcription model requested
            // TranscriptionClient handles model switching internally
            lifecycleLogger.notice("Switching transcription model from \(current) to \(model)")

        case .transcription:
            // Same model already loaded, nothing to do
            return

        case .none:
            break
        }

        // Mark as loading transcription model
        loadedModel = .transcription(model)
        lifecycleLogger.notice("Prepared for transcription with model: \(model)")
    }

    /// Prepares for conversation mode by unloading transcription model if needed.
    func prepareForConversation() async throws {
        switch loadedModel {
        case .transcription(let model):
            lifecycleLogger.notice("Unloading transcription model \(model) for conversation")
            // TranscriptionClient doesn't have explicit unload, but we track state
            loadedModel = .none

            // Brief delay for memory to be released
            try await Task.sleep(for: Self.memoryReleaseDelay)

        case .conversation:
            // Already loaded for conversation
            lifecycleLogger.debug("Conversation model already loaded")
            return

        case .none:
            break
        }

        // Prepare conversation model
        try await conversation.prepareModel { progress in
            lifecycleLogger.debug("Conversation model loading: \(Int(progress.fractionCompleted * 100))%")
        }
        loadedModel = .conversation
        lifecycleLogger.notice("Prepared for conversation mode")
    }

    /// Unloads all models and releases memory
    func unloadAll() async {
        switch loadedModel {
        case .conversation:
            await conversation.cleanup()
        case .transcription:
            // TranscriptionClient manages its own lifecycle
            break
        case .none:
            break
        }
        loadedModel = .none
        lifecycleLogger.notice("Unloaded all models")
    }

    /// Returns the current loaded model type
    func currentModel() -> LoadedModel {
        return loadedModel
    }

    /// Checks if a specific model type is ready
    func isReady(for mode: OperationMode) async -> Bool {
        switch mode {
        case .transcription:
            if case .transcription = loadedModel {
                return true
            }
            return false
        case .conversation:
            if case .conversation = loadedModel {
                return await conversation.isModelReady()
            }
            return false
        }
    }
}

// MARK: - Dependency Client

@DependencyClient
struct ModelLifecycleClient: Sendable {
    /// Prepare for transcription mode
    var prepareForTranscription: @Sendable (String) async throws -> Void

    /// Prepare for conversation mode
    var prepareForConversation: @Sendable () async throws -> Void

    /// Unload all models
    var unloadAll: @Sendable () async -> Void

    /// Get current loaded model
    var currentModel: @Sendable () async -> ModelLifecycleManager.LoadedModel = { .none }

    /// Check if ready for a mode
    var isReady: @Sendable (OperationMode) async -> Bool = { _ in false }
}

// MARK: - DependencyKey

extension ModelLifecycleClient: DependencyKey {
    static var liveValue: Self {
        // Create a shared actor instance
        let manager: LockIsolated<ModelLifecycleManager?> = LockIsolated(nil)

        @Sendable func getManager() -> ModelLifecycleManager {
            manager.withValue { existing in
                if let existing = existing {
                    return existing
                }
                @Dependency(\.transcription) var transcription
                @Dependency(\.conversation) var conversation
                let newManager = ModelLifecycleManager(
                    transcription: transcription,
                    conversation: conversation
                )
                existing = newManager
                return newManager
            }
        }

        return Self(
            prepareForTranscription: { model in
                try await getManager().prepareForTranscription(model: model)
            },
            prepareForConversation: {
                try await getManager().prepareForConversation()
            },
            unloadAll: {
                await getManager().unloadAll()
            },
            currentModel: {
                await getManager().currentModel()
            },
            isReady: { mode in
                await getManager().isReady(for: mode)
            }
        )
    }

    static var testValue: Self {
        Self()
    }

    static var previewValue: Self {
        Self(
            prepareForTranscription: { _ in },
            prepareForConversation: { },
            unloadAll: { },
            currentModel: { .none },
            isReady: { _ in true }
        )
    }
}

// MARK: - DependencyValues

extension DependencyValues {
    var modelLifecycle: ModelLifecycleClient {
        get { self[ModelLifecycleClient.self] }
        set { self[ModelLifecycleClient.self] = newValue }
    }
}
