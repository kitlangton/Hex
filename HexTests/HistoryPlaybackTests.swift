import ComposableArchitecture
import Foundation
import Testing

@testable import Hex

@Suite(.serialized)
@MainActor
struct HistoryPlaybackTests {
  @Test
  func stoppingPlaybackCompletesWaitersExactlyOnce() async {
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

  @Test
  func stalePlaybackFinishedDoesNotStopCurrentPlayback() async {
    let transcriptID = UUID()
    let playbackID = UUID()
    let store = TestStore(
      initialState: HistoryFeature.State(
        transcriptionHistory: Shared(.init()),
        playingTranscriptID: transcriptID,
        playbackID: playbackID
      )
    ) {
      HistoryFeature()
    }

    await store.send(.playbackFinished(UUID()))

    #expect(store.state.playingTranscriptID == transcriptID)
    #expect(store.state.playbackID == playbackID)
  }
}
