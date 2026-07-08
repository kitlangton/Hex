import Foundation

public enum TranscriptFormattingApplier {
	public static func apply(
		_ text: String,
		lowercase: Bool,
		removePunctuation: Bool
	) -> String {
		var output = lowercase ? text.lowercased() : text
		if removePunctuation {
			output = output.components(separatedBy: .punctuationCharacters).joined()
		}
		return output
	}
}
