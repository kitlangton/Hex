import Foundation

/// Tone applied during transcription refinement.
public enum RefinementTone: String, Codable, CaseIterable, Equatable, Sendable {
	case natural
	case professional
	case casual
	case concise
	case friendly
}
