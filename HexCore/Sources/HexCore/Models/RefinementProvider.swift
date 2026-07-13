import Foundation

/// Which backend refines a completed transcript.
public enum RefinementProvider: String, Codable, CaseIterable, Equatable, Sendable {
	case apple
	case gemini
	case openRouter
}
