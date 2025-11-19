import Foundation

protocol LLMProviderRuntime {
    func run(
        config: LLMTransformationConfig,
        input: String,
        provider: LLMProvider,
        toolingPolicy: ToolingPolicy,
        toolServerEndpoint: HexToolServerEndpoint?,
        capabilities: LLMProviderCapabilities
    ) async throws -> String
}
