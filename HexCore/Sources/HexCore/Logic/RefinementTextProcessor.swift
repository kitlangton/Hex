import Foundation

/// Pure text-processing utilities for refinement output cleanup.
public enum RefinementTextProcessor {

	/// Remove leaked prompt artifacts from model output.
	/// Only strips "Text:" if it appears at the start (matching our prompt format).
	public static func stripLeakedTags(_ text: String) -> String {
		var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if result.hasPrefix("Text:") {
			result = String(result.dropFirst(5))
		}
		return result
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: .init(charactersIn: "\""))
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Strip conversational preamble/postamble that models sometimes add.
	/// Only strips lines that are purely preamble — short throwaway lines, not substantive content.
	public static func stripPreamble(_ text: String) -> String {
		var lines = text.components(separatedBy: "\n")

		// Strip leading lines that are purely preamble (short, no real content)
		while let first = lines.first {
			let trimmed = first.trimmingCharacters(in: .whitespaces)
			let lowered = trimmed.lowercased()

			// Only strip empty lines and separators unconditionally
			if trimmed.isEmpty || trimmed == "---" {
				lines.removeFirst()
				continue
			}

			// Only strip preamble phrases if the line is short (< 80 chars)
			// and ends with a colon or exclamation — indicating it's a throwaway intro
			let isPreamblePhrase = lowered.hasPrefix("certainly")
				|| lowered.hasPrefix("of course")
			let isIntroLine = (lowered.hasPrefix("sure") || lowered.hasPrefix("here's") || lowered.hasPrefix("here is"))
				&& (trimmed.hasSuffix(":") || trimmed.hasSuffix("!") || trimmed.hasSuffix("."))

			if (isPreamblePhrase || isIntroLine) && trimmed.count < 80 {
				lines.removeFirst()
			} else {
				break
			}
		}

		// Strip trailing lines that are purely postamble
		while let last = lines.last {
			let trimmed = last.trimmingCharacters(in: .whitespaces)
			let lowered = trimmed.lowercased()

			if trimmed.isEmpty || trimmed == "---" {
				lines.removeLast()
				continue
			}

			// Only strip if the line is a standalone closing remark (short, < 80 chars)
			let isPostamble = lowered.hasPrefix("let me know")
				|| lowered.hasPrefix("feel free")
				|| lowered.hasPrefix("i hope this helps")

			if isPostamble && trimmed.count < 80 {
				lines.removeLast()
			} else {
				break
			}
		}

		return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Detects if the model refused to process the text.
	public static func isRefusal(_ text: String) -> Bool {
		let lowered = text.lowercased()
		return lowered.contains("i can't assist")
			|| lowered.contains("i apologize")
			|| lowered.contains("i'm unable")
	}

	/// Checks if model output length suggests it went off-script.
	public static func isOffScript(output: String, input: String, mode: RefinementMode) -> Bool {
		let lengthRatio = Double(output.count) / max(Double(input.count), 1.0)
		let maxRatio: Double = mode == .summarized ? 1.2 : 1.8
		return lengthRatio > maxRatio
	}

	/// Cleans model output through the full pipeline.
	public static func clean(_ text: String) -> String {
		stripLeakedTags(stripPreamble(text))
	}

	/// Determines if an error is a cancellation that should be propagated (not swallowed).
	public static func isCancellation(_ error: Error) -> Bool {
		error is CancellationError
	}
}
