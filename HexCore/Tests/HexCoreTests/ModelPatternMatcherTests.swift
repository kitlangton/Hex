import Testing
@testable import HexCore

struct ModelPatternMatcherTests {
	@Test
	func stripsTrailingSizeSuffix() {
		let stripped = ModelPatternMatcher.stripSizeSuffix("openai_whisper-large-v3-v20240930_626MB")
		#expect(stripped == "openai_whisper-large-v3-v20240930")
	}

	@Test
	func leavesNameWithoutSuffixUnchanged() {
		let stripped = ModelPatternMatcher.stripSizeSuffix("openai_whisper-large-v3")
		#expect(stripped == "openai_whisper-large-v3")
	}

	@Test
	func doesNotStripSuffixInMiddle() {
		let stripped = ModelPatternMatcher.stripSizeSuffix("openai_626MB_whisper")
		#expect(stripped == "openai_626MB_whisper")
	}

	@Test
	func doesNotStripWithoutLeadingUnderscore() {
		let stripped = ModelPatternMatcher.stripSizeSuffix("626MB")
		#expect(stripped == "626MB")
	}

	@Test
	func flexibleMatchesExactName() {
		#expect(ModelPatternMatcher.matchesFlexible("openai_whisper-tiny", "openai_whisper-tiny"))
	}

	@Test
	func flexibleMatchesGlobPattern() {
		#expect(ModelPatternMatcher.matchesFlexible("openai_whisper-tiny*", "openai_whisper-tiny-v1"))
	}

	@Test
	func flexibleMatchesCatalogNameAgainstRenamedConcrete() {
		// Catalog entry without suffix; on-disk/HF concrete name gained `_626MB`.
		#expect(ModelPatternMatcher.matchesFlexible(
			"openai_whisper-large-v3-v20240930",
			"openai_whisper-large-v3-v20240930_626MB"
		))
	}

	@Test
	func flexibleMatchesSuffixedAgainstBase() {
		// And the reverse direction for non-glob inputs.
		#expect(ModelPatternMatcher.matchesFlexible(
			"openai_whisper-large-v3-v20240930_626MB",
			"openai_whisper-large-v3-v20240930"
		))
	}

	@Test
	func flexibleRejectsUnrelatedNames() {
		#expect(!ModelPatternMatcher.matchesFlexible("openai_whisper-tiny", "openai_whisper-large"))
	}

	@Test
	func flexibleRejectsDegenerateEmptyStrip() {
		// Both sides strip to empty -- must not be treated as matching.
		#expect(!ModelPatternMatcher.matchesFlexible("_626MB", "_500MB"))
	}

	@Test
	func flexibleRegressionGlobPatternFirst() {
		// Regression: download-completion used to pass the concrete resolved
		// model name as `pattern` and the glob-bearing catalog entry as `text`,
		// which caused fnmatch to treat the glob as a literal and fail to match.
		// This test documents the expected pattern-first ordering by asserting
		// the correct form matches; the inverted form is covered by
		// `flexibleRejectsInvertedGlobOrder`.
		let pattern = "distil-whisper_distil-large-v3*"
		let concrete = "distil-whisper_distil-large-v3_594MB"
		#expect(ModelPatternMatcher.matchesFlexible(pattern, concrete))
	}

	@Test
	func flexibleRejectsInvertedGlobOrder() {
		// Protects against a regression to the old argument order in callers:
		// with a concrete name as `pattern` and a glob-bearing catalog entry as
		// `text`, neither fnmatch nor size-suffix stripping can recover a match.
		let concrete = "distil-whisper_distil-large-v3_594MB"
		let glob = "distil-whisper_distil-large-v3*"
		#expect(!ModelPatternMatcher.matchesFlexible(concrete, glob))
	}
}
