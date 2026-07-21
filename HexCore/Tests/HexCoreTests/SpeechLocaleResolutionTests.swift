import Foundation
import Testing
@testable import HexCore

struct SpeechLocaleResolutionTests {
	/// A realistic slice of SpeechTranscriber.supportedLocales.
	private let supported = [
		Locale(identifier: "en-US"),
		Locale(identifier: "en-GB"),
		Locale(identifier: "fr-FR"),
		Locale(identifier: "de-DE"),
		Locale(identifier: "es-ES"),
		Locale(identifier: "pt-BR"),
	]

	@Test
	func exactBCP47MatchWins() {
		let result = SpeechLocaleResolution.resolve(
			preference: "en-GB",
			supported: supported,
			current: Locale(identifier: "en-US")
		)
		#expect(result?.identifier(.bcp47) == "en-GB")
	}

	@Test
	func bareLanguageCodePrefersCurrentRegion() {
		let result = SpeechLocaleResolution.resolve(
			preference: "en",
			supported: supported,
			current: Locale(identifier: "en-GB")
		)
		#expect(result?.identifier(.bcp47) == "en-GB")
	}

	@Test
	func bareLanguageCodeFallsBackToFirstCandidateWhenRegionUnavailable() {
		let result = SpeechLocaleResolution.resolve(
			preference: "en",
			supported: supported,
			current: Locale(identifier: "fr-FR")
		)
		#expect(result?.identifier(.bcp47) == "en-US")
	}

	@Test
	func nilPreferenceResolvesFromCurrentLocale() {
		let result = SpeechLocaleResolution.resolve(
			preference: nil,
			supported: supported,
			current: Locale(identifier: "de-DE")
		)
		#expect(result?.identifier(.bcp47) == "de-DE")
	}

	@Test
	func autoPreferenceBehavesLikeNil() {
		let result = SpeechLocaleResolution.resolve(
			preference: "auto",
			supported: supported,
			current: Locale(identifier: "fr-FR")
		)
		#expect(result?.identifier(.bcp47) == "fr-FR")
	}

	@Test
	func unsupportedCurrentLocaleFallsBackToEnglish() {
		let result = SpeechLocaleResolution.resolve(
			preference: nil,
			supported: supported,
			current: Locale(identifier: "am-ET")
		)
		#expect(result?.identifier(.bcp47) == "en-US")
	}

	@Test
	func autoWithoutEnglishFallsBackToFirstSupported() {
		let noEnglish = [Locale(identifier: "fr-FR"), Locale(identifier: "de-DE")]
		let result = SpeechLocaleResolution.resolve(
			preference: nil,
			supported: noEnglish,
			current: Locale(identifier: "am-ET")
		)
		#expect(result?.identifier(.bcp47) == "fr-FR")
	}

	@Test
	func unsupportedExplicitLanguageReturnsNil() {
		let result = SpeechLocaleResolution.resolve(
			preference: "am",
			supported: supported,
			current: Locale(identifier: "en-US")
		)
		#expect(result == nil)
	}

	@Test
	func emptySupportedListReturnsNil() {
		let result = SpeechLocaleResolution.resolve(
			preference: "en",
			supported: [],
			current: Locale(identifier: "en-US")
		)
		#expect(result == nil)
	}

	@Test
	func whitespacePreferenceBehavesLikeAuto() {
		let result = SpeechLocaleResolution.resolve(
			preference: "  ",
			supported: supported,
			current: Locale(identifier: "es-ES")
		)
		#expect(result?.identifier(.bcp47) == "es-ES")
	}
}
