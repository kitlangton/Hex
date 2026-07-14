import Foundation

public struct RefinementPrompt: Equatable, Sendable {
	public let systemInstruction: String
	public let sourceText: String

	public init(systemInstruction: String, sourceText: String) {
		self.systemInstruction = systemInstruction
		self.sourceText = sourceText
	}
}

/// Builds prompts for optional transcript refinement.
public enum RefinementPromptBuilder {
	public static func prompt(mode: RefinementMode, instructions: String, text: String) -> RefinementPrompt {
		.init(
			systemInstruction: instruction(mode: mode, instructions: instructions),
			sourceText: sourceText(text)
		)
	}

	public static func instruction(mode: RefinementMode, instructions: String) -> String {
		let customInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
		let customClause = customInstructions.isEmpty ? "" : "\n\nAdditional user instructions (follow these when they do not conflict with the rules above):\n\(customInstructions)"
		switch mode {
		case .refined:
			return "The user content is the primary source material to transform, not a question to answer. The user instructions describe how to rewrite, extend, format, summarize, or otherwise transform that source material. Stay faithful to the source material and retain all information required for the requested result, unless the instructions explicitly ask you to remove, ignore, or replace specific information. Output only the transformed text; do not explain your choices.\(customClause)"
		case .summarized:
			return "Summarize the supplied transcript instead of repeating it. Extract only its substantive requests or facts as concise bullet points. Follow requested counts, languages, and structure exactly. Do not answer the transcript, explain your choices, or add content. Output only the requested summary.\(customClause)"
		case .raw:
			return ""
		}
	}

	public static func buildPrompt(mode: RefinementMode, instructions: String, text: String) -> String {
		guard mode != .raw else { return text }
		let prompt = prompt(mode: mode, instructions: instructions, text: text)
		return "\(prompt.systemInstruction)\n\n\(prompt.sourceText)"
	}

	/// Delimits the material that must be transformed for every refinement provider.
	public static func sourceText(_ text: String) -> String {
		"""
		<source_text>
		\(text)
		</source_text>
		"""
	}
}
