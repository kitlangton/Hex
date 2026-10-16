import Foundation

/// Builds a decoder prompt from the user's custom vocabulary so Whisper-family
/// models are biased toward the exact spelling/casing of names, jargon, and
/// other words the model commonly gets wrong.
///
/// The prompt is passed to WhisperKit via `DecodingOptions.promptTokens`,
/// which Whisper prepends to the decoder's prefill tokens. The model treats
/// them as previously transcribed text and is measurably more likely to
/// reproduce those spellings — this is the on-device equivalent of Whisper's
/// `initial_prompt` / "hotwords" feature.
public enum CustomVocabularyPrompt {
	/// Maximum characters of vocabulary text to inject. Whisper's decoder context
	/// is limited (~224 tokens total, shared with prefill tokens), and an
	/// over-long prompt degrades rather than improves accuracy, so the prompt is
	/// trimmed to the most recent terms that fit.
	public static let maxPromptLength = 220

	/// Parses a free-form vocabulary list into normalized terms.
	/// Accepts comma- or newline-separated entries; trims whitespace, drops empties.
	public static func parseTerms(_ vocabulary: String) -> [String] {
		vocabulary
			.components(separatedBy: CharacterSet(charactersIn: ",\n"))
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}

	/// Builds the prompt text injected ahead of the decoder's prefill tokens.
	///
	/// Returns `nil` when the vocabulary is empty or disabled, in which case the
	/// caller should leave `DecodingOptions.promptTokens` unset.
	///
	/// A short declarative lead-in ("Vocabulary: ...") is used instead of raw
	/// comma soup: Whisper is trained on natural prose, so framing the terms as
	/// a labeled list conditions it more reliably and lowers the odds of the
	/// model echoing stray terms into unrelated transcripts.
	public static func makePromptText(vocabulary: String, isEnabled: Bool) -> String? {
		guard isEnabled else { return nil }
		let terms = parseTerms(vocabulary)
		guard !terms.isEmpty else { return nil }

		// Build incrementally from whole terms that fit. Never splits a term, and
		// handles a single over-long term (or over-long final term) by dropping it —
		// the previous comma-trim loop missed both cases when no comma was present.
		let prefix = "Vocabulary: "
		let suffix = "."
		var includedTerms: [String] = []
		var length = prefix.count + suffix.count

		for term in terms {
			let separatorLength = includedTerms.isEmpty ? 0 : 2 // ", "
			guard length + separatorLength + term.count <= maxPromptLength else { continue }
			includedTerms.append(term)
			length += separatorLength + term.count
		}

		guard !includedTerms.isEmpty else { return nil }
		return prefix + includedTerms.joined(separator: ", ") + suffix
	}
}
