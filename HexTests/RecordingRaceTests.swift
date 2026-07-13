import AppKit
import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

@MainActor
final class RecordingRaceTests: XCTestCase {
  func testNewRecordingCancelsPendingDiscardCleanup() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let activeApp = NSWorkspace.shared.frontmostApplication
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("discard-cleanup-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
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
    XCTAssertEqual(counts.startCalls, 2)
    XCTAssertEqual(counts.stopCalls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopURL.path))
  }

  func testStopGuardIgnoresOnlyStaleSessions() {
    let currentSessionID = UUID()

    XCTAssertFalse(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: currentSessionID
      )
    )
    XCTAssertFalse(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: nil,
        currentSessionID: currentSessionID
      )
    )
    XCTAssertTrue(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: UUID()
      )
    )
  }

  func testCaptureControllerIgnoresCallbacksFromOlderGeneration() {
    XCTAssertTrue(
      SuperFastCaptureController.shouldProcessCallback(
        callbackGeneration: 2,
        currentGeneration: 2
      )
    )
    XCTAssertFalse(
      SuperFastCaptureController.shouldProcessCallback(
        callbackGeneration: 1,
        currentGeneration: 2
      )
    )
  }

  func testFailedRecordingStopEndsTranscription() async {
    let now = Date(timeIntervalSince1970: 1_234)
    var state = Self.makeState()
    state.isRecording = true
    state.recordingStartTime = now
    state.$hexSettings.withLock { settings in
      settings.hotkey = HotKey(key: .a, modifiers: [.command])
    }
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.stopRecording = { .failed(.fallbackExportFailed("copy failed")) }
      $0.sleepManagement.allowSleep = {}
    }

    await store.send(.stopRecording) {
      $0.isRecording = false
      $0.isTranscribing = true
      $0.error = nil
      $0.isPrewarming = true
    }
    await store.receive(\.transcriptionError) {
      $0.isTranscribing = false
      $0.isPrewarming = false
      $0.error = "Failed to export recorded audio: copy failed"
    }
  }

  func testShortRecordingReleasesSleepAssertion() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("short-recording-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = SleepProbe()
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {}
      $0.recording.stopRecording = { .captured(stopURL) }
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
    XCTAssertEqual(counts.preventSleepCalls, 1)
    XCTAssertEqual(counts.allowSleepCalls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopURL.path))
  }

  func testDiscardCancelsPendingRecordingStart() async {
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
    XCTAssertEqual(counts.startCalls, 0)
    XCTAssertEqual(counts.stopCalls, 1)
  }

  func testEmptyTranscriptionDeletesCapturedAudio() async throws {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("empty-transcription-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: audioURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    }

    await store.send(.transcriptionAudioCaptured(audioURL, 1.25)) {
      $0.activeTranscriptionAudioURL = audioURL
      $0.activeTranscriptionDuration = 1.25
    }
    await store.send(.transcriptionResult("", audioURL)) {
      $0.activeTranscriptionAudioURL = nil
      $0.activeTranscriptionDuration = nil
    }
    await store.finish()

    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testHistoryUsesRecordingDurationCapturedAtStop() async {
    let duration = 1.25
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("history-duration-\(UUID().uuidString).wav")
    let transcript = Transcript(
      timestamp: Date(timeIntervalSince1970: 1_234),
      text: "hello",
      audioPath: audioURL,
      duration: duration,
      sourceAppBundleID: nil,
      sourceAppName: nil,
      status: .completed
    )
    let probe = TranscriptPersistenceProbe()
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcriptPersistence.save = { text, audioURL, duration, sourceAppBundleID, sourceAppName, status in
        await probe.record(duration: duration)
        return Transcript(
          id: transcript.id,
          timestamp: transcript.timestamp,
          text: text,
          audioPath: audioURL,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          status: status
        )
      }
      $0.pasteboard.paste = { _ in }
      $0.soundEffects.play = { _ in }
    }

    await store.send(.transcriptionAudioCaptured(audioURL, duration)) {
      $0.activeTranscriptionAudioURL = audioURL
      $0.activeTranscriptionDuration = duration
    }
    await store.send(.transcriptionResult("hello", audioURL)) {
      $0.activeTranscriptionAudioURL = nil
      $0.activeTranscriptionDuration = nil
      $0.isTranscribing = false
      $0.isPrewarming = false
    }
    while await probe.duration == nil {
      await Task.yield()
    }
    store.assert {
      $0.$transcriptionHistory.withLock { $0.history = [transcript] }
    }
    await store.finish()

    let storedDuration = await probe.duration
    XCTAssertEqual(storedDuration, duration)
  }

  func testTranscriptTextProcessorAppliesFormattingAfterWordTransforms() {
    var settings = HexSettings()
    settings.lowercaseTranscripts = true
    settings.removePunctuation = true

    XCTAssertEqual(
      TranscriptTextProcessor.process("Hello, World!", settings: settings, bypassFilters: false),
      "hello world"
    )
  }

  func testTranscriptTextProcessorBypassesEveryTransformForScratchpadPreview() {
    var settings = HexSettings()
    settings.lowercaseTranscripts = true
    settings.removePunctuation = true

    XCTAssertEqual(
      TranscriptTextProcessor.process("Hello, World!", settings: settings, bypassFilters: true),
      "Hello, World!"
    )
  }

	func testRefinementReceivesProcessedTranscriptAndKeepsAudioOwnedUntilItCompletes() async throws {
		let now = Date(timeIntervalSince1970: 1_234)
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let probe = RefinementProbe()
		var state = Self.makeState()
		state.isTranscribing = true
		state.isPrewarming = true
		state.$hexSettings.withLock {
			$0.refinementMode = .refined
			$0.lowercaseTranscripts = true
			$0.removePunctuation = true
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
			$0.date.now = now
			$0.refinement.refine = { request in
				await probe.recordInput(request.text)
				return "refined text"
			}
			$0.pasteboard.paste = { text in await probe.recordPaste(text) }
			$0.soundEffects.play = { _ in }
		}

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("Hello, World!", audioURL)) {
			$0.isTranscribing = false
			$0.isPrewarming = false
			$0.isRefining = true
		}
		await store.receive(.refinementResult("refined text", audioURL, 2)) {
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
			$0.isRefining = false
		}
		await store.finish()

		let refinementInput = await probe.input
		let pastedText = await probe.paste
		XCTAssertEqual(refinementInput, "hello world")
		XCTAssertEqual(pastedText, "refined text")
		XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
	}

	func testRefinementFailureFallsBackToProcessedTranscript() async throws {
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-fallback-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let probe = RefinementProbe()
		var state = Self.makeState()
		state.isTranscribing = true
		state.$hexSettings.withLock {
			$0.refinementMode = .refined
			$0.lowercaseTranscripts = true
			$0.removePunctuation = true
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
			$0.refinement.refine = { _ in throw RefinementTestError.failed }
			$0.pasteboard.paste = { text in await probe.recordPaste(text) }
			$0.soundEffects.play = { _ in }
		}

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("Hello, World!", audioURL)) {
			$0.isTranscribing = false
			$0.isRefining = true
		}
		await store.receive(.refinementResult("hello world", audioURL, 2)) {
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
			$0.isRefining = false
		}
		await store.finish()

		let pastedText = await probe.paste
		XCTAssertEqual(pastedText, "hello world")
		XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
	}

	func testCancellingRefinementOwnsAudioAndIgnoresLateResult() async throws {
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-cancel-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let refinementProbe = PendingRefinementProbe()
		let pasteProbe = RefinementProbe()
		var state = Self.makeState()
		state.isTranscribing = true
		state.$hexSettings.withLock {
			$0.refinementMode = .refined
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
			$0.refinement.refine = { _ in try await refinementProbe.refine() }
			$0.pasteboard.paste = { text in await pasteProbe.recordPaste(text) }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
		}

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("keep this", audioURL)) {
			$0.isTranscribing = false
			$0.isRefining = true
		}
		await refinementProbe.waitUntilPending()

		await store.send(.cancel) {
			$0.isRefining = false
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
		}
		await refinementProbe.resume("late result")
		await store.finish()

		let pastedText = await pasteProbe.paste
		XCTAssertNil(pastedText)
		XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
	}

	func testRefinedHotkeyWithSelectedTextStartsRecording() async throws {
		let now = Date(timeIntervalSince1970: 1_234)
		let activeApp = NSWorkspace.shared.frontmostApplication
		let recordingProbe = RecordingProbe(
			stopURL: FileManager.default.temporaryDirectory.appendingPathComponent("selected-text-hotkey-\(UUID().uuidString).wav")
		)
		let selectedText = SelectedTextCapture(
			text: "draft message",
			replaceSelection: { _ in .replaced },
			cancelSelection: {}
		)
		let store = TestStore(initialState: Self.makeState()) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = now
			$0.pasteboard.captureSelectedText = { selectedText }
			$0.recording.startRecording = {
				await recordingProbe.recordStart()
			}
			$0.sleepManagement.preventSleep = { _ in }
		}

		await store.send(.refinedHotKeyPressed) {
			$0.isCapturingSelectedTextForRefinement = true
		}
		await store.receive(.selectedTextCaptured(selectedText)) {
			$0.isCapturingSelectedTextForRefinement = false
			$0.selectedTextForRefinement = selectedText
		}
		await store.receive(.startRefinedRecording) {
			$0.isRecording = true
			$0.forcedRefinementMode = .refined
			$0.activeRecordingHotkey = $0.hexSettings.refinedHotkey
			$0.activeMinimumKeyTime = $0.hexSettings.refinedMinimumKeyTime
			$0.activeRecordingSource = .refined
			$0.recordingStartTime = now
			$0.sourceAppBundleID = activeApp?.bundleIdentifier
			$0.sourceAppName = activeApp?.localizedName
		}
		await store.finish()

		let recordingCounts = await recordingProbe.counts()
		XCTAssertEqual(recordingCounts.startCalls, 1)
	}

	func testSelectedTextRefinementUsesSpokenInstruction() async throws {
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("selected-text-refinement-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let refinementProbe = RefinementProbe()
		let selectedText = SelectedTextCapture(
			text: "draft message",
			replaceSelection: { text in
				await refinementProbe.recordPaste(text)
				return .replaced
			},
			cancelSelection: {}
		)
		var state = Self.makeState()
		state.isTranscribing = true
		state.forcedRefinementMode = .refined
		state.selectedTextForRefinement = selectedText
		state.$hexSettings.withLock {
			$0.refinementInstructions = "Preserve Markdown."
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.refinement.refine = { request in
				await refinementProbe.recordInput(request.text)
				await refinementProbe.recordInstructions(request.instructions)
				return "shorter draft"
			}
			$0.soundEffects.play = { _ in }
		}

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("make it shorter", audioURL)) {
			$0.isTranscribing = false
			$0.isRefining = true
		}
		await store.receive(.refinementResult("shorter draft", audioURL, 2)) {
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
			$0.isRefining = false
			$0.selectedTextForRefinement = nil
			$0.forcedRefinementMode = nil
			$0.activeRecordingHotkey = nil
			$0.activeMinimumKeyTime = nil
			$0.activeRecordingSource = nil
		}
		await store.finish()

		XCTAssertEqual(await refinementProbe.input, "draft message")
		XCTAssertEqual(await refinementProbe.instructions, "Preserve Markdown.\n\nSpoken instruction:\nmake it shorter")
		XCTAssertEqual(await refinementProbe.paste, "shorter draft")
	}

	func testSilentSelectedTextRefinementUsesDefaultInstructions() async throws {
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("silent-selected-text-refinement-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let refinementProbe = RefinementProbe()
		let selectedText = SelectedTextCapture(
			text: "draft message",
			replaceSelection: { text in
				await refinementProbe.recordPaste(text)
				return .replaced
			},
			cancelSelection: {}
		)
		var state = Self.makeState()
		state.isTranscribing = true
		state.forcedRefinementMode = .refined
		state.selectedTextForRefinement = selectedText
		state.$hexSettings.withLock {
			$0.refinementInstructions = "Preserve Markdown."
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.refinement.refine = { request in
				await refinementProbe.recordInput(request.text)
				await refinementProbe.recordInstructions(request.instructions)
				return "refined draft"
			}
			$0.soundEffects.play = { _ in }
		}

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("", audioURL)) {
			$0.isTranscribing = false
			$0.isRefining = true
		}
		await store.receive(.refinementResult("refined draft", audioURL, 2)) {
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
			$0.isRefining = false
			$0.selectedTextForRefinement = nil
			$0.forcedRefinementMode = nil
			$0.activeRecordingHotkey = nil
			$0.activeMinimumKeyTime = nil
			$0.activeRecordingSource = nil
		}
		await store.finish()

		XCTAssertEqual(await refinementProbe.input, "draft message")
		XCTAssertEqual(await refinementProbe.instructions, "Preserve Markdown.")
		XCTAssertEqual(await refinementProbe.paste, "refined draft")
	}

	func testRefinedHotkeyReleaseDuringSelectionCaptureDoesNotStartRecording() async {
		let captureProbe = PendingSelectedTextCaptureProbe()
		let store = TestStore(initialState: Self.makeState()) {
			TranscriptionFeature()
		} withDependencies: {
			$0.pasteboard.captureSelectedText = { await captureProbe.capture() }
		}

		await store.send(.refinedHotKeyPressed) {
			$0.isCapturingSelectedTextForRefinement = true
		}
		await captureProbe.waitUntilPending()
		await store.send(.hotKeyReleased(.refined)) {
			$0.refinedHotKeyReleasedWhileCapturingSelection = true
		}
		await captureProbe.resume(nil)
		await store.receive(.selectedTextCaptureUnavailable) {
			$0.isCapturingSelectedTextForRefinement = false
			$0.refinedHotKeyReleasedWhileCapturingSelection = false
		}
		await store.finish()
	}

	func testRefinedHotkeyWithoutSelectionStartsRefinedRecording() async {
		let now = Date(timeIntervalSince1970: 1_234)
		let activeApp = NSWorkspace.shared.frontmostApplication
		let recordingProbe = RecordingProbe(
			stopURL: FileManager.default.temporaryDirectory.appendingPathComponent("no-selection-hotkey-\(UUID().uuidString).wav")
		)
		let store = TestStore(initialState: Self.makeState()) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = now
			$0.pasteboard.captureSelectedText = { nil }
			$0.recording.startRecording = { await recordingProbe.recordStart() }
			$0.sleepManagement.preventSleep = { _ in }
		}

		await store.send(.refinedHotKeyPressed) {
			$0.isCapturingSelectedTextForRefinement = true
		}
		await store.receive(.selectedTextCaptureUnavailable) {
			$0.isCapturingSelectedTextForRefinement = false
		}
		await store.receive(.startRefinedRecording) {
			$0.isRecording = true
			$0.forcedRefinementMode = .refined
			$0.activeRecordingHotkey = $0.hexSettings.refinedHotkey
			$0.activeMinimumKeyTime = $0.hexSettings.refinedMinimumKeyTime
			$0.activeRecordingSource = .refined
			$0.recordingStartTime = now
			$0.sourceAppBundleID = activeApp?.bundleIdentifier
			$0.sourceAppName = activeApp?.localizedName
		}
		await store.finish()

		let recordingCounts = await recordingProbe.counts()
		XCTAssertEqual(recordingCounts.startCalls, 1)
	}

  private static func makeState() -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      hexSettings: Shared(value: .init()),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: .init())
    )
  }
}

private actor RefinementProbe {
	private(set) var input: String?
	private(set) var instructions: String?
	private(set) var paste: String?

	func recordInput(_ value: String) { input = value }
	func recordInstructions(_ value: String) { instructions = value }
	func recordPaste(_ value: String) { paste = value }
}

private actor PendingSelectedTextCaptureProbe {
	private var continuation: CheckedContinuation<SelectedTextCapture?, Never>?

	func capture() async -> SelectedTextCapture? {
		await withCheckedContinuation { continuation in
			self.continuation = continuation
		}
	}

	func waitUntilPending() async {
		while continuation == nil {
			await Task.yield()
		}
	}

	func resume(_ selectedText: SelectedTextCapture?) {
		continuation?.resume(returning: selectedText)
		continuation = nil
	}
}

private enum RefinementTestError: Error {
	case failed
}

private actor PendingRefinementProbe {
	private var continuation: CheckedContinuation<String, Error>?

	func refine() async throws -> String {
		try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
		}
	}

	func waitUntilPending() async {
		while continuation == nil {
			await Task.yield()
		}
	}

	func resume(_ text: String) {
		continuation?.resume(returning: text)
		continuation = nil
	}
}

private actor RecordingProbe {
  private let stopURL: URL
  private var startCalls = 0
  private var stopCalls = 0
  private var stopContinuation: CheckedContinuation<RecordingStopResult, Never>?

  init(stopURL: URL) {
    self.stopURL = stopURL
  }

  func recordStart() {
    startCalls += 1
  }

  func beginStop() async -> RecordingStopResult {
    stopCalls += 1
    return await withCheckedContinuation { continuation in
      stopContinuation = continuation
    }
  }

  func beginImmediateStop() -> RecordingStopResult {
    stopCalls += 1
    return .captured(stopURL)
  }

  func waitForPendingStop() async {
    while stopContinuation == nil {
      await Task.yield()
    }
  }

  func resumePendingStop() {
    stopContinuation?.resume(returning: .captured(stopURL))
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
