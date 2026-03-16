import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

// Re-export types so the app target can use them without HexCore prefixes.
typealias RecordingAudioBehavior = HexCore.RecordingAudioBehavior
typealias HexSettings = HexCore.HexSettings

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

// MARK: - Storage Migration

extension URL {
	static var hexSettingsURL: URL {
		get {
			URL.hexMigratedFileURL(named: "hex_settings.json")
		}
	}
}
