import Foundation

public enum LLMProviderCapabilitiesResolver {
    public static func capabilities(for provider: LLMProvider) -> LLMProviderCapabilities {
        var capabilities = defaultCapabilities(for: provider.type)
        if let metadata = LLMModelRegistry.shared.metadata(for: provider.type, modelID: provider.defaultModel) {
            if let supports = metadata.supportsToolCalling {
                capabilities.supportsToolCalling = supports
            }
            if let context = metadata.context {
                capabilities.maxContextTokens = context
            }
            if let reliability = metadata.toolReliability {
                capabilities.toolReliability = reliability
            }
        }
        return capabilities
    }

    public static func defaultCapabilities(for type: LLMProvider.ProviderType) -> LLMProviderCapabilities {
        switch type {
        case .claudeCode:
            return LLMProviderCapabilities(
                supportsToolCalling: true,
                supportsStreaming: false,
                maxContextTokens: 200_000,
                toolReliability: .stable,
                requiresNetwork: true
            )
        case .ollama:
            return LLMProviderCapabilities(
                supportsToolCalling: false,
                supportsStreaming: true,
                maxContextTokens: nil,
                toolReliability: .none,
                requiresNetwork: false
            )
        case .anthropicAPI, .openAI:
            return LLMProviderCapabilities(
                supportsToolCalling: true,
                supportsStreaming: true,
                maxContextTokens: nil,
                toolReliability: .experimental,
                requiresNetwork: true
            )
        }
    }
}
