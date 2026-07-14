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
		XCTAssertTrue(decoded.superFastModeEnabled)
		XCTAssertEqual(decoded.useDoubleTapOnly, true)
		XCTAssertEqual(decoded.doubleTapLockEnabled, true)
		XCTAssertEqual(decoded.outputLanguage, "en")
		XCTAssertEqual(decoded.selectedMicrophoneID, "builtin:mic")
		XCTAssertEqual(decoded.saveTranscriptionHistory, false)
		XCTAssertEqual(decoded.saveCancelledRecordings, true)
		XCTAssertEqual(decoded.maxHistoryEntries, 10)
		XCTAssertEqual(decoded.hasCompletedModelBootstrap, true)
		XCTAssertEqual(decoded.hasCompletedStorageMigration, true)
		XCTAssertFalse(decoded.lowercaseTranscripts)
		XCTAssertFalse(decoded.removePunctuation)
		XCTAssertEqual(decoded.refinementMode, .raw)
		XCTAssertEqual(decoded.refinementProvider, .apple)
		XCTAssertEqual(decoded.refinementInstructions, "")
		XCTAssertNil(decoded.openRouterModelID)
		XCTAssertNil(decoded.refinedHotkey)
		XCTAssertTrue(decoded.includeSelectedTextInRefinement)
	}

	func testEncodeDecodeRoundTripPreservesDefaults() throws {
		let settings = HexSettings()
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertEqual(decoded, settings)
	}

	func testNewSettingsEnableSuperFastModeByDefault() {
		XCTAssertTrue(HexSettings().superFastModeEnabled)
	}

	func testInitNormalizesDoubleTapOnlyWhenLockDisabled() {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)

		XCTAssertFalse(settings.useDoubleTapOnly)
		XCTAssertFalse(settings.doubleTapLockEnabled)
	}

	func testDecodeNormalizesDoubleTapOnlyWhenLockDisabled() throws {
		let payload = "{\"useDoubleTapOnly\":true,\"doubleTapLockEnabled\":false}"
		guard let data = payload.data(using: .utf8) else {
			XCTFail("Failed to encode JSON payload")
			return
		}

		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertFalse(decoded.useDoubleTapOnly)
		XCTAssertFalse(decoded.doubleTapLockEnabled)
	}

	func testDecodeNormalizesRefinedDoubleTapOnlyWhenLockDisabled() throws {
		let payload = "{\"refinedUseDoubleTapOnly\":true,\"refinedDoubleTapLockEnabled\":false}"
		let decoded = try JSONDecoder().decode(HexSettings.self, from: Data(payload.utf8))

		XCTAssertFalse(decoded.refinedUseDoubleTapOnly)
		XCTAssertFalse(decoded.refinedDoubleTapLockEnabled)
	}

	func testRefinedHotkeyAndInstructionsRoundTrip() throws {
		let settings = HexSettings(
			refinementInstructions: "Return exactly three points.",
			refinedHotkey: HotKey(key: .space, modifiers: [.command]),
			refinedMinimumKeyTime: 0.4,
			includeSelectedTextInRefinement: false
		)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))

		XCTAssertEqual(decoded.refinementInstructions, "Return exactly three points.")
		XCTAssertEqual(decoded.refinedHotkey, HotKey(key: .space, modifiers: [.command]))
		XCTAssertEqual(decoded.refinedMinimumKeyTime, 0.4)
		XCTAssertFalse(decoded.includeSelectedTextInRefinement)
	}

	func testEncodeDecodeRoundTripPreservesNormalizedDoubleTapValues() throws {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertFalse(settings.useDoubleTapOnly)
		XCTAssertFalse(decoded.useDoubleTapOnly)
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
