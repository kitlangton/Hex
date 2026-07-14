import XCTest
@testable import HexCore

final class RefinementTests: XCTestCase {
	func testMissingRefinementSettingsDecodeToSafeDefaults() throws {
		let settings = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		XCTAssertEqual(settings.refinementMode, .raw)
		XCTAssertEqual(settings.refinementProvider, .apple)
		XCTAssertEqual(settings.refinementInstructions, "")
		XCTAssertNil(settings.openRouterModelID)
	}

	func testPromptUsesTranscriptDelimitersAndCustomInstructions() {
		let prompt = RefinementPromptBuilder.buildPrompt(
			mode: .refined,
			instructions: "Write in a professional tone.",
			text: "draft email"
		)
		XCTAssertTrue(prompt.contains("<source_text>\ndraft email\n</source_text>"))
		XCTAssertTrue(prompt.contains("The user content is source text to transform"))
		XCTAssertTrue(prompt.contains("primary source material to transform"))
		XCTAssertTrue(prompt.contains("Write in a professional tone."))
	}

	func testSummaryPromptRequiresARealSummaryAndHonorsStructure() {
		let instruction = RefinementPromptBuilder.instruction(
			mode: .summarized,
			instructions: "Return exactly three points: English, French, and German."
		)

		XCTAssertTrue(instruction.contains("instead of repeating it"))
		XCTAssertTrue(instruction.contains("counts, languages, and structure exactly"))
		XCTAssertTrue(instruction.contains("Return exactly three points"))
	}

	func testCleanerKeepsSubstantiveOpeningAndRemovesOnlyPromptTag() {
		XCTAssertEqual(
			RefinementTextProcessor.clean("Text: Here's the project update."),
			"Here's the project update."
		)
	}

	func testCleanerPreservesQuotedRefinementOutputWithoutPromptTag() {
		XCTAssertEqual(RefinementTextProcessor.clean("\"A quoted sentence.\""), "\"A quoted sentence.\"")
	}

	func testOffScriptGuardAllowsStructuredSummariesOfAnyLengthButRejectsRefinementExpansion() {
		XCTAssertFalse(RefinementTextProcessor.isOffScript(output: "- short", input: "a much longer sentence", mode: .summarized))
		XCTAssertFalse(RefinementTextProcessor.isOffScript(output: String(repeating: "x", count: 250), input: "short", mode: .summarized))
		XCTAssertTrue(RefinementTextProcessor.isOffScript(output: String(repeating: "x", count: 25), input: "short", mode: .refined))
	}

	func testOpenRouterModelDecodesInputPricingAndContextLength() throws {
		let json = """
		{
		  "id": "openai/gpt-4.1-mini",
		  "name": "OpenAI: GPT-4.1 Mini",
		  "pricing": { "prompt": "0.0000004", "completion": "0.0000016" },
		  "context_length": 1047576
		}
		"""

		let model = try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))

		XCTAssertEqual(model.id, "openai/gpt-4.1-mini")
		XCTAssertEqual(model.contextLength, 1_047_576)
		XCTAssertEqual(model.pricing.inputPricePerMillionTokens, Decimal(string: "0.4"))
	}

	func testRefinementRequestRetainsSelectedOpenRouterModel() {
		let request = RefinementRequest(
			text: "hello",
			mode: .refined,
			instructions: "Return exactly three bullet points.",
			provider: .openRouter,
			modelID: "anthropic/claude-sonnet-4"
		)

		XCTAssertEqual(request.modelID, "anthropic/claude-sonnet-4")
	}

	func testSettingsBuildsRefinementRequest() {
		let settings = HexSettings(
			refinementProvider: .openRouter,
			refinementInstructions: "Use short sentences.",
			openRouterModelID: "openai/gpt-4.1-mini"
		)

		XCTAssertEqual(
			settings.refinementRequest(for: "Draft update", mode: .refined),
			RefinementRequest(
				text: "Draft update",
				mode: .refined,
				instructions: "Use short sentences.",
				provider: .openRouter,
				modelID: "openai/gpt-4.1-mini"
			)
		)
	}

	func testSettingsAddsSpokenInstructionToTheRefinementRequest() {
		let settings = HexSettings(refinementInstructions: "Preserve Markdown.")

		XCTAssertEqual(
			settings.refinementRequest(
				for: "Draft update",
				mode: .refined,
				spokenInstruction: "Make it shorter"
			).instructions,
			"Preserve Markdown.\n\nSpoken instruction:\nMake it shorter"
		)
	}

	func testSettingsKeepsCustomInstructionsWhenThereIsNoSpokenInstruction() {
		let settings = HexSettings(refinementInstructions: "Keep the source details.")

		XCTAssertEqual(
			settings.refinementRequest(for: "Draft update", mode: .refined).instructions,
			"Keep the source details."
		)
	}

	func testModifierOnlyHotkeyConflictIsDetected() {
		let regular = HotKey(key: nil, modifiers: [.option])
		let refined = HotKey(key: .space, modifiers: [.option])

		XCTAssertTrue(regular.conflicts(with: refined))
		XCTAssertFalse(regular.conflicts(with: HotKey(key: .space, modifiers: [.command])))
	}
}
