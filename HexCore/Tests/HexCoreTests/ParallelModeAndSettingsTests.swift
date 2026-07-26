import XCTest
@testable import HexCore

final class ParallelModeAndSettingsTests: XCTestCase {
	func testDefaultSettingsHaveParallelModeDisabledByDefault() {
		let settings = HexSettings()
		XCTAssertEqual(settings.transcribeMode, .default)
		XCTAssertNil(settings.customModelDirectory)
	}

	func testParallelModeSettingRoundTripSerialization() throws {
		var settings = HexSettings()
		settings.transcribeMode = .parallel
		settings.customModelDirectory = "/Users/test/Documents/models"

		let encoder = JSONEncoder()
		let data = try encoder.encode(settings)

		let decoder = JSONDecoder()
		let decoded = try decoder.decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.transcribeMode, .parallel)
		XCTAssertEqual(decoded.customModelDirectory, "/Users/test/Documents/models")
		XCTAssertEqual(decoded, settings)
	}

	func testDecodingJsonPayloadWithParallelTranscribeMode() throws {
		let jsonString = """
		{
			"transcribeMode": "parallel",
			"customModelDirectory": "/Users/test/Documents"
		}
		"""
		guard let data = jsonString.data(using: .utf8) else {
			XCTFail("Failed to convert JSON string to Data")
			return
		}

		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertEqual(decoded.transcribeMode, .parallel)
		XCTAssertEqual(decoded.customModelDirectory, "/Users/test/Documents")
	}

	func testTranscriptionModeEnumCasesAndRawValues() {
		XCTAssertEqual(TranscriptionMode.default.rawValue, "default")
		XCTAssertEqual(TranscriptionMode.parallel.rawValue, "parallel")
		XCTAssertEqual(TranscriptionMode.allCases.count, 2)
	}

	func testModelPatternMatcherResolvesExactMatch() {
		let match = ModelPatternMatcher.matches("openai_whisper-base", "openai_whisper-base")
		XCTAssertTrue(match)
	}

	func testModelPatternMatcherResolvesWildcardMatch() {
		let match = ModelPatternMatcher.matches("openai_whisper-*", "openai_whisper-large-v3-v20240930_turbo_632MB")
		XCTAssertTrue(match)
	}

	func testModelPatternMatcherResolvesDownloadedPreference() {
		let models = [
			(name: "openai_whisper-large-v3", isDownloaded: false),
			(name: "openai_whisper-large-v3_turbo", isDownloaded: true)
		]
		let resolved = ModelPatternMatcher.resolvePattern("openai_whisper-large-v3*", from: models)
		XCTAssertEqual(resolved, "openai_whisper-large-v3_turbo")
	}
}
