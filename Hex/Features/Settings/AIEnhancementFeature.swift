//
//  AIEnhancementFeature.swift
//  Hex
//
//  Created by Claude AI on 4/22/25.
//

import ComposableArchitecture
import Foundation
import SwiftUI

@Reducer
struct AIEnhancementFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.hexSettings) var hexSettings: HexSettings
        
        var isOllamaAvailable: Bool = false
        var availableModels: [String] = []
        var isLoadingModels: Bool = false
        var errorMessage: String? = nil
        
        // Computed property for convenient access to the default model
        var defaultAIModel: String {
            "gemma3"
        }
    }
    
    enum Action {
        case task
        case checkOllamaAvailability
        case ollamaAvailabilityResult(Bool)
        case loadAvailableModels
        case modelsLoaded([String])
        case modelLoadingError(String)
        case setSelectedModel(String)
        case resetToDefaultPrompt
    }
    
    @Dependency(\.aiEnhancement) var aiEnhancement
    
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .send(.checkOllamaAvailability)
                
            case .checkOllamaAvailability:
                return .run { send in
                    let isAvailable = await aiEnhancement.isOllamaAvailable()
                    await send(.ollamaAvailabilityResult(isAvailable))
                }
                
            case let .ollamaAvailabilityResult(isAvailable):
                state.isOllamaAvailable = isAvailable
                
                // If Ollama is available, load models
                if isAvailable {
                    return .send(.loadAvailableModels)
                }
                return .none
                
            case .loadAvailableModels:
                state.isLoadingModels = true
                state.errorMessage = nil
                
                return .run { send in
                    do {
                        let models = try await aiEnhancement.getAvailableModels()
                        await send(.modelsLoaded(models))
                    } catch {
                        await send(.modelLoadingError(error.localizedDescription))
                    }
                }
                
            case let .modelsLoaded(models):
                state.isLoadingModels = false
                state.availableModels = models
                
                // If the selected model is not in the list and we have models, select the first one
                if !models.isEmpty && !models.contains(state.hexSettings.selectedAIModel) {
                    // Check if the default model is available
                    if models.contains(state.defaultAIModel) {
                        state.$hexSettings.withLock { $0.selectedAIModel = state.defaultAIModel }
                    } else {
                        state.$hexSettings.withLock { $0.selectedAIModel = models[0] }
                    }
                }
                
                return .none
                
            case let .modelLoadingError(message):
                state.isLoadingModels = false
                state.errorMessage = message
                return .none
                
            case let .setSelectedModel(model):
                state.$hexSettings.withLock { $0.selectedAIModel = model }
                return .none
                
            case .resetToDefaultPrompt:
                state.$hexSettings.withLock { $0.aiEnhancementPrompt = EnhancementOptions.defaultPrompt }
                return .none
            }
        }
    }
}