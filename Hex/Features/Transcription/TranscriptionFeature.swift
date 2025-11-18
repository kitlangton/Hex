//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPostProcessing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.textTransformations) var textTransformations: TextTransformationsState
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL)
    case transcriptionError(Error, URL?)
    case postProcessingComplete
  }

  enum CancelID {
    case metering
    case transcription
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .postProcessingComplete:
        state.isPostProcessing = false
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing || state.isPostProcessing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        hotKeyProcessor.useDoubleTapOnly = hexSettings.useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          // Process the key event
          switch hotKeyProcessor.process(keyEvent: keyEvent) {
          case .startRecording:
            // If double-tap lock is triggered, we start recording immediately
            if hotKeyProcessor.state == .doubleTapLock {
              Task { await send(.startRecording) }
            } else {
              Task { await send(.hotKeyPressed) }
            }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return hexSettings.useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        do {
          try await Task.sleep(nanoseconds: .max)
        } catch {
          // Cancellation expected
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none
    let startRecording = Effect.send(Action.startRecording)
    return .merge(maybeCancel, startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .run { _ in
        soundEffect.play(.cancel)
      }
    }
    state.isRecording = true
    let startTime = Date()
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime, privacy: .public)")

    // Prevent system sleep during recording
    return .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
      // Play sound immediately for instant feedback
      soundEffect.play(.startRecording)

      if preventSleep {
        await sleepManagement.preventSleep(reason: "Hex Voice Recording")
      }
      await recording.startRecording()
    }
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(duration, format: .fixed(precision: 3))s start=\(startStamp, privacy: .public) stop=\(stopStamp, privacy: .public) decision=\(String(describing: decision), privacy: .public) minimumKeyTime=\(minimumKeyTime, format: .fixed(precision: 2)) hotkeyHasKey=\(hotkeyHasKey, privacy: .public)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision), privacy: .public)")
      return .run { _ in
        let url = await recording.stopRecording()
        try? FileManager.default.removeItem(at: url)
      }
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .run { [sleepManagement] send in
      // Allow system to sleep again
      await sleepManagement.allowSleep()

      var audioURL: URL?
      do {
        soundEffect.play(.stopRecording)
        let capturedURL = await recording.stopRecording()
        audioURL = capturedURL

        // Create transcription options with the selected language
        // Note: cap concurrency to avoid audio I/O overloads on some Macs
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad,
        )
        
        let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
        
        transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent, privacy: .public) to text length \(result.count, privacy: .public)")
        await send(.transcriptionResult(result, capturedURL))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .none
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    // Debug logging
    transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .public)'")
    let bundleID = state.sourceAppBundleID
    let stacks = state.textTransformations.stacks
    transcriptionFeatureLogger.info("Source app bundle ID: \(bundleID ?? "nil")")
    transcriptionFeatureLogger.info("Available stacks: \(stacks.map { "\($0.name) (apps: \($0.appliesToBundleIdentifiers))" })")

    // Stack selection with precedence:
    // 1. Voice prefix + bundle ID match (highest)
    // 2. Voice prefix alone
    // 3. Bundle ID alone
    // 4. General fallback
    var selectedStack: TransformationStack?
    var processedResult = result
    
    let allPrefixes = stacks.flatMap { stack in stack.voicePrefixes.map { "\(stack.name):\($0)" } }.joined(separator: ", ")
    transcriptionFeatureLogger.info("Checking voice prefixes: \(allPrefixes)")
    if let prefixMatch = state.textTransformations.stackByVoicePrefix(text: result) {
      processedResult = prefixMatch.strippedText
      
      // Check if prefix-matched stack also matches bundle ID (highest priority)
      let prefixStack = prefixMatch.stack
      if let bundleID = bundleID,
         !prefixStack.appliesToBundleIdentifiers.isEmpty,
         prefixStack.appliesToBundleIdentifiers.contains(where: { $0.lowercased() == bundleID.lowercased() }) {
        selectedStack = prefixStack
        transcriptionFeatureLogger.info("✓ Voice prefix + bundle ID matched: '\(prefixStack.name)' (prefix: '\(prefixMatch.matchedPrefix)', bundle: \(bundleID))")
      } else {
        selectedStack = prefixMatch.stack
        transcriptionFeatureLogger.info("✓ Voice prefix matched: '\(prefixMatch.stack.name)' (prefix: '\(prefixMatch.matchedPrefix)')")
      }
      transcriptionFeatureLogger.info("  Stripped text: '\(String(processedResult.prefix(50)))...'")
    } else {
      selectedStack = state.textTransformations.stack(for: bundleID)
      if let selectedStack {
        transcriptionFeatureLogger.info("✓ Bundle ID matched: '\(selectedStack.name)' (apps: \(selectedStack.appliesToBundleIdentifiers))")
      } else {
        transcriptionFeatureLogger.warning("No stack selected, using empty pipeline")
      }
    }

    let pipeline = selectedStack?.pipeline ?? state.textTransformations.pipeline(for: bundleID)
    let providers = state.textTransformations.providers
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
    let textToProcess = processedResult  // Capture immutable copy for concurrency

    // Check if we have any LLM transformations that will trigger post-processing
    let hasLLMTransformations = pipeline.transformations.contains { transformation in
      if case .llm = transformation.type {
        return transformation.isEnabled
      }
      return false
    }

    if hasLLMTransformations {
      state.isPostProcessing = true
    }

    return .run { send in
      do {
        transcriptionFeatureLogger.info("Processing with \(pipeline.transformations.count) transformations, \(providers.count) providers")
        let executor = TextTransformationPipeline.Executor { config, input in
          transcriptionFeatureLogger.info("Running LLM transformation with provider: \(config.providerID)")
          return try await runClaudeCode(config: config, input: input, providers: providers)
        }
        let transformed = await pipeline.process(textToProcess, executor: executor)
        transcriptionFeatureLogger.info("Transformed text from \(textToProcess.count) to \(transformed.count) chars")
        await send(.postProcessingComplete)
        try await finalizeRecordingAndStoreTranscript(
          result: transformed,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.postProcessingComplete)
        await send(.transcriptionError(error, audioURL))
      }
    }
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }

    return .none
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let fm = FileManager.default
      let supportDir = try fm.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let ourAppFolder = supportDir.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
      let recordingsFolder = ourAppFolder.appendingPathComponent("Recordings", isDirectory: true)
      try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)

      let filename = "\(Date().timeIntervalSince1970).wav"
      let finalURL = recordingsFolder.appendingPathComponent(filename)
      try fm.moveItem(at: audioURL, to: finalURL)

      let transcript = Transcript(
        timestamp: Date(),
        text: result,
        audioPath: finalURL,
        duration: duration,
        sourceAppBundleID: sourceAppBundleID,
        sourceAppName: sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              try? FileManager.default.removeItem(at: removedTranscript.audioPath)
            }
          }
        }
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }

    await pasteboard.paste(result)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPostProcessing = false
    state.isPrewarming = false

    return .merge(
      .cancel(id: CancelID.transcription),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        try? FileManager.default.removeItem(at: url)
        soundEffect.play(.cancel)
      }
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .run { [sleepManagement] _ in
      // Allow system to sleep again
      await sleepManagement.allowSleep()
      let url = await recording.stopRecording()
      try? FileManager.default.removeItem(at: url)
    }
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isPostProcessing {
      return .postProcessing
    } else if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - LLM Execution

private func runClaudeCode(
  config: LLMTransformationConfig,
  input: String,
  providers: [LLMProvider]
) async throws -> String {
  transcriptionFeatureLogger.info("runClaudeCode called with \(providers.count) providers, looking for: \(config.providerID)")

  guard let provider = providers.first(where: { $0.id == config.providerID }) else {
    transcriptionFeatureLogger.error("Provider not found: \(config.providerID)")
    throw LLMExecutionError.providerNotFound(config.providerID)
  }

  guard provider.type == .claudeCode else {
    throw LLMExecutionError.unsupportedProvider(provider.type.rawValue)
  }

  guard let binaryPath = provider.binaryPath else {
    throw LLMExecutionError.invalidConfiguration("Provider has no binary path")
  }

  let userPrompt = config.promptTemplate.replacingOccurrences(of: "{{input}}", with: input)
  let wrappedPrompt = """
\(userPrompt)

IMPORTANT: Output ONLY the final result. Do not include any preamble like "Here is the cleaned text:" or "I'll clean up this transcription". Just output the transformed text directly.
"""
  
  transcriptionFeatureLogger.info("Found provider: \(provider.id), binary: \(binaryPath)")
  transcriptionFeatureLogger.debug("Sending prompt to LLM (first 200 chars): \(String(wrappedPrompt.prefix(200)), privacy: .public)")

  let process = Process()
  process.executableURL = URL(fileURLWithPath: binaryPath)
  var arguments = ["-p", "--output-format", "json"]
  if let model = provider.defaultModel {
    arguments.append(contentsOf: ["--model", model])
  }
  process.arguments = arguments

  if let workingDir = provider.workingDirectory {
    process.currentDirectoryURL = URL(fileURLWithPath: (workingDir as NSString).expandingTildeInPath)
  }

  var environment = ProcessInfo.processInfo.environment
  environment["CLAUDE_CODE_SKIP_UPDATE_CHECK"] = "1"
  environment["PATH"] = buildExecutableSearchPath(existingPATH: environment["PATH"])
  process.environment = environment

  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  let stdinPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe
  process.standardInput = stdinPipe

  try process.run()

  if let data = wrappedPrompt.appending("\n").data(using: .utf8) {
    stdinPipe.fileHandleForWriting.write(data)
  }
  stdinPipe.fileHandleForWriting.closeFile()

  let timeout = TimeInterval(provider.timeoutSeconds ?? 20)
  let deadline = Date().addingTimeInterval(timeout)

  while process.isRunning && Date() < deadline {
    try await Task.sleep(for: .milliseconds(100))
  }

  if process.isRunning {
    transcriptionFeatureLogger.error("Claude CLI timed out after \(timeout)s")
    process.terminate()
    throw LLMExecutionError.timeout
  }

  process.waitUntilExit()

  let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

  guard process.terminationStatus == 0 else {
    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
    throw LLMExecutionError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  guard !stdoutData.isEmpty else {
    throw LLMExecutionError.invalidOutput
  }

  if let parsed = try? decodeClaudeOutput(from: stdoutData) {
    transcriptionFeatureLogger.info("Claude returned \(parsed.count) chars (parsed JSON)")
    return parsed
  }

  guard let fallback = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty else {
    throw LLMExecutionError.invalidOutput
  }

  transcriptionFeatureLogger.info("Claude returned \(fallback.count) chars (raw text)")
  return fallback
}

private func buildExecutableSearchPath(existingPATH: String?) -> String {
  let existingEntries = existingPATH?
    .split(separator: ":")
    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    ?? []

  let fallbackEntries = defaultExecutableDirectories()
  let merged = dedupePaths(fallbackEntries + existingEntries)
  return merged.joined(separator: ":")
}



private func defaultExecutableDirectories() -> [String] {
  let fm = FileManager.default
  let home = fm.homeDirectoryForCurrentUser.path
  var candidates: [String] = []

  candidates.append(contentsOf: nvmExecutableDirectories(homeDirectory: home))

  let staticPaths = [
    "~/.claude/local/node_modules/.bin",
    "~/.local/bin",
    "~/.local/share/pnpm",
    "~/.config/yarn/global/node_modules/.bin",
    "~/.volta/bin",
    "~/.asdf/shims",
    "~/.asdf/bin",
    "~/.cargo/bin",
    "~/.deno/bin",
    "~/.pnpm-global/5/node_modules/.bin",
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin"
  ]

  candidates.append(contentsOf: staticPaths.map { ($0 as NSString).expandingTildeInPath })

  return candidates.filter { path in
    var isDirectory: ObjCBool = false
    return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }
}

private func nvmExecutableDirectories(homeDirectory: String) -> [String] {
  let fm = FileManager.default
  let nvmDir = (homeDirectory as NSString).appendingPathComponent(".nvm")
  let versionsDir = (nvmDir as NSString).appendingPathComponent("versions/node")
  var isDirectory: ObjCBool = false
  guard fm.fileExists(atPath: versionsDir, isDirectory: &isDirectory), isDirectory.boolValue else {
    return []
  }

  var directories: [String] = []

  let aliasPath = (nvmDir as NSString).appendingPathComponent("alias/default")
  if let aliasContents = try? String(contentsOfFile: aliasPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines),
     !aliasContents.isEmpty
  {
    let defaultDir = (versionsDir as NSString).appendingPathComponent("\(aliasContents)/bin")
    directories.append(defaultDir)
  }

  let currentDir = (versionsDir as NSString).appendingPathComponent("current/bin")
  directories.append(currentDir)

  if let versionFolders = try? fm.contentsOfDirectory(atPath: versionsDir) {
    for version in versionFolders.sorted(by: >) {
      guard !version.hasPrefix(".") else { continue }
      let versionDir = (versionsDir as NSString).appendingPathComponent("\(version)/bin")
      directories.append(versionDir)
    }
  }

  return directories
}

private func dedupePaths(_ paths: [String]) -> [String] {
  var seen = Set<String>()
  var ordered: [String] = []
  for path in paths {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }
    let normalized = (trimmed as NSString).standardizingPath
    if seen.insert(normalized).inserted {
      ordered.append(normalized)
    }
  }
  return ordered
}

private func decodeClaudeOutput(from data: Data) throws -> String {
  let decoder = JSONDecoder()
  if let envelope = try? decoder.decode(ClaudeCLIEnvelope.self, from: data) {
    // New format: top-level "result" field
    if let result = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
      return result
    }
    // Old format: "message" or "content" with nested content array
    if let message = envelope.message ?? envelope.contentMessage {
      let text = message.content.compactMap { $0.text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return text
      }
    }
  } else {
    // CLI sometimes emits multiple JSON objects separated by newlines; try the last one.
    if let lastLine = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
       let lineData = lastLine.data(using: .utf8),
       let envelope = try? decoder.decode(ClaudeCLIEnvelope.self, from: lineData) {
      if let result = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
        return result
      }
      if let message = envelope.message ?? envelope.contentMessage {
        let text = message.content.compactMap { $0.text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          return text
        }
      }
    }
  }
  throw LLMExecutionError.invalidOutput
}

private struct ClaudeCLIEnvelope: Decodable {
  struct Message: Decodable {
    struct Content: Decodable {
      let type: String
      let text: String?
    }
    let content: [Content]
  }

  let type: String?
  let result: String?
  let message: Message?
  let contentMessage: Message?

  enum CodingKeys: String, CodingKey {
    case type
    case result
    case message
    case content
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type)
    result = try container.decodeIfPresent(String.self, forKey: .result)
    message = try container.decodeIfPresent(Message.self, forKey: .message)
    contentMessage = try container.decodeIfPresent(Message.self, forKey: .content)
  }
}

enum LLMExecutionError: Error, LocalizedError {
  case providerNotFound(String)
  case invalidConfiguration(String)
  case unsupportedProvider(String)
  case timeout
  case processFailed(String)
  case invalidOutput

  var errorDescription: String? {
    switch self {
    case .providerNotFound(let id):
      return "LLM provider not found: \(id)"
    case .invalidConfiguration(let message):
      return "LLM provider configuration error: \(message)"
    case .unsupportedProvider(let type):
      return "LLM provider type \(type) is not supported yet"
    case .timeout:
      return "LLM execution timed out"
    case .processFailed(let message):
      return "LLM process failed: \(message)"
    case .invalidOutput:
      return "LLM returned invalid output"
    }
  }
}
