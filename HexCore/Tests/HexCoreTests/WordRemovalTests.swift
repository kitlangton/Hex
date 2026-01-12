import Testing
@testable import HexCore

struct WordRemovalTests {
	@Test
	func removesFillerWordsAndRepeats() {
		let removals = [
			WordRemoval(pattern: "uh+"),
			WordRemoval(pattern: "um+"),
			WordRemoval(pattern: "er+"),
			WordRemoval(pattern: "hm+")
		]
		let result = WordRemovalApplier.apply("Umm uhhh er hmm", removals: removals)
		#expect(result.isEmpty)
	}

	@Test
	func cleansSpacesAndPunctuation() {
		let removals = [
			WordRemoval(pattern: "uh+"),
			WordRemoval(pattern: "um+")
		]
		let result = WordRemovalApplier.apply("Well, um, that's uh fine", removals: removals)
		#expect(result == "Well, that's fine")
	}

	@Test
	func doesNotRemoveInsideWords() {
		let result = WordRemovalApplier.apply("thumb", removals: [WordRemoval(pattern: "um+")])
		#expect(result == "thumb")
	}

	@Test
	func removesLeadingPunctuation() {
		let result = WordRemovalApplier.apply("um, hello", removals: [WordRemoval(pattern: "um+")])
		#expect(result == "hello")
	}
}
