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

// MARK: - Developer Feature Flags

enum DeveloperAccess {
	private static let envKey = "HEX_ENABLE_LLM"
	private static let featureDirectoryName = "feature_flags"
	private static let sentinelFileName = "enable_llm_features"

	static var allowsLLMFeatures: Bool {
		if let envValue = ProcessInfo.processInfo.environment[envKey], isTruthy(envValue) {
			return true
		}

		guard let sentinelURL = featureFlagURL else { return false }
		return FileManager.default.fileExists(atPath: sentinelURL.path)
	}

	private static var featureFlagURL: URL? {
		guard let base = try? URL.hexApplicationSupport else { return nil }
		return base
			.appending(component: featureDirectoryName)
			.appending(component: sentinelFileName)
	}

	private static func isTruthy(_ value: String) -> Bool {
		switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "1", "true", "yes", "on":
			return true
		default:
			return false
		}
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

			// Migrate if needed
			if FileManager.default.fileExists(atPath: legacyURL.path),
			   !FileManager.default.fileExists(atPath: newURL.path) {
				try? FileManager.default.copyItem(at: legacyURL, to: newURL)
			}

			return newURL
		}
	}
}
