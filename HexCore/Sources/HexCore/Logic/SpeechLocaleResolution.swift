import Foundation

/// Maps Hex's `outputLanguage` setting (bare ISO codes from languages.json,
/// e.g. "en", "zh"; nil = Auto) onto one of the locales supported by Apple's
/// SpeechTranscriber.
///
/// Pure logic: callers pass in the supported-locale list, so this compiles and
/// unit-tests on macOS 14 even though the Speech APIs that produce that list
/// require macOS 26.
public enum SpeechLocaleResolution {
	/// Resolves a language preference against the supported locales.
	///
	/// - `nil`, empty, or "auto" preference: best match for the user's current
	///   locale, falling back to English, then the first supported locale.
	/// - Explicit code (e.g. "en"): exact BCP-47 match, else any supported
	///   locale sharing the language code (preferring the user's region, so
	///   "en" resolves to "en-US" on a US Mac rather than whatever sorts
	///   first).
	/// - Returns nil when the engine cannot serve the preference; callers
	///   should surface a clear error rather than silently transcribing in the
	///   wrong language.
	public static func resolve(
		preference: String?,
		supported: [Locale],
		current: Locale = .current
	) -> Locale? {
		guard !supported.isEmpty else { return nil }
		let trimmed = (preference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty || trimmed.lowercased() == "auto" {
			return bestMatch(for: current, in: supported, current: current)
				?? preferredEnglish(in: supported)
				?? supported.first
		}
		return bestMatch(for: Locale(identifier: trimmed), in: supported, current: current)
	}

	static func bestMatch(for locale: Locale, in supported: [Locale], current: Locale) -> Locale? {
		let target = locale.identifier(.bcp47)
		if let exact = supported.first(where: { $0.identifier(.bcp47) == target }) {
			return exact
		}
		guard let language = locale.language.languageCode?.identifier, !language.isEmpty else {
			return nil
		}
		let candidates = supported.filter { $0.language.languageCode?.identifier == language }
		if let region = current.region?.identifier,
		   let regional = candidates.first(where: { $0.region?.identifier == region })
		{
			return regional
		}
		return candidates.first
	}

	private static func preferredEnglish(in supported: [Locale]) -> Locale? {
		supported.first { $0.identifier(.bcp47) == "en-US" }
			?? supported.first { $0.language.languageCode?.identifier == "en" }
	}
}
