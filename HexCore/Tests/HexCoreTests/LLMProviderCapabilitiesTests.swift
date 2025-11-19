import XCTest
@testable import HexCore

final class LLMProviderCapabilitiesTests: XCTestCase {
    func testToolingDisabledWhenProviderCannotCallTools() {
        let providerTooling = LLMProvider.ToolingConfiguration(enabledToolGroups: [.appControl])
        let capabilities = LLMProviderCapabilities(
            supportsToolCalling: false,
            supportsStreaming: false,
            maxContextTokens: nil,
            toolReliability: .none,
            requiresNetwork: false
        )
        let policy = ToolingPolicy(
            capabilities: capabilities,
            transformationTooling: providerTooling,
            providerTooling: providerTooling
        )

        XCTAssertNil(policy.serverConfiguration)
        XCTAssertEqual(policy.disabledReason, "Provider does not support tool calling")
    }

    func testToolingEnabledWhenSupported() {
        let providerTooling = LLMProvider.ToolingConfiguration(enabledToolGroups: [.appControl, .context])
        let capabilities = LLMProviderCapabilities(
            supportsToolCalling: true,
            supportsStreaming: true,
            maxContextTokens: nil,
            toolReliability: .stable,
            requiresNetwork: true
        )
        let policy = ToolingPolicy(
            capabilities: capabilities,
            transformationTooling: nil,
            providerTooling: providerTooling
        )

        XCTAssertNotNil(policy.serverConfiguration)
        XCTAssertNil(policy.disabledReason)
        XCTAssertFalse(policy.allowedToolIdentifiers.isEmpty)
    }
}
