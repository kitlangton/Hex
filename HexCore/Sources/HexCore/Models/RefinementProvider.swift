import Foundation

/// Which AI backend to use for transcription refinement.
public enum RefinementProvider: String, Codable, CaseIterable, Equatable, Sendable {
	/// On-device Apple Intelligence (macOS 26+, no API key needed).
	case apple

	/// Google Gemini Flash (requires API key, uses network).
	case gemini
}
