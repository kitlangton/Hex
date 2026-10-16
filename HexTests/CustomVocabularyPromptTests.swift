import XCTest

@testable import HexCore

final class CustomVocabularyPromptTests: XCTestCase {

	// MARK: - parseTerms

	func testParseTermsSplitsOnCommasAndNewlines() {
		let terms = CustomVocabularyPrompt.parseTerms("Langton, Kit\nTCA,WhisperKit")
		XCTAssertEqual(terms, ["Langton", "Kit", "TCA", "WhisperKit"])
	}

	func testParseTermsTrimsWhitespaceAndDropsEmpties() {
		let terms = CustomVocabularyPrompt.parseTerms("  Langton ,, \n , TCA  ,\n\n")
		XCTAssertEqual(terms, ["Langton", "TCA"])
	}

	func testParseTermsEmptyInput() {
		XCTAssertEqual(CustomVocabularyPrompt.parseTerms(""), [])
		XCTAssertEqual(CustomVocabularyPrompt.parseTerms("  , \n ,"), [])
	}

	// MARK: - makePromptText

	func testMakePromptTextDisabledReturnsNil() {
		XCTAssertNil(CustomVocabularyPrompt.makePromptText(vocabulary: "Langton", isEnabled: false))
	}

	func testMakePromptTextEmptyVocabularyReturnsNil() {
		XCTAssertNil(CustomVocabularyPrompt.makePromptText(vocabulary: "", isEnabled: true))
		XCTAssertNil(CustomVocabularyPrompt.makePromptText(vocabulary: "  , \n", isEnabled: true))
	}

	func testMakePromptTextFormatsTermsAsLabeledList() {
		let prompt = CustomVocabularyPrompt.makePromptText(vocabulary: "Langton, TCA", isEnabled: true)
		XCTAssertEqual(prompt, "Vocabulary: Langton, TCA.")
	}

	func testMakePromptTextTrimsOverlongPromptToWholeTerms() {
		// ~30 terms of ~16 chars each exceeds maxPromptLength and must be trimmed
		let terms = (1...30).map { "VocabularyTerm\($0)" }
		let prompt = CustomVocabularyPrompt.makePromptText(
			vocabulary: terms.joined(separator: ", "),
			isEnabled: true
		)
		guard let prompt else { return XCTFail("expected non-nil prompt") }
		XCTAssertLessThanOrEqual(prompt.count, CustomVocabularyPrompt.maxPromptLength)
		XCTAssertTrue(prompt.hasPrefix("Vocabulary: "))
		XCTAssertTrue(prompt.hasSuffix("."))
		// Trimming must not cut a term in half: the tail term is removed whole
		XCTAssertFalse(prompt.contains("VocabularyTerm30"))
	}

	func testMakePromptTextSingleOverlongTermReturnsNil() {
		// One term longer than the whole budget: no comma to trim to, and the
		// term must never be split — so there is nothing usable to prompt with
		let hugeTerm = String(repeating: "a", count: CustomVocabularyPrompt.maxPromptLength)
		XCTAssertNil(CustomVocabularyPrompt.makePromptText(vocabulary: hugeTerm, isEnabled: true))
	}

	func testMakePromptTextOverlongFinalTermIsDropped() {
		// Short terms fit; a trailing over-long term is dropped rather than
		// pushing the prompt over the cap
		let hugeTail = String(repeating: "z", count: CustomVocabularyPrompt.maxPromptLength)
		let prompt = CustomVocabularyPrompt.makePromptText(
			vocabulary: "Langton, TCA, \(hugeTail)",
			isEnabled: true
		)
		XCTAssertEqual(prompt, "Vocabulary: Langton, TCA.")
	}

	func testMakePromptTextSkipsOverlongMiddleTermKeepsRest() {
		let hugeMiddle = String(repeating: "m", count: CustomVocabularyPrompt.maxPromptLength)
		let prompt = CustomVocabularyPrompt.makePromptText(
			vocabulary: "Langton, \(hugeMiddle), TCA",
			isEnabled: true
		)
		XCTAssertEqual(prompt, "Vocabulary: Langton, TCA.")
	}
}
