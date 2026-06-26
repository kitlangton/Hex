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
      Float(sin(Double(index) / 40.0) * 0.12)
    }
    let metrics = SpeechActivityMetrics.analyze(samples: speechLike)
    XCTAssertTrue(SpeechActivityGate.hasSpeechActivity(metrics))
    XCTAssertTrue(SpeechActivityGate.hasStrongSpeechActivity(metrics))
  }

  func testPeakSampleAloneDoesNotCountAsSpeech() {
    let metrics = SpeechActivityMetrics(peakRMS: 0.005, peakSample: 0.08)
    XCTAssertFalse(SpeechActivityGate.hasSpeechActivity(metrics))
    XCTAssertFalse(SpeechActivityGate.hasWhisperActivity(metrics))
  }

  func testStrongSpeechRequiresBothRMSAndPeak() {
    let peakOnly = SpeechActivityMetrics(peakRMS: 0.010, peakSample: 0.12)
    XCTAssertFalse(SpeechActivityGate.hasStrongSpeechActivity(peakOnly))
  }

  func testSilentTranscriptionFilterRejectsCommonHallucinations() {
    XCTAssertTrue(SilentTranscriptionFilter.isLikelyHallucination("Thank you."))
    XCTAssertTrue(SilentTranscriptionFilter.isLikelyHallucination("okay"))
    XCTAssertFalse(SilentTranscriptionFilter.isLikelyHallucination("The settings section seems fine"))
  }

  func testShouldRejectHallucinationOnWeakSpeechMetrics() {
    let weakMetrics = SpeechActivityMetrics(peakRMS: 0.024, peakSample: 0.065)
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

  func testEvaluatePreviewActivityRejectsConstantBackgroundNoise() {
    let noise = (0 ..< 16_000).map { index in
      Float(sin(Double(index) / 17.0) * 0.025)
    }
    let evaluation = SpeechActivityGate.evaluatePreviewActivity(samples: noise)
    XCTAssertFalse(evaluation.hasActivity)
  }

  func testEvaluatePreviewActivityAcceptsWhisperLevelSpeech() {
    let metrics = SpeechActivityMetrics(peakRMS: 0.010, peakSample: 0.074)
    XCTAssertTrue(SpeechActivityGate.hasWhisperActivity(metrics))

    let whisper = (0 ..< 12_000).map { index in
      Float(sin(Double(index) / 45.0) * 0.08)
    }
    let evaluation = SpeechActivityGate.evaluatePreviewActivity(samples: whisper)
    XCTAssertTrue(evaluation.hasActivity)
  }

  func testEvaluatePreviewActivityAcceptsHoldWindowDuringPause() {
    let speech = (0 ..< 8_000).map { index in
      Float(sin(Double(index) / 35.0) * 0.10)
    }
    let pause = [Float](repeating: 0.0005, count: 8_000)
    let samples = speech + pause
    let evaluation = SpeechActivityGate.evaluatePreviewActivity(samples: samples)
    XCTAssertTrue(evaluation.hasActivity)
  }
}
