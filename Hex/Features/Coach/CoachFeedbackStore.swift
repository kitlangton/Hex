import ComposableArchitecture
import Foundation
import HexCore

extension SharedReaderKey
	where Self == FileStorageKey<CoachFeedbackHistory>.Default
{
	static var coachFeedback: Self {
		Self[
			.fileStorage(.coachFeedbackURL),
			default: .init()
		]
	}
}

extension URL {
	static var coachFeedbackURL: URL {
		URL.hexMigratedFileURL(named: "coach_feedback.json")
	}
}
