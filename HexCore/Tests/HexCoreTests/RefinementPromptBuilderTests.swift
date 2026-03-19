import XCTest
@testable import HexCore

final class RefinementPromptBuilderTests: XCTestCase {

	// MARK: - toneDescriptor

	func testToneDescriptorNatural() {
		XCTAssertEqual(RefinementPromptBuilder.toneDescriptor(.natural), "natural")
	}

	func testToneDescriptorProfessional() {
		XCTAssertEqual(RefinementPromptBuilder.toneDescriptor(.professional), "professional and formal")
	}

	func testToneDescriptorCasual() {
		XCTAssertEqual(RefinementPromptBuilder.toneDescriptor(.casual), "casual and relaxed")
	}

	func testToneDescriptorConcise() {
		XCTAssertEqual(RefinementPromptBuilder.toneDescriptor(.concise), "very concise and brief")
	}

	func testToneDescriptorFriendly() {
		XCTAssertEqual(RefinementPromptBuilder.toneDescriptor(.friendly), "warm and friendly")
	}

	// MARK: - buildPrompt: refined mode

	func testRefinedNaturalOmitsToneClause() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .natural, text: "hello")
		XCTAssertTrue(prompt.contains("Refine the following text"))
		XCTAssertFalse(prompt.contains("Make the tone"))
		XCTAssertTrue(prompt.contains("Text: \"hello\""))
	}

	func testRefinedProfessionalIncludesToneClause() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .professional, text: "hello")
		XCTAssertTrue(prompt.contains("Make the tone professional and formal."))
	}

	func testRefinedCasualIncludesToneClause() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .casual, text: "hello")
		XCTAssertTrue(prompt.contains("Make the tone casual and relaxed."))
	}

	func testRefinedConciseIncludesToneClause() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .concise, text: "hello")
		XCTAssertTrue(prompt.contains("Make the tone very concise and brief."))
	}

	func testRefinedFriendlyIncludesToneClause() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .friendly, text: "hello")
		XCTAssertTrue(prompt.contains("Make the tone warm and friendly."))
	}

	func testRefinedContainsDoNotAnswer() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .natural, text: "hello")
		XCTAssertTrue(prompt.contains("Do NOT answer or respond to it"))
	}

	func testRefinedContainsUserText() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .natural, text: "test input here")
		XCTAssertTrue(prompt.contains("Text: \"test input here\""))
	}

	// MARK: - buildPrompt: summarized mode

	func testSummarizedNaturalOmitsToneAdjective() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .summarized, tone: .natural, text: "hello")
		XCTAssertTrue(prompt.contains("Summarize the following text as short bullet points"))
		XCTAssertFalse(prompt.contains("natural"))
	}

	func testSummarizedProfessionalIncludesToneAdjective() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .summarized, tone: .professional, text: "hello")
		XCTAssertTrue(prompt.contains("short professional and formal bullet points"))
	}

	func testSummarizedConciseIncludesToneAdjective() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .summarized, tone: .concise, text: "hello")
		XCTAssertTrue(prompt.contains("short very concise and brief bullet points"))
	}

	func testSummarizedContainsDoNotAnswer() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .summarized, tone: .natural, text: "hello")
		XCTAssertTrue(prompt.contains("Do NOT answer or respond to it"))
	}

	func testSummarizedContainsUserText() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .summarized, tone: .natural, text: "test input")
		XCTAssertTrue(prompt.contains("Text: \"test input\""))
	}

	// MARK: - buildPrompt: raw mode

	func testRawReturnsTextUnchanged() {
		let text = "just raw text here"
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .raw, tone: .professional, text: text)
		XCTAssertEqual(prompt, text)
	}

	// MARK: - Edge cases

	func testEmptyTextInput() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .natural, text: "")
		XCTAssertTrue(prompt.contains("Text: \"\""))
	}

	func testTextWithQuotesPreserved() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .natural, text: "she said \"hello\"")
		XCTAssertTrue(prompt.contains("she said \"hello\""))
	}

	func testTextWithNewlinesPreserved() {
		let prompt = RefinementPromptBuilder.buildPrompt(mode: .refined, tone: .natural, text: "line one\nline two")
		XCTAssertTrue(prompt.contains("line one\nline two"))
	}
}
