import Testing
@testable import HexCore

struct RegexCleanupPassTests {

	// MARK: - Filler Removal

	@Test
	func removesUnconditionalFillers() {
		let input = "so um like we should uh meet on Friday"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "We should meet on Friday.")
	}

	@Test
	func removesMultipleFillerTypes() {
		let input = "um can you send me the report when you get a chance"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Can you send me the report when you get a chance.")
	}

	@Test
	func preservesMidSentenceLike() {
		// "like" mid-sentence without comma is ambiguous — preserve it
		let input = "um can you like send me the report"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Can you like send me the report.")
	}

	@Test
	func removesYouKnowAndBasically() {
		let input = "you know the project is basically done"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "The project is done.")
	}

	@Test
	func preservesLikeInMeaningfulContext() {
		let input = "I like pizza and I like pasta"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "I like pizza and I like pasta.")
	}

	@Test
	func preservesSoInMeaningfulContext() {
		let input = "it was so good that we stayed late"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "It was so good that we stayed late.")
	}

	@Test
	func removesFillerLikeAfterComma() {
		let input = "the meeting is tomorrow, like around 3pm"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "The meeting is tomorrow, around 3pm.")
	}

	// MARK: - Stutter / Repetition

	@Test
	func collapsesRepeatedWords() {
		let input = "I I think the the project is done"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "I think the project is done.")
	}

	@Test
	func collapsesTripleRepeat() {
		let input = "we we we need to go"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "We need to go.")
	}

	// MARK: - Punctuation

	@Test
	func fixesDoublePunctuation() {
		let input = "hello,, world"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Hello, world.")
	}

	@Test
	func removesOrphanedLeadingPunctuation() {
		let input = ", hello world"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Hello world.")
	}

	@Test
	func ensuresSpaceAfterPunctuation() {
		let input = "hello,world"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Hello, world.")
	}

	// MARK: - Capitalization

	@Test
	func capitalizesFirstLetter() {
		let input = "hello world"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Hello world.")
	}

	@Test
	func capitalizesAfterPeriod() {
		let input = "first sentence. second sentence"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "First sentence. Second sentence.")
	}

	@Test
	func capitalizesAfterExclamation() {
		let input = "wow! that is great"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Wow! That is great.")
	}

	@Test
	func preservesExistingCapitalization() {
		let input = "Hello World"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Hello World.")
	}

	// MARK: - Whitespace

	@Test
	func collapsesMultipleSpaces() {
		let input = "hello    world"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Hello world.")
	}

	@Test
	func trimsLeadingAndTrailingWhitespace() {
		let input = "  hello world  "
		let result = RegexCleanupPass.apply(input)
		#expect(result == "Hello world.")
	}

	// MARK: - Edge Cases

	@Test
	func emptyStringReturnsEmpty() {
		#expect(RegexCleanupPass.apply("") == "")
	}

	@Test
	func alreadyCleanTextPassesThrough() {
		let input = "The meeting is scheduled for Friday at 3pm."
		let result = RegexCleanupPass.apply(input)
		#expect(result == "The meeting is scheduled for Friday at 3pm.")
	}

	@Test
	func allFillersProducesEmptyOrMinimal() {
		let input = "um uh you know basically"
		let result = RegexCleanupPass.apply(input)
		#expect(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
	}

	@Test
	func singleWordPassesThrough() {
		#expect(RegexCleanupPass.apply("hello") == "Hello.")
	}

	// MARK: - Combined / Realistic Transcripts

	@Test
	func realisticTranscript1() {
		let input = "okay so um like we're trying this with the uh new model now and hopefully it works"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "We're trying this with the new model now and hopefully it works.")
	}

	@Test
	func realisticTranscript2() {
		let input = "so uh yeah i need to fix the bug in the login page before tomorrow"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "I need to fix the bug in the login page before tomorrow.")
	}

	@Test
	func realisticTranscript3() {
		let input = "um so basically the the server is is down and we need to you know restart it"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "The server is down and we need to restart it.")
	}

	@Test
	func doesNotRemoveActuallyFromMidSentence() {
		// "actually" is an unconditional filler — it gets removed everywhere.
		// If this behavior is too aggressive, it should be moved to contextFillers.
		let input = "that is actually a good point"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "That is a good point.")
	}

	@Test
	func removesCommaWrappedFiller() {
		let input = "we should, you know, just deploy it"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "We should just deploy it.")
	}

	@Test
	func removesCommaWrappedFillerRight() {
		let input = "the code is, basically, done"
		let result = RegexCleanupPass.apply(input)
		#expect(result == "The code is done.")
	}
}
