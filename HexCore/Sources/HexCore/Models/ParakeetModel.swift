import Foundation

/// Known Parakeet Core ML bundles that Hex supports.
public enum ParakeetModel: String, CaseIterable, Sendable {
	case englishV2 = "parakeet-tdt-0.6b-v2-coreml"
	case multilingualV3 = "parakeet-tdt-0.6b-v3-coreml"

	/// The identifier used throughout the app (matches the on-disk folder name).
	public var identifier: String { rawValue }

	/// Whether the model only supports English transcription.
	public var isEnglishOnly: Bool {
		self == .englishV2
	}

	/// Short capability label for UI copy.
	public var capabilityLabel: String {
		isEnglishOnly ? "English" : "Multilingual"
	}

	/// Convenience text for recommendation badges.
	public var recommendationLabel: String {
		isEnglishOnly ? "Recommended (English)" : "Recommended (Multilingual)"
	}
}
