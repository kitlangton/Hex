import Foundation

public enum HexToolGroup: String, Codable, CaseIterable, Sendable, Hashable {
	case appControl = "app-control"
	
	public var description: String {
		switch self {
		case .appControl:
			return "Launches or focuses macOS applications by bundle identifier."
		}
	}

	public var toolIdentifiers: [String] {
		switch self {
		case .appControl:
			return ["hex-tools:openApplication"]
		}
	}
}

public struct HexToolServerConfiguration: Codable, Equatable, Sendable {
	public var enabledToolGroups: [HexToolGroup]
	public var instructions: String?
	
	public init(
		enabledToolGroups: [HexToolGroup],
		instructions: String? = nil
	) {
		self.enabledToolGroups = enabledToolGroups
		self.instructions = instructions
	}
}

public struct HexToolServerEndpoint: Equatable, Sendable {
	public var baseURL: URL
	public var serverName: String
	public var instructions: String?
	
	public init(baseURL: URL, serverName: String, instructions: String?) {
		self.baseURL = baseURL
		self.serverName = serverName
		self.instructions = instructions
	}
}
