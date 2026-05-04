import AppKit
import ComposableArchitecture
import Foundation
import Testing

@testable import Hex

@Suite(.serialized)
@MainActor
struct RecordingRaceTests {
  @Test
  func newRecordingCancelsPendingDiscardCleanup() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let activeApp = NSWorkspace.shared.frontmostApplication
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("discard-cleanup-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    #expect(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = RecordingProbe(stopURL: stopURL)
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {
        await probe.recordStart()
      }
      $0.recording.stopRecording = {
        await probe.beginStop()
      }
      $0.sleepManagement.preventSleep = { _ in }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isStartingRecording = true
      $0.recordingStartTime = nil
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.receive(.recordingStarted) {
      $0.isStartingRecording = false
      $0.isRecording = true
      $0.recordingStartTime = now
    }
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }

    await probe.waitForPendingStop()

    await store.send(.startRecording) {
      $0.isStartingRecording = true
      $0.recordingStartTime = nil
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.receive(.recordingStarted) {
      $0.isStartingRecording = false
      $0.isRecording = true
      $0.recordingStartTime = now
    }

    await probe.resumePendingStop()
    await store.finish()

    let counts = await probe.counts()
    #expect(counts.startCalls == 2)
    #expect(counts.stopCalls == 1)
    #expect(FileManager.default.fileExists(atPath: stopURL.path))
  }

  @Test
  func newRecordingCancelsPendingDiscardCleanup_onStartFailure() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let activeApp = NSWorkspace.shared.frontmostApplication
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("discard-cleanup-failure-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    #expect(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = RecordingProbe(stopURL: stopURL, startResults: [true, false])
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {
        await probe.recordStart()
      }
      $0.recording.stopRecording = {
        await probe.beginStop()
      }
      $0.sleepManagement.preventSleep = { _ in }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isStartingRecording = true
      $0.recordingStartTime = nil
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.receive(.recordingStarted) {
      $0.isStartingRecording = false
      $0.isRecording = true
      $0.recordingStartTime = now
    }
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }

    await probe.waitForPendingStop()

    await store.send(.startRecording) {
      $0.isStartingRecording = true
      $0.recordingStartTime = nil
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.receive(.recordingStartFailed) {
      $0.isStartingRecording = false
      $0.shouldStopWhenRecordingStarts = false
      $0.isRecording = false
      $0.recordingStartTime = nil
    }

    await probe.resumePendingStop()
    await store.finish()

    let counts = await probe.counts()
    #expect(counts.startCalls == 2)
    #expect(counts.stopCalls == 1)
    #expect(FileManager.default.fileExists(atPath: stopURL.path))
  }

  @Test
  func stopGuardIgnoresOnlyStaleSessions() {
    let currentSessionID = UUID()

    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: currentSessionID
      ) == false
    )
    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: nil,
        currentSessionID: currentSessionID
      ) == false
    )
    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: UUID()
      )
    )
  }

  private static func makeState() -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      hexSettings: Shared(.init()),
      isRemappingScratchpadFocused: Shared(false),
      modelBootstrapState: Shared(.init(isModelReady: true)),
      transcriptionHistory: Shared(.init())
    )
  }
}

private actor RecordingProbe {
  private let stopURL: URL
  private var startResults: [Bool]
  private var startCalls = 0
  private var stopCalls = 0
  private var stopContinuation: CheckedContinuation<URL, Never>?

  init(stopURL: URL, startResults: [Bool] = [true]) {
    self.stopURL = stopURL
    self.startResults = startResults
  }

  func recordStart() -> Bool {
    startCalls += 1
    return startResults.isEmpty ? true : startResults.removeFirst()
  }

  func beginStop() async -> URL {
    stopCalls += 1
    return await withCheckedContinuation { continuation in
      stopContinuation = continuation
    }
  }

  func waitForPendingStop() async {
    while stopContinuation == nil {
      await Task.yield()
    }
  }

  func resumePendingStop() {
    stopContinuation?.resume(returning: stopURL)
    stopContinuation = nil
  }

  func counts() -> (startCalls: Int, stopCalls: Int) {
    (startCalls, stopCalls)
  }
}
