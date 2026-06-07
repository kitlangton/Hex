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

  func testLivePreviewUpdateGateRequiresDoubleShrink() {
    var gate = LivePreviewUpdateGate()
    XCTAssertTrue(gate.shouldApply(next: "hello"))
    gate.markApplied("hello")
    XCTAssertFalse(gate.shouldApply(next: "hell"))
    XCTAssertTrue(gate.shouldApply(next: "hell"))
  }

  func testLivePreviewUpdateGateRejectsUnrelatedGrowth() {
    var gate = LivePreviewUpdateGate()
    gate.markApplied("The setting seems fine")
    XCTAssertFalse(gate.shouldApply(next: "Random words completely different"))
    XCTAssertTrue(gate.shouldApply(next: "The setting seems fine now"))
  }

  func testLivePreviewTranscriptionSchedulerThrottles() {
    var scheduler = LivePreviewTranscriptionScheduler()
    XCTAssertFalse(scheduler.shouldScheduleTranscribe(snapshotDuration: 0.3, hasInFlightTranscribe: false))
    XCTAssertTrue(scheduler.shouldScheduleTranscribe(snapshotDuration: 0.5, hasInFlightTranscribe: false))
    scheduler.markTranscribed(duration: 0.5)
    XCTAssertFalse(scheduler.shouldScheduleTranscribe(snapshotDuration: 0.65, hasInFlightTranscribe: false))
    XCTAssertTrue(scheduler.shouldScheduleTranscribe(snapshotDuration: 0.75, hasInFlightTranscribe: false))
  }
}
