import XCTest
@testable import HexCore

final class TextTransformationTests: XCTestCase {
	
	// MARK: - Individual Transformation Tests
	
	func testUppercase() async {
		let transform = Transformation(type: .uppercase)
		let result = await transform.transform("hello world")
		XCTAssertEqual(result, "HELLO WORLD")
	}
	
	func testLowercase() async {
		let transform = Transformation(type: .lowercase)
		let result = await transform.transform("HELLO WORLD")
		XCTAssertEqual(result, "hello world")
	}
	
	func testCapitalize() async {
		let transform = Transformation(type: .capitalize)
		let result = await transform.transform("hello world")
		XCTAssertEqual(result, "Hello World")
	}
	
	func testCapitalizeFirst() async {
		let transform = Transformation(type: .capitalizeFirst)
		let result = await transform.transform("hello world")
		XCTAssertEqual(result, "Hello world")
	}
	
	func testSpongebobCase() async {
		let transform = Transformation(type: .spongebobCase)
		let result = await transform.transform("hello")
		XCTAssertEqual(result, "hElLo")
	}
	
	func testTrimWhitespace() async {
		let transform = Transformation(type: .trimWhitespace)
		let result = await transform.transform("  hello world  ")
		XCTAssertEqual(result, "hello world")
	}
	
	func testRemoveExtraSpaces() async {
		let transform = Transformation(type: .removeExtraSpaces)
		let result = await transform.transform("hello    world")
		XCTAssertEqual(result, "hello world")
	}
	
	func testReplaceTextCaseInsensitive() async {
		let config = ReplaceTextConfig(
			pattern: "hello",
			replacement: "hi",
			caseSensitive: false
		)
		let transform = Transformation(type: .replaceText(config))
		let result = await transform.transform("Hello world")
		XCTAssertEqual(result, "hi world")
	}
	
	func testReplaceTextCaseSensitive() async {
		let config = ReplaceTextConfig(
			pattern: "Hello",
			replacement: "Hi",
			caseSensitive: true
		)
		let transform = Transformation(type: .replaceText(config))
		let result1 = await transform.transform("hello world")
		let result2 = await transform.transform("Hello world")
		XCTAssertEqual(result1, "hello world")
		XCTAssertEqual(result2, "Hi world")
	}
	
	func testReplaceTextRegex() async {
		let config = ReplaceTextConfig(
			pattern: "\\d+",
			replacement: "X",
			useRegex: true
		)
		let transform = Transformation(type: .replaceText(config))
		let result = await transform.transform("I have 42 apples and 7 oranges")
		XCTAssertEqual(result, "I have X apples and X oranges")
	}
	
	func testAddPrefix() async {
		let transform = Transformation(type: .addPrefix(">> "))
		let result = await transform.transform("hello")
		XCTAssertEqual(result, ">> hello")
	}
	
	func testAddSuffix() async {
		let transform = Transformation(type: .addSuffix("\n\nBest,\nJohn"))
		let result = await transform.transform("Thanks for your help")
		XCTAssertEqual(result, "Thanks for your help\n\nBest,\nJohn")
	}
	
	func testDisabledTransformation() async {
		var transform = Transformation(type: .uppercase)
		transform.isEnabled = false
		let result = await transform.transform("hello")
		XCTAssertEqual(result, "hello")
	}
	
	// MARK: - Pipeline Tests
	
	func testEmptyPipeline() async {
		let pipeline = TextTransformationPipeline()
		let result = await pipeline.process("hello")
		XCTAssertEqual(result, "hello")
	}
	
	func testDisabledPipeline() async {
		var pipeline = TextTransformationPipeline()
		pipeline.isEnabled = false
		pipeline.transformations = [
			Transformation(type: .uppercase)
		]
		let result = await pipeline.process("hello")
		XCTAssertEqual(result, "hello")
	}
	
	func testPipelineSequence() async {
		var pipeline = TextTransformationPipeline()
		pipeline.transformations = [
			Transformation(type: .trimWhitespace),
			Transformation(type: .removeExtraSpaces),
			Transformation(type: .capitalize)
		]
		
		let result = await pipeline.process("  hello    world  ")
		XCTAssertEqual(result, "Hello World")
	}
	
	func testPipelineWithDisabledTransformation() async {
		var pipeline = TextTransformationPipeline()
		var uppercaseTransform = Transformation(type: .uppercase)
		uppercaseTransform.isEnabled = false
		
		pipeline.transformations = [
			uppercaseTransform,
			Transformation(type: .addPrefix(">> "))
		]
		
		let result = await pipeline.process("hello")
		XCTAssertEqual(result, ">> hello")
	}
	
	func testComplexPipeline() async {
		var pipeline = TextTransformationPipeline()
		let replaceConfig = ReplaceTextConfig(
			pattern: "my email",
			replacement: "user@example.com"
		)
		
		pipeline.transformations = [
			Transformation(type: .trimWhitespace),
			Transformation(type: .replaceText(replaceConfig)),
			Transformation(type: .addSuffix("\n\nSent from Hex"))
		]
		
		let result = await pipeline.process(" Please contact my email ")
		XCTAssertEqual(result, "Please contact user@example.com\n\nSent from Hex")
	}
	
	func testPipelineMove() {
		var pipeline = TextTransformationPipeline()
		pipeline.transformations = [
			Transformation(type: .uppercase),
			Transformation(type: .lowercase),
			Transformation(type: .capitalize)
		]
		
		pipeline.move(from: 0, to: 2)
		
		XCTAssertEqual(pipeline.transformations[0].type, .lowercase)
		XCTAssertEqual(pipeline.transformations[1].type, .capitalize)
		XCTAssertEqual(pipeline.transformations[2].type, .uppercase)
	}
	
	// MARK: - Codable Tests
	
	func testTransformationEncodeDecode() throws {
		let original = Transformation(type: .replaceText(
			ReplaceTextConfig(pattern: "foo", replacement: "bar")
		))
		
		let encoded = try JSONEncoder().encode(original)
		let decoded = try JSONDecoder().decode(Transformation.self, from: encoded)
		
		XCTAssertEqual(original, decoded)
	}
	
	func testPipelineEncodeDecode() throws {
		var original = TextTransformationPipeline()
		original.transformations = [
			Transformation(type: .uppercase),
			Transformation(type: .lowercase),
			Transformation(type: .replaceText(
				ReplaceTextConfig(pattern: "test", replacement: "prod")
			))
		]
		
		let encoded = try JSONEncoder().encode(original)
		let decoded = try JSONDecoder().decode(TextTransformationPipeline.self, from: encoded)
		
		XCTAssertEqual(original, decoded)
	}
}
