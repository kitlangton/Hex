import Foundation
import Testing
@testable import HexCore

/// Transcript uses synthesized Codable, so persisted history written by older
/// app versions must keep decoding as fields are added. These tests pin that
/// contract the same way HexSettingsMigrationTests does for settings.
struct TranscriptionHistoryDecodingTests {
	/// A history entry exactly as written before modelIdentifier existed.
	private let legacyJSON = Data(
		"""
		{
			"history": [
				{
					"id": "6F1E5A31-98D2-4D30-92F8-4E1B4C43B1AA",
					"timestamp": 730000000,
					"text": "hello world",
					"audioPath": "file:///tmp/recording.wav",
					"duration": 2.5,
					"sourceAppBundleID": "com.apple.Notes",
					"sourceAppName": "Notes"
				}
			]
		}
		""".utf8
	)

	@Test
	func legacyHistoryWithoutModelIdentifierDecodes() throws {
		let history = try JSONDecoder().decode(TranscriptionHistory.self, from: legacyJSON)

		#expect(history.history.count == 1)
		let transcript = try #require(history.history.first)
		#expect(transcript.text == "hello world")
		#expect(transcript.modelIdentifier == nil)
	}

	@Test
	func modelIdentifierRoundTrips() throws {
		let original = Transcript(
			timestamp: Date(timeIntervalSinceReferenceDate: 730_000_000),
			text: "hi",
			audioPath: URL(fileURLWithPath: "/tmp/hi.wav"),
			duration: 1.0,
			modelIdentifier: "parakeet-tdt-0.6b-v3-coreml"
		)

		let data = try JSONEncoder().encode(original)
		let decoded = try JSONDecoder().decode(Transcript.self, from: data)

		#expect(decoded == original)
		#expect(decoded.modelIdentifier == "parakeet-tdt-0.6b-v3-coreml")
	}
}
