import Testing
@testable import HexCore

struct TranscriptFormattingTests {
	@Test
	func lowercasesTranscript() {
		let result = TranscriptFormattingApplier.apply(
			"Hello WORLD!",
			lowercase: true,
			removePunctuation: false,
			removeTrailingPunctuation: false
		)

		#expect(result == "hello world!")
	}

	@Test
	func removesUnicodePunctuation() {
		let result = TranscriptFormattingApplier.apply(
			"Hello, world! It’s well-known — really.",
			lowercase: false,
			removePunctuation: true,
			removeTrailingPunctuation: false
		)

		#expect(result == "Hello world Its wellknown  really")
	}

	@Test
	func appliesBothOptionsIndependently() {
		let result = TranscriptFormattingApplier.apply(
			"Hello, WORLD!",
			lowercase: true,
			removePunctuation: true,
			removeTrailingPunctuation: false
		)

		#expect(result == "hello world")
	}

	@Test
	func leavesTranscriptUnchangedWhenDisabled() {
		let input = "Hello, WORLD!"
		let result = TranscriptFormattingApplier.apply(
			input,
			lowercase: false,
			removePunctuation: false,
			removeTrailingPunctuation: false
		)

		#expect(result == input)
	}

	@Test
	func removesOnlyTrailingPunctuation() {
		let result = TranscriptFormattingApplier.apply(
			"The quick, brown fox jumped over the lazy dog.",
			lowercase: false,
			removePunctuation: false,
			removeTrailingPunctuation: true
		)

		#expect(result == "The quick, brown fox jumped over the lazy dog")
	}

	@Test
	func removesRunOfTrailingPunctuation() {
		let result = TranscriptFormattingApplier.apply(
			"Wait, what?!…",
			lowercase: false,
			removePunctuation: false,
			removeTrailingPunctuation: true
		)

		#expect(result == "Wait, what")
	}

	@Test
	func keepsTrailingWhitespaceWhenRemovingTrailingPunctuation() {
		let result = TranscriptFormattingApplier.apply(
			"Good dog. ",
			lowercase: false,
			removePunctuation: false,
			removeTrailingPunctuation: true
		)

		#expect(result == "Good dog ")
	}

	@Test
	func leavesTranscriptWithoutTrailingPunctuationUnchanged() {
		let input = "The quick, brown fox"
		let result = TranscriptFormattingApplier.apply(
			input,
			lowercase: false,
			removePunctuation: false,
			removeTrailingPunctuation: true
		)

		#expect(result == input)
	}

	@Test
	func removePunctuationSupersedesTrailingRemoval() {
		let result = TranscriptFormattingApplier.apply(
			"Hello, world!",
			lowercase: false,
			removePunctuation: true,
			removeTrailingPunctuation: true
		)

		#expect(result == "Hello world")
	}

	@Test
	func leavesWhitespaceOnlyTranscriptUnchanged() {
		let input = "   "
		let result = TranscriptFormattingApplier.apply(
			input,
			lowercase: false,
			removePunctuation: false,
			removeTrailingPunctuation: true
		)

		#expect(result == input)
	}
}
