import XCTest
@testable import HexCore

final class SpeechActivityTests: XCTestCase {
  func testAnalyzeDetectsSilence() {
    let silent = [Float](repeating: 0, count: 16_000)
    let metrics = SpeechActivityMetrics.analyze(samples: silent)
    XCTAssertFalse(SpeechActivityGate.hasSpeechActivity(metrics))
  }

  func testAnalyzeDetectsSpeechLikeSignal() {
    let speechLike = (0 ..< 16_000).map { index in
      Float(sin(Double(index) / 40.0) * 0.08)
    }
    let metrics = SpeechActivityMetrics.analyze(samples: speechLike)
    XCTAssertTrue(SpeechActivityGate.hasSpeechActivity(metrics))
  }

  func testSilentTranscriptionFilterRejectsCommonHallucinations() {
    XCTAssertTrue(SilentTranscriptionFilter.isLikelyHallucination("Thank you."))
    XCTAssertTrue(SilentTranscriptionFilter.isLikelyHallucination("okay"))
    XCTAssertFalse(SilentTranscriptionFilter.isLikelyHallucination("The settings section seems fine"))
  }

  func testShouldAcceptTranscriptionWithoutSpeechActivity() {
    let metrics = SpeechActivityMetrics.zero
    XCTAssertFalse(
      SilentTranscriptionFilter.shouldAcceptTranscription(text: "Thank you.", metrics: metrics)
    )
    XCTAssertFalse(
      SilentTranscriptionFilter.shouldAcceptTranscription(text: "okay", metrics: metrics)
    )
  }

  func testShouldAcceptTranscriptionWithSpeechActivity() {
    let metrics = SpeechActivityMetrics(peakRMS: 0.05, peakSample: 0.12)
    XCTAssertTrue(
      SilentTranscriptionFilter.shouldAcceptTranscription(text: "Thank you.", metrics: metrics)
    )
  }
}
