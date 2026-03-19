import Foundation

/// Pure text-processing utilities for refinement output cleanup.
public enum RefinementTextProcessor {

	/// Remove leaked prompt artifacts from model output.
	public static func stripLeakedTags(_ text: String) -> String {
		text.replacingOccurrences(of: "Text:", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: .init(charactersIn: "\""))
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Strip conversational preamble/postamble that models sometimes add.
	public static func stripPreamble(_ text: String) -> String {
		var lines = text.components(separatedBy: "\n")

		while let first = lines.first {
			let trimmed = first.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty
				|| trimmed == "---"
				|| trimmed.lowercased().hasPrefix("certainly")
				|| trimmed.lowercased().hasPrefix("sure")
				|| trimmed.lowercased().hasPrefix("here's")
				|| trimmed.lowercased().hasPrefix("here is")
				|| trimmed.lowercased().hasPrefix("of course") {
				lines.removeFirst()
			} else {
				break
			}
		}

		while let last = lines.last {
			let trimmed = last.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty
				|| trimmed == "---"
				|| trimmed.lowercased().hasPrefix("let me know")
				|| trimmed.lowercased().hasPrefix("feel free")
				|| trimmed.lowercased().hasPrefix("i hope") {
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
}
