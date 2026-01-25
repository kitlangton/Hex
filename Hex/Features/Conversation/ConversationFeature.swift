//
//  ConversationFeature.swift
//  Hex
//
//  TCA Reducer for Conversation Mode with PersonaPlex integration.
//

import ComposableArchitecture
import Foundation
import HexCore

private let conversationFeatureLogger = HexLog.conversation

// MARK: - Shared State Keys

extension SharedReaderKey
    where Self == InMemoryKey<[PersonaConfig]>.Default
{
    static var conversationPersonas: Self {
        Self[
            .inMemory("conversationPersonas"),
            default: [PersonaConfig.default]
        ]
    }
}

// MARK: - ConversationFeature Reducer

@Reducer
struct ConversationFeature {
    @ObservableState
    struct State: Equatable {
        // Session state
        var sessionState: ConversationState = .idle
        var isActive: Bool = false

        // Current conversation
        var currentTranscript: String = ""
        var conversationHistory: [ConversationTurn] = []

        // Audio levels (for visualization)
        var inputLevel: Float = 0
        var outputLevel: Float = 0

        // Error handling
        var error: String?

        // Shared state
        @Shared(.hexSettings) var hexSettings: HexSettings
        @Shared(.conversationPersonas) var personas: [PersonaConfig]

        /// Returns the currently selected persona, if any
        var selectedPersona: PersonaConfig? {
            guard let selectedID = hexSettings.selectedPersonaID else {
                return personas.first
            }
            return personas.first { $0.id == selectedID }
        }
    }

    enum Action: Equatable {
        // Lifecycle
        case task
        case onDisappear

        // Session control
        case startConversation
        case stopConversation
        case toggleConversation

        // Persona management
        case selectPersona(UUID)
        case createPersona(PersonaConfig)
        case deletePersona(UUID)
        case updatePersona(PersonaConfig)

        // Model management
        case prepareModel
        case modelProgress(Double)
        case modelReady
        case modelError(String)

        // Conversation events
        case transcriptReceived(String)
        case stateChanged(ConversationState)
        case audioLevelsUpdated(inputLevel: Float, outputLevel: Float)
        case conversationError(String)

        // History management
        case appendTurn(ConversationTurn)
        case clearHistory

        // Internal
        case _sessionStarted
        case _sessionEnded
    }

    enum CancelID {
        case conversation
        case audioLevels
        case transcriptStream
        case stateStream
    }

    @Dependency(\.conversation) var conversation
    @Dependency(\.soundEffects) var soundEffects

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            // MARK: - Lifecycle

            case .task:
                return .merge(
                    startStateMonitoring(),
                    syncPersonaSelection(&state)
                )

            case .onDisappear:
                return .merge(
                    .cancel(id: CancelID.conversation),
                    .cancel(id: CancelID.audioLevels),
                    .cancel(id: CancelID.transcriptStream),
                    .cancel(id: CancelID.stateStream)
                )

            // MARK: - Session Control

            case .startConversation:
                return handleStartConversation(&state)

            case .stopConversation:
                return handleStopConversation(&state)

            case .toggleConversation:
                if state.isActive {
                    return .send(.stopConversation)
                } else {
                    return .send(.startConversation)
                }

            // MARK: - Persona Management

            case let .selectPersona(id):
                state.$hexSettings.withLock { $0.selectedPersonaID = id }
                conversationFeatureLogger.notice("Selected persona: \(id)")
                return .none

            case let .createPersona(persona):
                state.$personas.withLock { $0.append(persona) }
                conversationFeatureLogger.notice("Created persona: \(persona.name)")
                return .none

            case let .deletePersona(id):
                state.$personas.withLock { personas in
                    personas.removeAll { $0.id == id }
                }
                // If deleted persona was selected, select the first available
                if state.hexSettings.selectedPersonaID == id {
                    state.$hexSettings.withLock { $0.selectedPersonaID = state.personas.first?.id }
                }
                conversationFeatureLogger.notice("Deleted persona: \(id)")
                return .none

            case let .updatePersona(updatedPersona):
                state.$personas.withLock { personas in
                    if let index = personas.firstIndex(where: { $0.id == updatedPersona.id }) {
                        personas[index] = updatedPersona
                    }
                }
                conversationFeatureLogger.notice("Updated persona: \(updatedPersona.name)")
                return .none

            // MARK: - Model Management

            case .prepareModel:
                state.sessionState = .loading(progress: 0)
                return .run { send in
                    do {
                        try await conversation.prepareModel { progress in
                            Task { @MainActor in
                                await send(.modelProgress(progress.fractionCompleted))
                            }
                        }
                        await send(.modelReady)
                    } catch {
                        await send(.modelError(error.localizedDescription))
                    }
                }

            case let .modelProgress(progress):
                state.sessionState = .loading(progress: progress)
                return .none

            case .modelReady:
                state.sessionState = .ready
                conversationFeatureLogger.notice("Conversation model ready")
                return .none

            case let .modelError(errorMessage):
                state.sessionState = .error(errorMessage)
                state.error = errorMessage
                conversationFeatureLogger.error("Model error: \(errorMessage)")
                return .none

            // MARK: - Conversation Events

            case let .transcriptReceived(text):
                state.currentTranscript = text
                conversationFeatureLogger.debug("Transcript received: \(text, privacy: .private)")
                return .none

            case let .stateChanged(newState):
                state.sessionState = newState

                // Update isActive based on session state
                if case .active = newState {
                    state.isActive = true
                } else if case .idle = newState {
                    state.isActive = false
                }

                return .none

            case let .audioLevelsUpdated(inputLevel, outputLevel):
                state.inputLevel = inputLevel
                state.outputLevel = outputLevel
                return .none

            case let .conversationError(errorMessage):
                state.error = errorMessage
                state.sessionState = .error(errorMessage)
                state.isActive = false
                conversationFeatureLogger.error("Conversation error: \(errorMessage)")
                return .run { _ in
                    soundEffects.play(.cancel)
                }

            // MARK: - History Management

            case let .appendTurn(turn):
                state.conversationHistory.append(turn)
                return .none

            case .clearHistory:
                state.conversationHistory.removeAll()
                state.currentTranscript = ""
                return .none

            // MARK: - Internal

            case ._sessionStarted:
                conversationFeatureLogger.notice("Conversation session started")
                return .none

            case ._sessionEnded:
                conversationFeatureLogger.notice("Conversation session ended")
                return .none
            }
        }
    }
}

// MARK: - Effect Helpers

private extension ConversationFeature {

    func startStateMonitoring() -> Effect<Action> {
        .run { send in
            for await newState in conversation.stateStream() {
                await send(.stateChanged(newState))
            }
        }
        .cancellable(id: CancelID.stateStream, cancelInFlight: true)
    }

    func syncPersonaSelection(_ state: inout State) -> Effect<Action> {
        // Ensure a persona is selected if none is
        if state.hexSettings.selectedPersonaID == nil, let firstPersona = state.personas.first {
            state.$hexSettings.withLock { $0.selectedPersonaID = firstPersona.id }
        }
        return .none
    }

    func handleStartConversation(_ state: inout State) -> Effect<Action> {
        guard let persona = state.selectedPersona else {
            conversationFeatureLogger.error("Cannot start conversation: no persona selected")
            return .send(.conversationError("No persona selected"))
        }

        // Check if model is ready
        guard state.sessionState == .ready || state.sessionState == .idle else {
            if state.sessionState.isLoading {
                conversationFeatureLogger.notice("Model still loading, cannot start conversation yet")
                return .none
            }
            // Try to prepare model first
            return .send(.prepareModel)
        }

        state.isActive = true
        state.error = nil
        state.currentTranscript = ""

        let config = ConversationConfig(
            persona: persona,
            inputDeviceID: state.hexSettings.selectedMicrophoneID
        )

        conversationFeatureLogger.notice("Starting conversation with persona: \(persona.name)")

        return .run { send in
            await send(.stateChanged(.loading(progress: 0)))

            do {
                try await conversation.startSession(config)
                await send(.stateChanged(.active(speaking: false, listening: true)))
                await send(._sessionStarted)

                // Start listening to transcript stream
                for await text in conversation.transcriptStream() {
                    await send(.transcriptReceived(text))
                }

                await send(._sessionEnded)
            } catch {
                await send(.conversationError(error.localizedDescription))
            }
        } catch: { error, send in
            await send(.conversationError(error.localizedDescription))
        }
        .cancellable(id: CancelID.conversation, cancelInFlight: true)
    }

    func handleStopConversation(_ state: inout State) -> Effect<Action> {
        guard state.isActive else {
            return .none
        }

        state.isActive = false
        state.sessionState = .idle

        conversationFeatureLogger.notice("Stopping conversation")

        return .merge(
            .cancel(id: CancelID.conversation),
            .cancel(id: CancelID.transcriptStream),
            .run { send in
                await conversation.stopSession()
                await send(._sessionEnded)
            }
        )
    }
}
