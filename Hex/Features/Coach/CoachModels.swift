import Foundation
import HexCore

/// LLM-produced pronunciation feedback for a single recording.
struct Feedback: Codable, Equatable, Sendable {
	var overallScore: Int
	var summary: String
	var nativeRewrite: String
	var issues: [Issue]
	var wins: [String]
	/// The full Markdown response from the model, preserved verbatim. The popover
	/// falls back to rendering this when the structured fields above are empty —
	/// which happens whenever the user is running a custom prompt that doesn't
	/// match our default schema.
	var rawMarkdown: String

	init(
		overallScore: Int,
		summary: String,
		nativeRewrite: String = "",
		issues: [Issue],
		wins: [String],
		rawMarkdown: String = ""
	) {
		self.overallScore = overallScore
		self.summary = summary
		self.nativeRewrite = nativeRewrite
		self.issues = issues
		self.wins = wins
		self.rawMarkdown = rawMarkdown
	}

	// Custom decoder for backward compatibility with older saved feedback.
	enum CodingKeys: String, CodingKey {
		case overallScore
		case summary
		case nativeRewrite
		case issues
		case wins
		case rawMarkdown
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.overallScore = try c.decode(Int.self, forKey: .overallScore)
		self.summary = try c.decode(String.self, forKey: .summary)
		self.nativeRewrite = (try? c.decodeIfPresent(String.self, forKey: .nativeRewrite)) ?? ""
		self.issues = try c.decode([Issue].self, forKey: .issues)
		self.wins = try c.decode([String].self, forKey: .wins)
		self.rawMarkdown = (try? c.decodeIfPresent(String.self, forKey: .rawMarkdown)) ?? ""
	}

	/// True when the structured parser could not extract anything meaningful from
	/// the response — typically because the user's custom prompt produced a
	/// different format. The popover uses this to switch to raw-markdown rendering.
	var isStructured: Bool {
		overallScore > 0 || !summary.isEmpty || !nativeRewrite.isEmpty || !issues.isEmpty || !wins.isEmpty
	}
}

struct Issue: Codable, Equatable, Sendable {
	var wordOrPhrase: String
	var whatYouSaid: String
	var whatToSay: String
	var tip: String
}

/// A single coach session: input (transcript + audio) plus the feedback we got back.
struct CoachFeedbackEntry: Codable, Equatable, Identifiable, Sendable {
	var id: UUID
	var transcriptID: UUID
	var timestamp: Date
	var transcript: String
	var durationSec: TimeInterval
	var provider: CoachProvider
	var model: String
	var feedback: Feedback
	var costUSDEstimate: Double?

	init(
		id: UUID = UUID(),
		transcriptID: UUID,
		timestamp: Date = Date(),
		transcript: String,
		durationSec: TimeInterval,
		provider: CoachProvider,
		model: String,
		feedback: Feedback,
		costUSDEstimate: Double? = nil
	) {
		self.id = id
		self.transcriptID = transcriptID
		self.timestamp = timestamp
		self.transcript = transcript
		self.durationSec = durationSec
		self.provider = provider
		self.model = model
		self.feedback = feedback
		self.costUSDEstimate = costUSDEstimate
	}
}

struct CoachFeedbackHistory: Codable, Equatable, Sendable {
	static let maxEntries = 500

	var version: Int = 1
	var items: [CoachFeedbackEntry] = []

	mutating func append(_ entry: CoachFeedbackEntry) {
		items.insert(entry, at: 0)
		if items.count > Self.maxEntries {
			items = Array(items.prefix(Self.maxEntries))
		}
	}
}
