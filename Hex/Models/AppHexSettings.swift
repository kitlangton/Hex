import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

// Re-export types so the app target can use them without HexCore prefixes.
typealias RecordingAudioBehavior = HexCore.RecordingAudioBehavior
typealias HexSettings = HexCore.HexSettings

// MARK: - URL Extensions

extension URL {
	/// Returns the Application Support directory for Hex
	static var hexApplicationSupport: URL {
		get throws {
			let fm = FileManager.default
			let appSupport = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			let hexDir = appSupport.appending(component: "com.kitlangton.Hex")
			try fm.createDirectory(at: hexDir, withIntermediateDirectories: true)
			return hexDir
		}
	}

	/// Legacy location in Documents (for migration)
	static var legacyDocumentsDirectory: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	}
}

extension FileManager {
	/// Copies a file from legacy location to new location if legacy exists and new doesn't.
	func migrateIfNeeded(from legacy: URL, to new: URL) {
		guard fileExists(atPath: legacy.path), !fileExists(atPath: new.path) else { return }
		try? copyItem(at: legacy, to: new)
	}

	/// Removes an item only if it exists, swallowing any errors.
	func removeItemIfExists(at url: URL) {
		guard fileExists(atPath: url.path) else { return }
		try? removeItem(at: url)
	}
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

// MARK: - Storage Migration

extension URL {
	static var hexSettingsURL: URL {
		get {
			let newURL = (try? URL.hexApplicationSupport.appending(component: "hex_settings.json"))
				?? URL.documentsDirectory.appending(component: "hex_settings.json")
			let legacyURL = URL.legacyDocumentsDirectory.appending(component: "hex_settings.json")
			FileManager.default.migrateIfNeeded(from: legacyURL, to: newURL)
			return newURL
		}
	}
}
