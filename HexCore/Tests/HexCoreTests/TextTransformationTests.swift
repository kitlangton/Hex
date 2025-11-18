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
		let stack = TransformationStack(name: "Custom", pipeline: customPipeline, isDefault: true)
		let state = TextTransformationsState(stacks: [stack])
		let data = try JSONEncoder().encode(state)
		let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		let version = jsonObject?["schemaVersion"] as? Int
		XCTAssertEqual(version, TextTransformationsState.currentSchemaVersion)
	}

	func testLegacyStateMigratesToStackBasedSchema() throws {
		let data = try loadTextTransformationFixture(named: "v0")
		let decoded = try JSONDecoder().decode(TextTransformationsState.self, from: data)
		XCTAssertEqual(decoded.schemaVersion, TextTransformationsState.currentSchemaVersion)
		XCTAssertEqual(decoded.stacks.count, 1)
		XCTAssertTrue(decoded.stacks[0].isDefault)
		XCTAssertEqual(decoded.stacks[0].pipeline.transformations.count, 1)
	}

	func testPipelineSelectionPrefersMatchingBundle() {
		var bundlePipeline = TextTransformationPipeline()
		bundlePipeline.transformations = [Transformation(type: .addPrefix("[Docs] "))]
		var defaultPipeline = TextTransformationPipeline()
		defaultPipeline.transformations = [Transformation(type: .uppercase)]
		let bundleStack = TransformationStack(
			name: "Docs",
			pipeline: bundlePipeline,
			appliesToBundleIdentifiers: ["com.apple.TextEdit"],
			isDefault: false
		)
		let defaultStack = TransformationStack(name: "Default", pipeline: defaultPipeline, isDefault: true)
		let state = TextTransformationsState(stacks: [bundleStack, defaultStack])
		let selected = state.pipeline(for: "com.apple.TextEdit")
		XCTAssertEqual(selected.transformations.count, bundlePipeline.transformations.count)
		let fallback = state.pipeline(for: "com.apple.Mail")
		XCTAssertEqual(fallback.transformations.count, defaultPipeline.transformations.count)
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
