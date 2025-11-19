import Foundation

public struct LLMProviderCapabilities: Sendable, Equatable {
    public enum ToolReliability: String, Codable, Sendable {
        case none
        case experimental
        case stable
    }

    public var supportsToolCalling: Bool
    public var supportsStreaming: Bool
    public var maxContextTokens: Int?
    public var toolReliability: ToolReliability
    public var requiresNetwork: Bool

    public init(
        supportsToolCalling: Bool,
        supportsStreaming: Bool,
        maxContextTokens: Int? = nil,
        toolReliability: ToolReliability,
        requiresNetwork: Bool
    ) {
        self.supportsToolCalling = supportsToolCalling
        self.supportsStreaming = supportsStreaming
        self.maxContextTokens = maxContextTokens
        self.toolReliability = toolReliability
        self.requiresNetwork = requiresNetwork
    }
}

struct ToolingPolicy: Sendable {
    let capabilities: LLMProviderCapabilities
    let requestedTooling: LLMProvider.ToolingConfiguration?
    let effectiveTooling: LLMProvider.ToolingConfiguration?
    let disabledReason: String?

    init(
        capabilities: LLMProviderCapabilities,
        transformationTooling: LLMProvider.ToolingConfiguration?,
        providerTooling: LLMProvider.ToolingConfiguration?
    ) {
        self.capabilities = capabilities
        let requested = transformationTooling ?? providerTooling
        self.requestedTooling = requested

        if capabilities.supportsToolCalling, capabilities.toolReliability != .none {
            self.effectiveTooling = requested
            self.disabledReason = nil
        } else if requested != nil {
            self.effectiveTooling = nil
            if !capabilities.supportsToolCalling {
                self.disabledReason = "Provider does not support tool calling"
            } else {
                self.disabledReason = "Tool reliability set to \(capabilities.toolReliability.rawValue)"
            }
        } else {
            self.effectiveTooling = nil
            self.disabledReason = nil
        }
    }

    var shouldStartToolServer: Bool {
        effectiveTooling?.serverConfiguration() != nil
    }

    var serverConfiguration: HexToolServerConfiguration? {
        effectiveTooling?.serverConfiguration()
    }

    var allowedToolIdentifiers: Set<String> {
        guard let effectiveTooling else { return [] }
        return Set(effectiveTooling.enabledToolGroups.flatMap { $0.toolIdentifiers })
    }
}
