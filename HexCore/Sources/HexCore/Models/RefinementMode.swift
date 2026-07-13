import Foundation

/// Controls the optional AI post-processing applied after Hex produces a transcript.
public enum RefinementMode: String, Codable, CaseIterable, Equatable, Sendable {
	case raw
	case refined
	case summarized
}
