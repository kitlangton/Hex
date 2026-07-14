import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

// Re-export types so the app target can use them without HexCore prefixes.
typealias RecordingAudioBehavior = HexCore.RecordingAudioBehavior
typealias HexSettings = HexCore.HexSettings

enum HotKeyCaptureTarget: Equatable, Sendable {
	case recording
	case refinedRecording
	case pasteLastTranscript
}

extension SharedReaderKey
	where Self == FileStorageKey<HexSettings>.Default
{
	static var hexSettings: Self {
		Self[
			.fileStorage(.hexSettingsURL),
			default: .init()
		]
	}
}

extension SharedReaderKey
	where Self == InMemoryKey<HotKeyCaptureTarget?>.Default
{
	static var hotKeyCaptureTarget: Self {
		Self[.inMemory("hotKeyCaptureTarget"), default: nil]
	}
}

// MARK: - Storage Migration

extension URL {
	static var hexSettingsURL: URL {
		get {
			URL.hexMigratedFileURL(named: "hex_settings.json")
		}
	}
}
