import Dependencies
import Foundation

public struct HexToolServerClient: Sendable {
	public var ensureServer: @Sendable (HexToolServerConfiguration?) async throws -> HexToolServerEndpoint
	public var shutdown: @Sendable () async -> Void

	public init(
		ensureServer: @escaping @Sendable (HexToolServerConfiguration?) async throws -> HexToolServerEndpoint,
		shutdown: @escaping @Sendable () async -> Void
	) {
		self.ensureServer = ensureServer
		self.shutdown = shutdown
	}
}

extension HexToolServerClient: DependencyKey {
	public static let liveValue: HexToolServerClient = {
		let manager = HexToolServerManager.shared
		return .init(
			ensureServer: { configuration in
				try await manager.ensureServer(configuration: configuration)
			},
			shutdown: {
				try? await manager.shutdown()
			}
		)
	}()
	
	public static let testValue = HexToolServerClient(
		ensureServer: { _ in
			throw HexToolServerError.toolGroupDisabled("hex-tools-client-test")
		},
		shutdown: {}
	)
}

public extension DependencyValues {
	var hexToolServer: HexToolServerClient {
		get { self[HexToolServerClient.self] }
		set { self[HexToolServerClient.self] = newValue }
	}
}
