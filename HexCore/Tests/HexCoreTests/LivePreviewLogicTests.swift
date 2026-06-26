import XCTest
@testable import HexCore

final class LivePreviewLogicTests: XCTestCase {
  func testKeystrokeUpdateActionAppendsSuffix() {
    let action = LiveTextInsertionLogic.keystrokeUpdateAction(previous: "hello", new: "hello world")
    XCTAssertEqual(action, .append(" world"))
  }

  func testKeystrokeUpdateActionShrinksWhenPreviewShortens() {
    let action = LiveTextInsertionLogic.keystrokeUpdateAction(previous: "hello world", new: "hello")
    XCTAssertEqual(action, .shrinkBackspaces(6))
  }

  func testKeystrokeUpdateActionReplacesTailOnRevision() {
    let action = LiveTextInsertionLogic.keystrokeUpdateAction(previous: "hello word", new: "hello world")
    XCTAssertEqual(action, .replaceTail(backspaces: 1, insert: "ld"))
  }

  func testKeystrokeUpdateActionPrefersFullReplace() {
    let action = LiveTextInsertionLogic.keystrokeUpdateAction(
      previous: "hello",
      new: "hello world",
      preferFullReplace: true
    )
    XCTAssertEqual(action, .replaceTail(backspaces: 5, insert: "hello world"))
  }

  func testLivePreviewUpdateGateRequiresMinimumInitialLength() {
    var gate = LivePreviewUpdateGate()
    XCTAssertFalse(gate.shouldApply(next: "Te"))
    XCTAssertTrue(gate.shouldApply(next: "Testing live"))
  }

  func testLivePreviewUpdateGateAllowsModerateGrowthFromSmallBase() {
    var gate = LivePreviewUpdateGate()
    gate.markApplied("Testing live preview")
    XCTAssertTrue(
      gate.shouldApply(
        next: "Testing live preview with more words added here."
      )
    )
  }

  func testLivePreviewUpdateGateRecoversFromShortPoisonedPreview() {
    var gate = LivePreviewUpdateGate()
    gate.markApplied("Te")
    XCTAssertTrue(
      gate.shouldApply(
        next: "Testing life transcription, testing the life inscription."
      )
    )
  }

  func testLivePreviewUpdateGateAllowsSmallShrinkRevision() {
    var gate = LivePreviewUpdateGate()
    gate.markApplied("Testing the live transcription")
    XCTAssertTrue(gate.shouldApply(next: "Testing the live transcriptio"))
  }

  func testLivePreviewUpdateGateRequiresDoubleShrinkForLargeTrim() {
    var gate = LivePreviewUpdateGate()
    XCTAssertTrue(gate.shouldApply(next: "hello world again"))
    gate.markApplied("hello world again")
    XCTAssertFalse(gate.shouldApply(next: "hello"))
    XCTAssertTrue(gate.shouldApply(next: "hello"))
  }

  func testLivePreviewUpdateGateRejectsUnrelatedGrowth() {
    var gate = LivePreviewUpdateGate()
    gate.markApplied("The setting seems fine")
    XCTAssertFalse(
      gate.shouldApply(next: "Random words completely different here")
    )
    XCTAssertTrue(gate.shouldApply(next: "The setting seems fine now"))
  }

  func testLivePreviewUpdateGateAcceptsPrefixExtension() {
    var gate = LivePreviewUpdateGate()
    gate.markApplied("hello world")
    XCTAssertTrue(gate.shouldApply(next: "hello world again"))
  }

  func testLivePreviewUpdateGateAcceptsMateriallyLongerRefresh() {
    var gate = LivePreviewUpdateGate()
    gate.markApplied("Testing the live transcription. Seems to be working okay. Seems to be cutting off the last word.")
    XCTAssertTrue(
      gate.shouldApply(
        next: "Testing the live transcription. Seems to be working okay. Seems to be cutting off the last word. Sometimes getting stuck."
      )
    )
  }

  func testLivePreviewTranscriptionSchedulerThrottles() {
    var scheduler = LivePreviewTranscriptionScheduler()
    XCTAssertFalse(scheduler.shouldScheduleTranscribe(snapshotDuration: 0.3, hasInFlightTranscribe: false))
    XCTAssertTrue(scheduler.shouldScheduleTranscribe(snapshotDuration: 0.5, hasInFlightTranscribe: false))
    scheduler.markTranscribed(duration: 0.5)
    XCTAssertFalse(scheduler.shouldScheduleTranscribe(snapshotDuration: 0.65, hasInFlightTranscribe: false))
    XCTAssertTrue(scheduler.shouldScheduleTranscribe(snapshotDuration: 0.95, hasInFlightTranscribe: false))
  }

  func testLivePreviewTranscriptionSchedulerSlowsOnLongRecordings() {
    var scheduler = LivePreviewTranscriptionScheduler()
    scheduler.markTranscribed(duration: 5.0)
    XCTAssertFalse(scheduler.shouldScheduleTranscribe(snapshotDuration: 5.4, hasInFlightTranscribe: false))
    XCTAssertTrue(scheduler.shouldScheduleTranscribe(snapshotDuration: 5.85, hasInFlightTranscribe: false))

    scheduler.markTranscribed(duration: 14.0)
    XCTAssertFalse(scheduler.shouldScheduleTranscribe(snapshotDuration: 14.5, hasInFlightTranscribe: false))
    XCTAssertTrue(scheduler.shouldScheduleTranscribe(snapshotDuration: 14.8, hasInFlightTranscribe: false))
  }
}
