import Foundation

public struct WordRemapping: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var isEnabled: Bool
	public var match: String
	public var replacement: String

	public init(
		id: UUID = UUID(),
		isEnabled: Bool = true,
		match: String,
		replacement: String
	) {
		self.id = id
		self.isEnabled = isEnabled
		self.match = match
		self.replacement = replacement
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
			let pattern = "(?<!\\w)\(escaped)(?!\\w)"
			output = output.replacingOccurrences(
				of: pattern,
				with: remapping.replacement,
				options: [.regularExpression, .caseInsensitive]
			)
		}
		return output
	}
}
