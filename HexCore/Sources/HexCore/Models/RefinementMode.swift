import Foundation

/// Controls how transcribed text is post-processed before pasting.
public enum RefinementMode: String, Codable, CaseIterable, Equatable, Sendable {
	/// Paste the raw transcription as-is (with word removals/remappings still applied).
	case raw

	/// Clean up grammar, punctuation, and capitalization while preserving meaning.
	case refined

	/// Condense the transcription into concise bullet points.
	case summarized
}
