import XCTest
@testable import HexCore

final class HexSettingsMigrationTests: XCTestCase {
	func testV1FixtureMigratesToCurrentDefaults() throws {
		let data = try loadFixture(named: "v1")
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.recordingAudioBehavior, .pauseMedia, "Legacy pauseMediaOnRecord bool should map to pauseMedia behavior")
		XCTAssertEqual(decoded.soundEffectsEnabled, false)
		XCTAssertEqual(decoded.soundEffectsVolume, HexSettings.baseSoundEffectsVolume)
		XCTAssertEqual(decoded.openOnLogin, true)
		XCTAssertEqual(decoded.showDockIcon, false)
		XCTAssertEqual(decoded.selectedModel, "whisper-large-v3")
		XCTAssertEqual(decoded.useClipboardPaste, false)
		XCTAssertEqual(decoded.preventSystemSleep, true)
		XCTAssertEqual(decoded.minimumKeyTime, 0.25)
		XCTAssertEqual(decoded.copyToClipboard, true)
		XCTAssertEqual(decoded.recordingMode, .doubleTap)
		XCTAssertEqual(decoded.outputLanguage, "en")
		XCTAssertEqual(decoded.selectedMicrophoneID, "builtin:mic")
		XCTAssertEqual(decoded.saveTranscriptionHistory, false)
		XCTAssertEqual(decoded.maxHistoryEntries, 10)
		XCTAssertEqual(decoded.hasCompletedModelBootstrap, true)
		XCTAssertEqual(decoded.hasCompletedStorageMigration, true)
	}

	func testEncodeDecodeRoundTripPreservesDefaults() throws {
		let settings = HexSettings()
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertEqual(decoded, settings)
	}

	private func loadFixture(named name: String) throws -> Data {
		guard let url = Bundle.module.url(
			forResource: name,
			withExtension: "json",
			subdirectory: "Fixtures/HexSettings"
		) else {
			XCTFail("Missing fixture \(name).json")
			throw NSError(domain: "Fixture", code: 0)
		}
		return try Data(contentsOf: url)
	}
}
