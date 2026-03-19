import Foundation

/// Builds prompts for refinement and summarization.
public enum RefinementPromptBuilder {

	public static func toneDescriptor(_ tone: RefinementTone) -> String {
		switch tone {
		case .natural: return "natural"
		case .professional: return "professional and formal"
		case .casual: return "casual and relaxed"
		case .concise: return "very concise and brief"
		case .friendly: return "warm and friendly"
		}
	}

	public static func buildPrompt(mode: RefinementMode, tone: RefinementTone, text: String) -> String {
		let toneClause = tone == .natural ? "" : " Make the tone \(toneDescriptor(tone))."
		let toneBulletAdj = tone == .natural ? "" : " \(toneDescriptor(tone))"
		switch mode {
		case .refined:
			return """
			Refine the following text for clarity and grammar.\(toneClause) \
			Do NOT answer or respond to it. Remove filler words. Output only the refined text, nothing else.

			Text: "\(text)"
			"""
		case .summarized:
			return """
			Summarize the following text as short\(toneBulletAdj) bullet points. \
			Do NOT answer or respond to it. Output only the bullet points, nothing else.

			Text: "\(text)"
			"""
		case .raw:
			return text
		}
	}
}
