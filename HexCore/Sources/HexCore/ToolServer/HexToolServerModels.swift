import Foundation

public enum HexToolGroup: String, Codable, CaseIterable, Sendable, Hashable {
	case appControl = "app-control"
	case appDiscovery = "app-discovery"
	case context = "context"

	public var description: String {
		switch self {
		case .appControl:
			return "Launches or focuses macOS applications and opens URLs."
		case .appDiscovery:
			return "Lists installed applications so models can find bundle identifiers."
		case .context:
			return "Reads selected text or clipboard contents without disturbing the user."
		}
	}

	public var toolIdentifiers: [String] {
		switch self {
		case .appControl:
			return ["hex-tools:openApplication", "hex-tools:openURL"]
		case .appDiscovery:
			return ["hex-tools:listApplications"]
		case .context:
			return ["hex-tools:getSelectedText", "hex-tools:getClipboardText"]
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
