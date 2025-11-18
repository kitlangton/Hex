import Foundation
import SwiftMCP

public actor HexToolServerManager {
	public static let shared = HexToolServerManager()

	private var transport: HTTPSSETransport?
	private var server: HexToolServerActor?
	private var endpointBase: HexToolServerEndpoint?
	private var currentAllowedGroups: Set<HexToolGroup> = []

	private let host = "127.0.0.1"
	private let serverName = "hex-tools"

	public func ensureServer(configuration: HexToolServerConfiguration? = nil) async throws -> HexToolServerEndpoint {
		let requestedGroups = Set(configuration?.enabledToolGroups ?? [])
		let baseEndpoint = try await startIfNeeded()
		if requestedGroups != currentAllowedGroups {
			currentAllowedGroups = requestedGroups
			HexLog.transcription.info("Configuring MCP server tool groups: \(requestedGroups.map(\.rawValue).joined(separator: ", "))")
			await server?.updateAllowedGroups(requestedGroups)
		}
		return HexToolServerEndpoint(
			baseURL: baseEndpoint.baseURL,
			serverName: baseEndpoint.serverName,
			instructions: configuration?.instructions
		)
	}

	private func startIfNeeded() async throws -> HexToolServerEndpoint {
		if let endpointBase {
			return endpointBase
		}
		HexLog.transcription.info("Starting MCP server (initial boot)")
		let server = HexToolServerActor()
		let transport = HTTPSSETransport(server: server, host: host, port: 0)
		transport.keepAliveMode = HTTPSSETransport.KeepAliveMode.ping
		try await transport.start()
		let resolvedURL = URL(string: "http://\(host):\(transport.port)/mcp")!
		HexLog.transcription.info("MCP server running at \(resolvedURL)")
		let endpoint = HexToolServerEndpoint(
			baseURL: resolvedURL,
			serverName: serverName,
			instructions: nil
		)
		self.server = server
		self.transport = transport
		self.endpointBase = endpoint
		return endpoint
	}
	
	public func shutdown() async throws {
		if let transport {
			try await transport.stop()
		}
		transport = nil
		server = nil
		endpointBase = nil
		currentAllowedGroups = []
	}
}
