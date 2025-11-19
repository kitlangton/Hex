import Foundation

public struct LLMProvider: Codable, Equatable, Identifiable, Sendable {
	public enum ProviderType: String, Codable, Sendable {
		case claudeCode = "claude_code"
		case anthropicAPI = "anthropic_api"
		case openAI = "openai"
		case ollama = "ollama"
	}
	
	public struct ToolingConfiguration: Codable, Equatable, Sendable {
		public var enabledToolGroups: [HexToolGroup]
		public var instructions: String?
		
		public init(enabledToolGroups: [HexToolGroup], instructions: String? = nil) {
			self.enabledToolGroups = enabledToolGroups
			self.instructions = instructions
		}
	}

	public struct SecretReference: Codable, Equatable, Sendable {
		public enum Storage: String, Codable, Sendable {
			case literal
			case environment
		}

		public var storage: Storage
		public var value: String

		public init(storage: Storage, value: String) {
			self.storage = storage
			self.value = value
		}

		public func resolve(using environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
			switch storage {
			case .literal:
				return value
			case .environment:
				return environment[value]
			}
		}
	}

	public var id: String
	public var displayName: String?
	public var type: ProviderType

	// Claude Code / CLI configuration
	public var binaryPath: String?
	public var workingDirectory: String?

	// Shared
	public var defaultModel: String?
	public var timeoutSeconds: Int?

	// HTTP providers (Anthropic/OpenAI)
	public var baseURL: String?
	public var apiKey: SecretReference?
	public var organization: String?
	
	// Tool server configuration
	public var tooling: ToolingConfiguration?

	public init(
		id: String,
		displayName: String? = nil,
		type: ProviderType,
		binaryPath: String? = nil,
		workingDirectory: String? = nil,
		defaultModel: String? = nil,
		timeoutSeconds: Int? = nil,
		baseURL: String? = nil,
		apiKey: SecretReference? = nil,
		organization: String? = nil,
		tooling: ToolingConfiguration? = nil
	) {
		self.id = id
		self.displayName = displayName
		self.type = type
		self.binaryPath = binaryPath
		self.workingDirectory = workingDirectory
		self.defaultModel = defaultModel
		self.timeoutSeconds = timeoutSeconds
		self.baseURL = baseURL
		self.apiKey = apiKey
		self.organization = organization
		self.tooling = tooling
	}
}

public extension LLMProvider.ToolingConfiguration {
	func serverConfiguration() -> HexToolServerConfiguration? {
		guard !enabledToolGroups.isEmpty else { return nil }
		return HexToolServerConfiguration(enabledToolGroups: enabledToolGroups, instructions: instructions)
	}
}

public extension LLMProvider {
	static let preferredProviderIdentifier = "hex-preferred-provider"
}
