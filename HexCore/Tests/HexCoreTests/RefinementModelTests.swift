import XCTest
@testable import HexCore

final class RefinementModelTests: XCTestCase {

	// MARK: - RefinementMode

	func testRefinementModeCodableRoundTrip() throws {
		for mode in RefinementMode.allCases {
			let data = try JSONEncoder().encode(mode)
			let decoded = try JSONDecoder().decode(RefinementMode.self, from: data)
			XCTAssertEqual(decoded, mode)
		}
	}

	func testRefinementModeRawValues() {
		XCTAssertEqual(RefinementMode.raw.rawValue, "raw")
		XCTAssertEqual(RefinementMode.refined.rawValue, "refined")
		XCTAssertEqual(RefinementMode.summarized.rawValue, "summarized")
	}

	func testRefinementModeAllCasesCount() {
		XCTAssertEqual(RefinementMode.allCases.count, 3)
	}

	// MARK: - RefinementProvider

	func testRefinementProviderCodableRoundTrip() throws {
		for provider in RefinementProvider.allCases {
			let data = try JSONEncoder().encode(provider)
			let decoded = try JSONDecoder().decode(RefinementProvider.self, from: data)
			XCTAssertEqual(decoded, provider)
		}
	}

	func testRefinementProviderRawValues() {
		XCTAssertEqual(RefinementProvider.apple.rawValue, "apple")
		XCTAssertEqual(RefinementProvider.gemini.rawValue, "gemini")
	}

	// MARK: - RefinementTone

	func testRefinementToneCodableRoundTrip() throws {
		for tone in RefinementTone.allCases {
			let data = try JSONEncoder().encode(tone)
			let decoded = try JSONDecoder().decode(RefinementTone.self, from: data)
			XCTAssertEqual(decoded, tone)
		}
	}

	func testRefinementToneRawValues() {
		XCTAssertEqual(RefinementTone.natural.rawValue, "natural")
		XCTAssertEqual(RefinementTone.professional.rawValue, "professional")
		XCTAssertEqual(RefinementTone.casual.rawValue, "casual")
		XCTAssertEqual(RefinementTone.concise.rawValue, "concise")
		XCTAssertEqual(RefinementTone.friendly.rawValue, "friendly")
	}

	func testRefinementToneAllCasesCount() {
		XCTAssertEqual(RefinementTone.allCases.count, 5)
	}

	func testSummarizedValidTones() {
		let validForSummary: [RefinementTone] = [.natural, .professional, .concise]
		let invalidForSummary: [RefinementTone] = [.casual, .friendly]

		for tone in validForSummary {
			XCTAssertTrue(RefinementTone.allCases.contains(tone), "\(tone) should exist")
		}
		for tone in invalidForSummary {
			XCTAssertFalse(validForSummary.contains(tone), "\(tone) should not be in summary tones")
		}
	}
}
