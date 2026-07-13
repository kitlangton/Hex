import Foundation

/// Pure text-processing utilities for refinement output cleanup.
public enum RefinementTextProcessor {
	public static func stripLeakedTags(_ text: String) -> String {
		var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let hadLeakedTag = result.hasPrefix("Text:")
		if hadLeakedTag {
			result = String(result.dropFirst(5))
		}
		result = result.trimmingCharacters(in: .whitespacesAndNewlines)
		if hadLeakedTag, result.first == "\"", result.last == "\"", result.count >= 2 {
			result.removeFirst()
			result.removeLast()
		}
		return result.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public static func stripPreamble(_ text: String) -> String {
		var lines = text.components(separatedBy: "\n")
		while let first = lines.first {
			let trimmed = first.trimmingCharacters(in: .whitespaces)
			let lowered = trimmed.lowercased()
			if trimmed.isEmpty || trimmed == "---" {
				lines.removeFirst()
				continue
			}
			let preamble = lowered.hasPrefix("certainly") || lowered.hasPrefix("of course")
				|| ((lowered.hasPrefix("sure") || lowered.hasPrefix("here's") || lowered.hasPrefix("here is"))
					&& (trimmed.hasSuffix(":") || trimmed.hasSuffix("!") || trimmed.hasSuffix(".")))
			if preamble && trimmed.count < 80 {
				lines.removeFirst()
			} else {
				break
			}
		}
		return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public static func isRefusal(_ text: String) -> Bool {
		let lowered = text.lowercased()
		return lowered.contains("i can't assist") || lowered.contains("i apologize") || lowered.contains("i'm unable")
	}

	public static func isOffScript(output: String, input: String, mode: RefinementMode) -> Bool {
		// A faithful summary can legitimately be longer than its source when the user
		// requests several languages or a prescribed format. Applying an expansion
		// limit here made those valid results fall back to the original transcript.
		guard mode == .refined else { return false }
		let ratio = Double(output.count) / max(Double(input.count), 1)
		return ratio > 1.8
	}

	public static func clean(_ text: String) -> String {
		stripLeakedTags(stripPreamble(text))
	}
}
