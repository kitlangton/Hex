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
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }

    await probe.waitForPendingStop()

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
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

  @Test
  func shortRecordingReleasesSleepAssertion() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("short-recording-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    #expect(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = SleepProbe()
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {}
      $0.recording.stopRecording = { stopURL }
      $0.sleepManagement.preventSleep = { _ in
        await probe.recordPreventSleep()
      }
      $0.sleepManagement.allowSleep = {
        await probe.recordAllowSleep()
      }
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      $0.sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    }
    await store.send(.stopRecording) {
      $0.isRecording = false
    }
    await store.finish()

    let counts = await probe.counts()
    #expect(counts.preventSleepCalls == 1)
    #expect(counts.allowSleepCalls == 1)
    #expect(!FileManager.default.fileExists(atPath: stopURL.path))
  }

  @Test
  func discardCancelsPendingRecordingStart() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-start-discard-\(UUID().uuidString).wav")
    let sleepProbe = PendingSleepProbe()
    let recordingProbe = RecordingProbe(stopURL: stopURL)
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {
        await recordingProbe.recordStart()
      }
      $0.recording.stopRecording = {
        await recordingProbe.beginImmediateStop()
      }
      $0.sleepManagement.preventSleep = { _ in
        await sleepProbe.preventSleep()
      }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      $0.sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    }
    await sleepProbe.waitUntilPending()
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }
    await sleepProbe.resume()
    await store.finish()

    let counts = await recordingProbe.counts()
    #expect(counts.startCalls == 0)
    #expect(counts.stopCalls == 1)
  }

  @Test
  func emptyTranscriptionDeletesCapturedAudio() async throws {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("empty-transcription-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: audioURL.path,
      contents: Data("test".utf8)
    )
    #expect(created)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    }

    await store.send(.transcriptionResult("", audioURL, 1.25, .zero))
    await store.finish()

    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
  }

  @Test
  func historyUsesRecordingDurationCapturedAtStop() async {
    let duration = 1.25
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("history-duration-\(UUID().uuidString).wav")
    let probe = TranscriptPersistenceProbe()
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcriptPersistence.save = { text, audioURL, duration, sourceAppBundleID, sourceAppName in
        await probe.record(duration: duration)
        return Transcript(
          timestamp: Date(timeIntervalSince1970: 1_234),
          text: text,
          audioPath: audioURL,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName
        )
      }
      $0.pasteboard.paste = { _ in }
      $0.soundEffects.play = { _ in }
    }

    await store.send(
      .transcriptionResult(
        "hello",
        audioURL,
        duration,
        SpeechActivityMetrics(peakRMS: 0.05, peakSample: 0.12)
      )
    )
    await store.finish()

    let storedDuration = await probe.duration
    #expect(storedDuration == duration)
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
  private var startCalls = 0
  private var stopCalls = 0
  private var stopContinuation: CheckedContinuation<URL, Never>?

  init(stopURL: URL) {
    self.stopURL = stopURL
  }

  func recordStart() {
    startCalls += 1
  }

  func beginStop() async -> URL {
    stopCalls += 1
    return await withCheckedContinuation { continuation in
      stopContinuation = continuation
    }
  }

  func beginImmediateStop() -> URL {
    stopCalls += 1
    return stopURL
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

private actor SleepProbe {
  private var preventSleepCalls = 0
  private var allowSleepCalls = 0

  func recordPreventSleep() {
    preventSleepCalls += 1
  }

  func recordAllowSleep() {
    allowSleepCalls += 1
  }

  func counts() -> (preventSleepCalls: Int, allowSleepCalls: Int) {
    (preventSleepCalls, allowSleepCalls)
  }
}

private actor PendingSleepProbe {
  private var continuation: CheckedContinuation<Void, Never>?

  func preventSleep() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilPending() async {
    while continuation == nil {
      await Task.yield()
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private actor TranscriptPersistenceProbe {
  private(set) var duration: TimeInterval?

  func record(duration: TimeInterval) {
    self.duration = duration
  }
}
