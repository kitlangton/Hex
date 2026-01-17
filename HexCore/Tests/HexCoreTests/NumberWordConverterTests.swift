import Testing
@testable import HexCore

struct NumberWordConverterTests {
	// MARK: - Basic Cardinals

	@Test
	func convertsBasicOnes() {
		#expect(NumberWordConverter.apply("zero") == "0")
		#expect(NumberWordConverter.apply("one") == "1")
		#expect(NumberWordConverter.apply("five") == "5")
		#expect(NumberWordConverter.apply("nine") == "9")
	}

	@Test
	func convertsTeens() {
		#expect(NumberWordConverter.apply("ten") == "10")
		#expect(NumberWordConverter.apply("eleven") == "11")
		#expect(NumberWordConverter.apply("fifteen") == "15")
		#expect(NumberWordConverter.apply("nineteen") == "19")
	}

	@Test
	func convertsTens() {
		#expect(NumberWordConverter.apply("twenty") == "20")
		#expect(NumberWordConverter.apply("fifty") == "50")
		#expect(NumberWordConverter.apply("ninety") == "90")
	}

	@Test
	func convertsTwentyFive() {
		#expect(NumberWordConverter.apply("twenty five") == "25")
	}

	@Test
	func convertsHyphenatedNumbers() {
		#expect(NumberWordConverter.apply("twenty-five") == "25")
		#expect(NumberWordConverter.apply("forty-two") == "42")
		#expect(NumberWordConverter.apply("ninety-nine") == "99")
	}

	// MARK: - Compound Numbers

	@Test
	func convertsHundreds() {
		#expect(NumberWordConverter.apply("one hundred") == "100")
		#expect(NumberWordConverter.apply("five hundred") == "500")
	}

	@Test
	func convertsHundredsWithTens() {
		#expect(NumberWordConverter.apply("one hundred twenty three") == "123")
		#expect(NumberWordConverter.apply("two hundred fifty six") == "256")
	}

	@Test
	func convertsWithAndConnector() {
		#expect(NumberWordConverter.apply("one hundred and twenty three") == "123")
		#expect(NumberWordConverter.apply("five hundred and one") == "501")
	}

	@Test
	func convertsThousands() {
		#expect(NumberWordConverter.apply("one thousand") == "1000")
		#expect(NumberWordConverter.apply("five thousand") == "5000")
	}

	@Test
	func convertsComplexNumbers() {
		#expect(NumberWordConverter.apply("one thousand three hundred thirty six") == "1336")
		#expect(NumberWordConverter.apply("two thousand five hundred") == "2500")
	}

	@Test
	func convertsMillions() {
		#expect(NumberWordConverter.apply("one million") == "1000000")
		#expect(NumberWordConverter.apply("two million five hundred thousand") == "2500000")
	}

	// MARK: - Decimals

	@Test
	func convertsDecimals() {
		#expect(NumberWordConverter.apply("three point one four") == "3.14")
		#expect(NumberWordConverter.apply("zero point five") == "0.5")
		#expect(NumberWordConverter.apply("one point zero") == "1.0")
	}

	@Test
	func convertsDecimalsWithMultipleDigits() {
		#expect(NumberWordConverter.apply("three point one four one five nine") == "3.14159")
	}

	// MARK: - Mixed Text

	@Test
	func handlesMixedText() {
		#expect(NumberWordConverter.apply("I have twenty five apples") == "I have 25 apples")
		#expect(NumberWordConverter.apply("There are one hundred people here") == "There are 100 people here")
	}

	@Test
	func handlesMultipleNumbersInText() {
		#expect(NumberWordConverter.apply("I have two cats and three dogs") == "I have 2 cats and 3 dogs")
	}

	@Test
	func preservesPunctuation() {
		#expect(NumberWordConverter.apply("I have twenty five apples.") == "I have 25 apples.")
		#expect(NumberWordConverter.apply("Is it twenty five?") == "Is it 25?")
	}

	// MARK: - Word Boundary Preservation

	@Test
	func doesNotConvertInsideWords() {
		#expect(NumberWordConverter.apply("someone") == "someone")
		#expect(NumberWordConverter.apply("threesome") == "threesome")
		#expect(NumberWordConverter.apply("anyone") == "anyone")
		#expect(NumberWordConverter.apply("tone") == "tone")
		#expect(NumberWordConverter.apply("stone") == "stone")
	}

	// MARK: - Case Insensitivity

	@Test
	func isCaseInsensitive() {
		#expect(NumberWordConverter.apply("Twenty Five") == "25")
		#expect(NumberWordConverter.apply("TWENTY FIVE") == "25")
		#expect(NumberWordConverter.apply("One Hundred") == "100")
	}

	// MARK: - Edge Cases

	@Test
	func handlesEmptyString() {
		#expect(NumberWordConverter.apply("") == "")
	}

	@Test
	func handlesNoNumbers() {
		#expect(NumberWordConverter.apply("hello world") == "hello world")
		#expect(NumberWordConverter.apply("The quick brown fox") == "The quick brown fox")
	}

	@Test
	func preservesExistingDigits() {
		#expect(NumberWordConverter.apply("I have 5 apples") == "I have 5 apples")
		#expect(NumberWordConverter.apply("25 items") == "25 items")
	}

	@Test
	func handlesOnlyWhitespace() {
		#expect(NumberWordConverter.apply("   ") == "   ")
	}
}
