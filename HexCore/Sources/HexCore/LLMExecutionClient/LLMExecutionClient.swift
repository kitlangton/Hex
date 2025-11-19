import Dependencies
import Foundation

public struct LLMExecutionClient: Sendable {
    public var run: @Sendable (
        _ config: LLMTransformationConfig,
        _ input: String,
        _ providers: [LLMProvider],
        _ toolServer: HexToolServerClient,
        _ preferences: LLMProviderPreferences
    ) async throws -> String
}

extension LLMExecutionClient: DependencyKey {
    public static let liveValue = LLMExecutionClient(
        run: { config, input, providers, toolServer, preferences in
            try await runLLMProvider(
                config: config,
                input: input,
                providers: providers,
                toolServer: toolServer,
                preferences: preferences
            )
        }
    )
    
    public static let testValue = LLMExecutionClient(
        run: { _, _, _, _, _ in
            return "Test Output"
        }
    )
}

public extension DependencyValues {
    var llmExecution: LLMExecutionClient {
        get { self[LLMExecutionClient.self] }
        set { self[LLMExecutionClient.self] = newValue }
    }
}

// MARK: - Implementation

private let logger = HexLog.llm

private func runLLMProvider(
    config: LLMTransformationConfig,
    input: String,
    providers: [LLMProvider],
    toolServer: HexToolServerClient,
    preferences: LLMProviderPreferences
) async throws -> String {
    logger.info("Running LLM transformation with provider hint: \(config.providerID)")

    var resolution = try resolveProvider(
        config: config,
        providers: providers,
        preferences: preferences
    )

    if let preferredModel = preferences.preferredModelID,
       preferences.preferredProviderID == resolution.provider.id || resolution.shouldApplyPreferredModel {
        logger.info("Overriding model for provider \(resolution.provider.id) with preferred model \(preferredModel)")
        resolution.provider.defaultModel = preferredModel
    }

    let runtime = try runtime(for: resolution.provider)
    let capabilities = LLMProviderCapabilitiesResolver.capabilities(for: resolution.provider)
    let toolingPolicy = ToolingPolicy(
        capabilities: capabilities,
        transformationTooling: config.tooling,
        providerTooling: resolution.provider.tooling
    )

    if let reason = toolingPolicy.disabledReason {
        logger.info("Tool server disabled: \(reason)")
    }

    let serverEndpoint: HexToolServerEndpoint?
    if let configuration = toolingPolicy.serverConfiguration {
        if !configuration.enabledToolGroups.isEmpty {
            logger.info("Configuring MCP server with tool groups: \(configuration.enabledToolGroups.map { $0.rawValue }.joined(separator: ","))")
        }
        let endpoint = try await toolServer.ensureServer(configuration)
        logger.info("MCP server ready at \(endpoint.baseURL)")
        serverEndpoint = endpoint
    } else {
        serverEndpoint = nil
    }

    return try await runtime.run(
        config: config,
        input: input,
        provider: resolution.provider,
        toolingPolicy: toolingPolicy,
        toolServerEndpoint: serverEndpoint,
        capabilities: capabilities
    )
}

private func resolveProvider(
    config: LLMTransformationConfig,
    providers: [LLMProvider],
    preferences: LLMProviderPreferences
) throws -> ProviderResolution {
    if let exact = providers.first(where: { $0.id == config.providerID }) {
        return ProviderResolution(provider: exact, shouldApplyPreferredModel: false)
    }

    let requestPreferred = config.providerID == LLMProvider.preferredProviderIdentifier

    if requestPreferred,
       let preferredID = preferences.preferredProviderID,
       let provider = providers.first(where: { $0.id == preferredID }) {
        return ProviderResolution(provider: provider, shouldApplyPreferredModel: true)
    }

    if let preferredID = preferences.preferredProviderID,
       let provider = providers.first(where: { $0.id == preferredID }) {
        logger.info("Provider \(config.providerID) missing; falling back to preferred provider \(preferredID)")
        return ProviderResolution(provider: provider, shouldApplyPreferredModel: requestPreferred)
    }

    if let fallback = providers.first {
        logger.warning("Provider \(config.providerID) missing; falling back to first available provider \(fallback.id)")
        return ProviderResolution(provider: fallback, shouldApplyPreferredModel: requestPreferred)
    }

    throw LLMExecutionError.providerNotFound(config.providerID)
}

private func runtime(for provider: LLMProvider) throws -> LLMProviderRuntime {
    switch provider.type {
    case .claudeCode:
        return ClaudeCodeProviderRuntime()
    case .ollama:
        return OllamaProviderRuntime()
    default:
        throw LLMExecutionError.unsupportedProvider(provider.type.rawValue)
    }
}

func buildLLMUserPrompt(config: LLMTransformationConfig, input: String) -> String {
    let userPrompt = config.promptTemplate.replacingOccurrences(of: "{{input}}", with: input)
    return """
\(userPrompt)

IMPORTANT: Output ONLY the final result. Do not add commentary or explanations—just the transformed text.
"""
}

private struct ProviderResolution {
    var provider: LLMProvider
    var shouldApplyPreferredModel: Bool
}

public enum LLMExecutionError: Error, LocalizedError {
  case providerNotFound(String)
  case invalidConfiguration(String)
  case unsupportedProvider(String)
  case timeout
  case processFailed(String)
  case invalidOutput

  public var errorDescription: String? {
    switch self {
    case .providerNotFound(let id):
      return "LLM provider not found: \(id)"
    case .invalidConfiguration(let message):
      return "LLM provider configuration error: \(message)"
    case .unsupportedProvider(let type):
      return "LLM provider type \(type) is not supported yet"
    case .timeout:
      return "LLM execution timed out"
    case .processFailed(let message):
      return "LLM process failed: \(message)"
    case .invalidOutput:
      return "LLM returned invalid output"
    }
  }
}
