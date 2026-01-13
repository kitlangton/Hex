import Testing
@testable import HexCore

struct WordRemappingTests {
	@Test
	func basicRemapping() {
		let remappings = [
			WordRemapping(match: "comma", replacement: ",")
		]
		let result = WordRemappingApplier.apply("Hello comma world", remappings: remappings)
		#expect(result == "Hello , world")
	}

	@Test
	func newlineEscapeSequence() {
		let remappings = [
			WordRemapping(match: "new line", replacement: "\\n")
		]
		let result = WordRemappingApplier.apply("Hello new line world", remappings: remappings)
		#expect(result == "Hello \n world")
	}

	@Test
	func newParagraphEscapeSequence() {
		let remappings = [
			WordRemapping(match: "new paragraph", replacement: "\\n\\n")
		]
		let result = WordRemappingApplier.apply("Hello new paragraph world", remappings: remappings)
		#expect(result == "Hello \n\n world")
	}

	@Test
	func tabEscapeSequence() {
		let remappings = [
			WordRemapping(match: "tab", replacement: "\\t")
		]
		let result = WordRemappingApplier.apply("Hello tab world", remappings: remappings)
		#expect(result == "Hello \t world")
	}

	@Test
	func escapedBackslash() {
		let remappings = [
			WordRemapping(match: "backslash", replacement: "\\\\")
		]
		let result = WordRemappingApplier.apply("Hello backslash world", remappings: remappings)
		#expect(result == "Hello \\ world")
	}

	@Test
	func literalBackslashN() {
		let remappings = [
			WordRemapping(match: "code", replacement: "\\\\n")
		]
		let result = WordRemappingApplier.apply("Hello code world", remappings: remappings)
		#expect(result == "Hello \\n world")
	}

	@Test
	func caseInsensitive() {
		let remappings = [
			WordRemapping(match: "COMMA", replacement: ",")
		]
		let result = WordRemappingApplier.apply("Hello comma world", remappings: remappings)
		#expect(result == "Hello , world")
	}

	@Test
	func doesNotRemapInsideWords() {
		let remappings = [
			WordRemapping(match: "new", replacement: "\\n")
		]
		let result = WordRemappingApplier.apply("renewable energy", remappings: remappings)
		#expect(result == "renewable energy")
	}

	@Test
	func disabledRemappingIgnored() {
		let remappings = [
			WordRemapping(isEnabled: false, match: "comma", replacement: ",")
		]
		let result = WordRemappingApplier.apply("Hello comma world", remappings: remappings)
		#expect(result == "Hello comma world")
	}

	@Test
	func multipleRemappings() {
		let remappings = [
			WordRemapping(match: "comma", replacement: ","),
			WordRemapping(match: "period", replacement: "."),
			WordRemapping(match: "new line", replacement: "\\n")
		]
		let result = WordRemappingApplier.apply("Hello comma new line world period", remappings: remappings)
		#expect(result == "Hello , \n world .")
	}
}
