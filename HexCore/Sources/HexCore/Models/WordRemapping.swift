import Foundation

public struct WordRemapping: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var isEnabled: Bool
	public var match: String
	public var replacement: String
	public var appendNewline: Bool

	public init(
		id: UUID = UUID(),
		isEnabled: Bool = true,
		match: String,
		replacement: String,
		appendNewline: Bool = false
	) {
		self.id = id
		self.isEnabled = isEnabled
		self.match = match
		self.replacement = replacement
		self.appendNewline = appendNewline
	}

	enum CodingKeys: String, CodingKey {
		case id
		case isEnabled
		case match
		case replacement
		case appendNewline
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
		match = try container.decode(String.self, forKey: .match)
		replacement = try container.decode(String.self, forKey: .replacement)
		appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? false
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(isEnabled, forKey: .isEnabled)
		try container.encode(match, forKey: .match)
		try container.encode(replacement, forKey: .replacement)
		try container.encode(appendNewline, forKey: .appendNewline)
	}
}

public enum WordRemappingApplier {
	public static func apply(_ text: String, remappings: [WordRemapping]) -> String {
		guard !remappings.isEmpty else { return text }
		var output = text
		for remapping in remappings where remapping.isEnabled {
			let trimmed = remapping.match.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			let escaped = NSRegularExpression.escapedPattern(for: trimmed)
			let pattern: String
			if remapping.appendNewline {
				pattern = "(?<!\\w)\(escaped)(?!\\w)[\\p{P}]*"
			} else if isPunctuationOnlyReplacement(remapping.replacement) {
				let punctuation = NSRegularExpression.escapedPattern(
					for: remapping.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
				)
				pattern = "(?<!\\w)\(escaped)(?!\\w)(?:\\s*\(punctuation))*"
			} else {
				pattern = "(?<!\\w)\(escaped)(?!\\w)"
			}
			let replacement = remapping.replacement + (remapping.appendNewline ? "\n" : "")
			output = output.replacingOccurrences(
				of: pattern,
				with: replacement,
				options: [.regularExpression, .caseInsensitive]
			)
		}
		return output
	}

	private static func isPunctuationOnlyReplacement(_ replacement: String) -> Bool {
		let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count == 1 else { return false }
		let punctuation: Set<Character> = [",", ".", "!", "?", ":", ";"]
		return trimmed.first.map { punctuation.contains($0) } ?? false
	}
}
