import XCTest
@testable import HexCore

final class RefinementTextProcessorTests: XCTestCase {

	// MARK: - stripPreamble

	func testStripPreambleRemovesCertainly() {
		let input = "Certainly! Here's the corrected version:\n\nThe meeting is at 3pm."
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripPreambleRemovesSure() {
		let input = "Sure, here you go:\n\nThe meeting is at 3pm."
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripPreambleRemovesHeres() {
		let input = "Here's the cleaned text:\n---\nThe meeting is at 3pm."
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripPreambleRemovesOfCourse() {
		let input = "Of course!\n\nThe meeting is at 3pm."
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripPreambleRemovesDashSeparators() {
		let input = "---\nThe meeting is at 3pm.\n---"
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripPreambleRemovesPostambleLetMeKnow() {
		let input = "The meeting is at 3pm.\n\nLet me know if you have any questions!"
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripPreambleRemovesPostambleFeelFree() {
		let input = "The meeting is at 3pm.\nFeel free to ask if you need anything."
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripPreambleRemovesPostambleIHope() {
		let input = "The meeting is at 3pm.\nI hope this helps!"
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripPreamblePreservesCleanText() {
		let input = "The meeting is at 3pm tomorrow."
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The meeting is at 3pm tomorrow.")
	}

	func testStripPreambleHandlesEmptyString() {
		let result = RefinementTextProcessor.stripPreamble("")
		XCTAssertEqual(result, "")
	}

	func testStripPreambleRemovesBothPreambleAndPostamble() {
		let input = "Certainly!\n---\nThe corrected text.\n---\nLet me know if you need anything."
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "The corrected text.")
	}

	func testStripPreamblePreservesMultilineContent() {
		let input = "First line of content.\nSecond line of content.\nThird line."
		let result = RefinementTextProcessor.stripPreamble(input)
		XCTAssertEqual(result, "First line of content.\nSecond line of content.\nThird line.")
	}

	// MARK: - stripLeakedTags

	func testStripLeakedTagsRemovesTextPrefix() {
		let input = "Text: The meeting is at 3pm."
		let result = RefinementTextProcessor.stripLeakedTags(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripLeakedTagsRemovesQuotes() {
		let input = "\"The meeting is at 3pm.\""
		let result = RefinementTextProcessor.stripLeakedTags(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripLeakedTagsTrimsWhitespace() {
		let input = "  The meeting is at 3pm.  "
		let result = RefinementTextProcessor.stripLeakedTags(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testStripLeakedTagsPreservesCleanText() {
		let input = "The meeting is at 3pm."
		let result = RefinementTextProcessor.stripLeakedTags(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	// MARK: - clean (full pipeline)

	func testCleanCombinesPreambleAndTagStripping() {
		let input = "Certainly!\n---\nThe meeting is at 3pm.\n---\nLet me know!"
		let result = RefinementTextProcessor.clean(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	func testCleanRemovesTextPrefixAndQuotes() {
		let input = "Text: \"The meeting is at 3pm.\""
		let result = RefinementTextProcessor.clean(input)
		XCTAssertEqual(result, "The meeting is at 3pm.")
	}

	// MARK: - isRefusal

	func testIsRefusalDetectsCantAssist() {
		XCTAssertTrue(RefinementTextProcessor.isRefusal("I can't assist with that request."))
	}

	func testIsRefusalDetectsApologize() {
		XCTAssertTrue(RefinementTextProcessor.isRefusal("I apologize, but I cannot help with this."))
	}

	func testIsRefusalDetectsUnable() {
		XCTAssertTrue(RefinementTextProcessor.isRefusal("I'm unable to process this request."))
	}

	func testIsRefusalReturnsFalseForNormalText() {
		XCTAssertFalse(RefinementTextProcessor.isRefusal("The meeting is at 3pm."))
	}

	func testIsRefusalIsCaseInsensitive() {
		XCTAssertTrue(RefinementTextProcessor.isRefusal("I CAN'T ASSIST with that."))
	}

	// MARK: - isOffScript

	func testIsOffScriptDetectsLongRefinedOutput() {
		let input = "Short input."
		let output = String(repeating: "a", count: input.count * 2) // 2x length
		XCTAssertTrue(RefinementTextProcessor.isOffScript(output: output, input: input, mode: .refined))
	}

	func testIsOffScriptAllowsReasonableRefinedOutput() {
		let input = "The meeting is at three pm tomorrow."
		let output = "The meeting is at 3:00 PM tomorrow afternoon."
		XCTAssertFalse(RefinementTextProcessor.isOffScript(output: output, input: input, mode: .refined))
	}

	func testIsOffScriptStricterForSummarized() {
		let input = "This is a fairly long input that should be summarized."
		// 1.3x length — too long for summary but fine for refined
		let output = String(repeating: "a", count: Int(Double(input.count) * 1.3))
		XCTAssertTrue(RefinementTextProcessor.isOffScript(output: output, input: input, mode: .summarized))
		XCTAssertFalse(RefinementTextProcessor.isOffScript(output: output, input: input, mode: .refined))
	}

	func testIsOffScriptHandlesEmptyInput() {
		let output = "Some output"
		XCTAssertTrue(RefinementTextProcessor.isOffScript(output: output, input: "", mode: .refined))
	}

	func testIsOffScriptAllowsShorterOutput() {
		let input = "Um so like the meeting is at three pm tomorrow you know."
		let output = "The meeting is at 3pm tomorrow."
		XCTAssertFalse(RefinementTextProcessor.isOffScript(output: output, input: input, mode: .refined))
	}

	func testIsOffScriptRawModeUsesRefinedThreshold() {
		// .raw should never reach isOffScript, but if it does, it uses refined ratio
		let input = "Short."
		let output = String(repeating: "a", count: input.count * 2)
		XCTAssertTrue(RefinementTextProcessor.isOffScript(output: output, input: input, mode: .raw))
	}

	// MARK: - isCancellation (Fix #2)

	func testIsCancellationDetectsCancellationError() {
		let error = CancellationError()
		XCTAssertTrue(RefinementTextProcessor.isCancellation(error))
	}

	func testIsCancellationReturnsFalseForOtherErrors() {
		let error = NSError(domain: "test", code: 42)
		XCTAssertFalse(RefinementTextProcessor.isCancellation(error))
	}

	func testIsCancellationReturnsFalseForURLError() {
		let error = URLError(.timedOut)
		XCTAssertFalse(RefinementTextProcessor.isCancellation(error))
	}

	func testIsCancellationReturnsFalseForDecodingError() {
		// A generic Swift error
		struct CustomError: Error {}
		XCTAssertFalse(RefinementTextProcessor.isCancellation(CustomError()))
	}
}
