//
//  ConversationClient.swift
//  Hex
//
//  A client that manages PersonaPlex MLX subprocess for full-duplex speech conversations.
//

import Dependencies
import DependenciesMacros
import Foundation
import HexCore

// MARK: - ConversationClient

/// A client that manages PersonaPlex MLX for full-duplex speech conversations.
/// Handles subprocess lifecycle, pipe-based communication, and state management.
@DependencyClient
struct ConversationClient: Sendable {
    /// Start a conversation session with the given configuration
    var startSession: @Sendable (ConversationConfig) async throws -> Void

    /// Stop the current conversation session
    var stopSession: @Sendable () async -> Void

    /// Check if a session is currently active
    var isSessionActive: @Sendable () -> Bool = { false }

    /// Stream of transcript text (what PersonaPlex says)
    var transcriptStream: @Sendable () -> AsyncStream<String> = { AsyncStream { $0.finish() } }

    /// Stream of conversation state changes
    var stateStream: @Sendable () -> AsyncStream<ConversationState> = { AsyncStream { $0.finish() } }

    /// Load a persona configuration
    var loadPersona: @Sendable (PersonaConfig) async throws -> Void

    /// Get available voice presets
    var getVoicePresets: @Sendable () async -> [VoicePreset] = { VoicePreset.allPresets }

    /// Download/prepare the model, reporting progress via callback
    var prepareModel: @Sendable (@escaping (Progress) -> Void) async throws -> Void

    /// Check if the conversation model is ready
    var isModelReady: @Sendable () async -> Bool = { false }

    /// Cleanup resources (terminate subprocess, release memory)
    var cleanup: @Sendable () async -> Void
}

// MARK: - DependencyKey
// The live implementation is provided by ConversationClientLive in ConversationClientLive.swift

extension ConversationClient: DependencyKey {
    static var liveValue: Self {
        // Use native MoshiKit implementation if available, otherwise fall back to Python subprocess
        #if canImport(MoshiKit)
        let native = ConversationClientNative()
        return Self(
            startSession: { try await native.startSession($0) },
            stopSession: { await native.stopSession() },
            isSessionActive: { native.isSessionActiveSync },
            transcriptStream: { native.transcriptStream() },
            stateStream: { native.stateStream() },
            loadPersona: { try await native.loadPersona($0) },
            getVoicePresets: { await native.getVoicePresets() },
            prepareModel: { try await native.prepareModel(progressCallback: $0) },
            isModelReady: { await native.isModelReady() },
            cleanup: { await native.cleanup() }
        )
        #else
        // Fall back to Python subprocess implementation
        let live = ConversationClientLive()
        return Self(
            startSession: { try await live.startSession($0) },
            stopSession: { await live.stopSession() },
            isSessionActive: { live.isSessionActiveSync },
            transcriptStream: { live.transcriptStream() },
            stateStream: { live.stateStream() },
            loadPersona: { try await live.loadPersona($0) },
            getVoicePresets: { await live.getVoicePresets() },
            prepareModel: { try await live.prepareModel(progressCallback: $0) },
            isModelReady: { await live.isModelReady() },
            cleanup: { await live.cleanup() }
        )
        #endif
    }

    static var testValue: Self {
        Self()
    }

    static var previewValue: Self {
        Self(
            startSession: { _ in },
            stopSession: { },
            isSessionActive: { false },
            transcriptStream: { AsyncStream { $0.finish() } },
            stateStream: {
                AsyncStream { continuation in
                    continuation.yield(.idle)
                    continuation.finish()
                }
            },
            loadPersona: { _ in },
            getVoicePresets: { VoicePreset.allPresets },
            prepareModel: { _ in },
            isModelReady: { true },
            cleanup: { }
        )
    }
}

// MARK: - DependencyValues

extension DependencyValues {
    var conversation: ConversationClient {
        get { self[ConversationClient.self] }
        set { self[ConversationClient.self] = newValue }
    }
}
