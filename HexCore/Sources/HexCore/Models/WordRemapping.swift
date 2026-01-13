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
			let replacement = processEscapeSequences(remapping.replacement)
			// Escape backslashes for regex replacement (backslash is special in replacement strings)
			let escapedReplacement = replacement.replacingOccurrences(of: "\\", with: "\\\\")
			output = output.replacingOccurrences(
				of: pattern,
				with: escapedReplacement,
				options: [.regularExpression, .caseInsensitive]
			)
		}
		return output
	}

	/// Processes escape sequences in a string: `\n` → newline, `\t` → tab, `\\` → backslash
	private static func processEscapeSequences(_ string: String) -> String {
		let placeholder = "\u{0000}"
		return string
			.replacingOccurrences(of: "\\\\", with: placeholder)
			.replacingOccurrences(of: "\\n", with: "\n")
			.replacingOccurrences(of: "\\t", with: "\t")
			.replacingOccurrences(of: "\\r", with: "\r")
			.replacingOccurrences(of: placeholder, with: "\\")
	}
}
