import Testing
@testable import HexCore

struct TranscriptFormattingTests {
	@Test
	func lowercasesTranscript() {
		let result = TranscriptFormattingApplier.apply(
			"Hello WORLD!",
			lowercase: true,
			removePunctuation: false
		)

		#expect(result == "hello world!")
	}

	@Test
	func removesUnicodePunctuation() {
		let result = TranscriptFormattingApplier.apply(
			"Hello, world! It’s well-known — really.",
			lowercase: false,
			removePunctuation: true
		)

		#expect(result == "Hello world Its wellknown  really")
	}

	@Test
	func appliesBothOptionsIndependently() {
		let result = TranscriptFormattingApplier.apply(
			"Hello, WORLD!",
			lowercase: true,
			removePunctuation: true
		)

		#expect(result == "hello world")
	}

	@Test
	func leavesTranscriptUnchangedWhenDisabled() {
		let input = "Hello, WORLD!"
		let result = TranscriptFormattingApplier.apply(
			input,
			lowercase: false,
			removePunctuation: false
		)

		#expect(result == input)
	}
}
