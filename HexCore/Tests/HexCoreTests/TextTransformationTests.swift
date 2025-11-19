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
			replacement: "hi"
		)
		let transform = Transformation(type: .replaceText(config))
		let result = await transform.transform("Hello world")
		XCTAssertEqual(result, "hi world")
	}

	func testReplaceTextAlwaysCaseInsensitive() async {
		let config = ReplaceTextConfig(
			pattern: "HELLO",
			replacement: "Hi"
		)
		let transform = Transformation(type: .replaceText(config))
		let result = await transform.transform("hello world")
		XCTAssertEqual(result, "Hi world")
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

	// MARK: - State Persistence Tests

	func testStateEncodingIncludesSchemaVersion() throws {
		var customPipeline = TextTransformationPipeline()
		customPipeline.transformations = [Transformation(type: .uppercase)]
		let mode = TransformationMode(name: "Custom", pipeline: customPipeline)
		let state = TextTransformationsState(modes: [mode])
		let data = try JSONEncoder().encode(state)
		let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		let version = jsonObject?["schemaVersion"] as? Int
		XCTAssertEqual(version, TextTransformationsState.currentSchemaVersion)
	}

	func testLegacyStateMigratesToModeBasedSchema() throws {
		let data = try loadTextTransformationFixture(named: "v0")
		let decoded = try JSONDecoder().decode(TextTransformationsState.self, from: data)
		XCTAssertEqual(decoded.schemaVersion, TextTransformationsState.currentSchemaVersion)
		XCTAssertEqual(decoded.modes.count, 1)
		XCTAssertEqual(decoded.modes[0].pipeline.transformations.count, 1)
	}

	func testPipelineSelectionPrefersMatchingBundle() {
		var bundlePipeline = TextTransformationPipeline()
		bundlePipeline.transformations = [Transformation(type: .addPrefix("[Docs] "))]
		var defaultPipeline = TextTransformationPipeline()
		defaultPipeline.transformations = [Transformation(type: .uppercase)]
		let bundleMode = TransformationMode(
			name: "Docs",
			pipeline: bundlePipeline,
			appliesToBundleIdentifiers: ["com.apple.TextEdit"]
		)
		let defaultMode = TransformationMode(name: "Default", pipeline: defaultPipeline)
		let state = TextTransformationsState(modes: [bundleMode, defaultMode])
		let selected = state.pipeline(for: "com.apple.TextEdit")
		XCTAssertEqual(selected.transformations.count, bundlePipeline.transformations.count)
		let fallback = state.pipeline(for: "com.apple.Mail")
		XCTAssertEqual(fallback.transformations.count, defaultPipeline.transformations.count)
	}

	// MARK: - Voice Prefix Tests

	func testVoicePrefixWithComma() {
		var pipeline = TextTransformationPipeline()
		pipeline.transformations = [Transformation(type: .uppercase)]
		let mode = TransformationMode(
			name: "Shakespeare",
			pipeline: pipeline,
			voicePrefixes: ["Shakespeare"]
		)
		let state = TextTransformationsState(modes: [mode])

		// Test with comma attached to prefix (the failing case)
		let result1 = state.modeByVoicePrefix(text: "Shakespeare, I have to take out the trash")
		XCTAssertNotNil(result1, "Should match 'Shakespeare,' with comma")
		XCTAssertEqual(result1?.strippedText, "I have to take out the trash")

		// Test with comma and space
		let result2 = state.modeByVoicePrefix(text: "Shakespeare, I have no way to go")
		XCTAssertNotNil(result2, "Should match 'Shakespeare, ' with comma and space")
		XCTAssertEqual(result2?.strippedText, "I have no way to go")

		// Test without comma
		let result3 = state.modeByVoicePrefix(text: "Shakespeare I am here")
		XCTAssertNotNil(result3, "Should match 'Shakespeare' without comma")
		XCTAssertEqual(result3?.strippedText, "I am here")
	}

	func testVoicePrefixWithPunctuation() {
		var pipeline = TextTransformationPipeline()
		pipeline.transformations = [Transformation(type: .uppercase)]
		let mode = TransformationMode(
			name: "Command",
			pipeline: pipeline,
			voicePrefixes: ["Hey"]
		)
		let state = TextTransformationsState(modes: [mode])

		// Various punctuation scenarios
		let testCases: [(String, String)] = [
			("Hey, hello there", "hello there"),
			("Hey! hello there", "hello there"),
			("Hey. hello there", "hello there"),
			("Hey; hello there", "hello there"),
			("Hey: hello there", "hello there"),
			("Hey? hello there", "hello there")
		]

		for (input, expected) in testCases {
			let result = state.modeByVoicePrefix(text: input)
			XCTAssertNotNil(result, "Should match '\(input)'")
			XCTAssertEqual(result?.strippedText, expected, "Failed for input: \(input)")
		}
	}

	private func loadTextTransformationFixture(named name: String) throws -> Data {
		guard let url = Bundle.module.url(
			forResource: name,
			withExtension: "json",
			subdirectory: "Fixtures/TextTransformations"
		) else {
			XCTFail("Missing TextTransformations fixture \(name)")
			throw NSError(domain: "Fixture", code: 0)
		}
		return try Data(contentsOf: url)
	}
}
