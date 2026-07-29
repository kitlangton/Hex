import Foundation

public enum TranscriptFormattingApplier {
	public static func apply(
		_ text: String,
		lowercase: Bool,
		removePunctuation: Bool,
		removeTrailingPunctuation: Bool
	) -> String {
		var output = lowercase ? text.lowercased() : text
		if removePunctuation {
			output = output.components(separatedBy: .punctuationCharacters).joined()
		} else if removeTrailingPunctuation {
			output = removingTrailingPunctuation(output)
		}
		return output
	}

	private static func removingTrailingPunctuation(_ text: String) -> String {
		guard let lastNonWhitespace = text.lastIndex(where: { !$0.isWhitespace }) else { return text }

		var body = text[...lastNonWhitespace]
		while let last = body.last, last.isPunctuation {
			body.removeLast()
		}

		return String(body + text[text.index(after: lastNonWhitespace)...])
	}
}
