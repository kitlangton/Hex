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
    XCTAssertTrue(SpeechActivityGate.hasStrongSpeechActivity(metrics))
  }

  func testPeakSampleAloneDoesNotCountAsSpeech() {
    let metrics = SpeechActivityMetrics(peakRMS: 0.005, peakSample: 0.08)
    XCTAssertFalse(SpeechActivityGate.hasSpeechActivity(metrics))
  }

  func testSilentTranscriptionFilterRejectsCommonHallucinations() {
    XCTAssertTrue(SilentTranscriptionFilter.isLikelyHallucination("Thank you."))
    XCTAssertTrue(SilentTranscriptionFilter.isLikelyHallucination("okay"))
    XCTAssertFalse(SilentTranscriptionFilter.isLikelyHallucination("The settings section seems fine"))
  }

  func testShouldRejectHallucinationOnWeakSpeechMetrics() {
    let weakMetrics = SpeechActivityMetrics(peakRMS: 0.020, peakSample: 0.06)
    XCTAssertTrue(SpeechActivityGate.hasSpeechActivity(weakMetrics))
    XCTAssertFalse(SpeechActivityGate.hasStrongSpeechActivity(weakMetrics))
    XCTAssertFalse(
      SilentTranscriptionFilter.shouldAcceptTranscription(text: "Thank you.", metrics: weakMetrics)
    )
    XCTAssertFalse(
      SilentTranscriptionFilter.shouldAcceptTranscription(text: "hello", metrics: weakMetrics)
    )
  }

  func testShouldAcceptTranscriptionWithStrongSpeechActivity() {
    let metrics = SpeechActivityMetrics(peakRMS: 0.05, peakSample: 0.12)
    XCTAssertTrue(
      SilentTranscriptionFilter.shouldAcceptTranscription(text: "Thank you.", metrics: metrics)
    )
    XCTAssertTrue(
      SilentTranscriptionFilter.shouldAcceptTranscription(
        text: "The settings section seems fine",
        metrics: metrics
      )
    )
  }
}
