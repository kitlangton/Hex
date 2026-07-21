import Foundation

/// Apple's on-device SpeechAnalyzer engine (macOS 26+), exposed as a single
/// selectable "model" in the library. Per-locale assets are managed by the OS
/// via AssetInventory and follow the user's Output Language setting, so the
/// engine is one entry from the user's perspective — there are no variants to
/// choose between. (#255)
public enum AppleSpeechModel: String, CaseIterable, Sendable {
	case system = "apple-speechanalyzer"

	/// The identifier used throughout the app (stored in `selectedModel`).
	public var identifier: String { rawValue }
}
