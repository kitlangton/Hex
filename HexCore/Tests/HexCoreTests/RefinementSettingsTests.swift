import XCTest
@testable import HexCore

final class RefinementSettingsTests: XCTestCase {

	// MARK: - Default Values

	func testDefaultRefinementMode() {
		let settings = HexSettings()
		XCTAssertEqual(settings.refinementMode, .raw)
	}

	func testDefaultRefinementProvider() {
		let settings = HexSettings()
		XCTAssertEqual(settings.refinementProvider, .apple)
	}

	func testDefaultRefinementTone() {
		let settings = HexSettings()
		XCTAssertEqual(settings.refinementTone, .natural)
	}

	func testDefaultCycleToneHotkey() {
		let settings = HexSettings()
		XCTAssertNil(settings.cycleToneHotkey)
	}

	func testDefaultGeminiAPIKey() {
		let settings = HexSettings()
		XCTAssertNil(settings.geminiAPIKey)
	}

	// MARK: - Init With Custom Values

	func testInitWithCustomRefinementFields() {
		let settings = HexSettings(
			refinementMode: .refined,
			refinementProvider: .gemini,
			refinementTone: .professional,
			cycleToneHotkey: HotKey(key: .t, modifiers: .init(modifiers: [.option, .shift])),
			geminiAPIKey: "test-key-123"
		)

		XCTAssertEqual(settings.refinementMode, .refined)
		XCTAssertEqual(settings.refinementProvider, .gemini)
		XCTAssertEqual(settings.refinementTone, .professional)
		XCTAssertEqual(settings.cycleToneHotkey?.key, .t)
		XCTAssertEqual(settings.geminiAPIKey, "test-key-123")
	}

	// MARK: - Codable Round-Trip

	func testRefinementFieldsEncodeDecodeRoundTrip() throws {
		let settings = HexSettings(
			refinementMode: .summarized,
			refinementProvider: .gemini,
			refinementTone: .concise,
			cycleToneHotkey: HotKey(key: .t, modifiers: .init(modifiers: [.option, .shift])),
			geminiAPIKey: "my-api-key"
		)

		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.refinementMode, .summarized)
		XCTAssertEqual(decoded.refinementProvider, .gemini)
		XCTAssertEqual(decoded.refinementTone, .concise)
		XCTAssertEqual(decoded.cycleToneHotkey?.key, .t)
		XCTAssertEqual(decoded.geminiAPIKey, "my-api-key")
		XCTAssertEqual(decoded, settings)
	}

	func testRefinementFieldsDecodeDefaultsWhenMissing() throws {
		// Simulate settings JSON from before refinement feature existed
		let oldJSON = "{\"soundEffectsEnabled\":true}"
		let data = oldJSON.data(using: .utf8)!

		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.refinementMode, .raw, "Should default to raw when missing")
		XCTAssertEqual(decoded.refinementProvider, .apple, "Should default to apple when missing")
		XCTAssertEqual(decoded.refinementTone, .natural, "Should default to natural when missing")
		XCTAssertNil(decoded.cycleToneHotkey, "Should default to nil when missing")
		XCTAssertNil(decoded.geminiAPIKey, "Should default to nil when missing")
	}

	func testV1FixtureDecodesWithRefinementDefaults() throws {
		guard let url = Bundle.module.url(
			forResource: "v1",
			withExtension: "json",
			subdirectory: "Fixtures/HexSettings"
		) else {
			XCTFail("Missing v1.json fixture")
			return
		}

		let data = try Data(contentsOf: url)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		// New refinement fields should have defaults
		XCTAssertEqual(decoded.refinementMode, .raw)
		XCTAssertEqual(decoded.refinementProvider, .apple)
		XCTAssertEqual(decoded.refinementTone, .natural)
		XCTAssertNil(decoded.cycleToneHotkey)
		XCTAssertNil(decoded.geminiAPIKey)

		// Existing fields should still be correct
		XCTAssertEqual(decoded.soundEffectsEnabled, false)
		XCTAssertEqual(decoded.selectedModel, "whisper-large-v3")
	}

	func testNilGeminiKeyRoundTrip() throws {
		let settings = HexSettings(geminiAPIKey: nil)
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertNil(decoded.geminiAPIKey)
	}

	func testEmptyGeminiKeyRoundTrip() throws {
		let settings = HexSettings(geminiAPIKey: "")
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertEqual(decoded.geminiAPIKey, "")
	}
}
