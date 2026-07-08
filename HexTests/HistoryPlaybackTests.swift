import ComposableArchitecture
import Foundation
import XCTest

@testable import Hex

@MainActor
final class HistoryPlaybackTests: XCTestCase {
  func testStoppingPlaybackCompletesWaitersExactlyOnce() async {
    let controller = AudioPlayerController()
    let waiter = Task {
      await controller.waitForPlaybackToFinish()
    }

    await Task.yield()
    controller.stop()
    controller.stop()

    await waiter.value
    await controller.waitForPlaybackToFinish()
  }

  func testStalePlaybackFinishedDoesNotStopCurrentPlayback() async {
    let transcriptID = UUID()
    let playbackID = UUID()
    let store = TestStore(
      initialState: HistoryFeature.State(
        transcriptionHistory: Shared(value: .init()),
        playingTranscriptID: transcriptID,
        playbackID: playbackID
      )
    ) {
      HistoryFeature()
    }

    await store.send(.playbackFinished(UUID()))

    XCTAssertEqual(store.state.playingTranscriptID, transcriptID)
    XCTAssertEqual(store.state.playbackID, playbackID)
  }
}
