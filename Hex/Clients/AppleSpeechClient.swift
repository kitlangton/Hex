import Foundation
import HexCore

// SpeechAnalyzer requires the macOS 26 SDK, which ships with the Swift 6.2+
// toolchain (Xcode 26). Older toolchains compile the stub at the bottom of
// this file instead — mirroring ParakeetClient's `canImport(FluidAudio)`
// guard — so the app still builds on Xcode 16, just without this engine.
// (`compiler(>=6.2)` checks the toolchain, not the project's language mode,
// and xcodebuild always pairs the toolchain with its bundled SDK.)
#if compiler(>=6.2)
import AVFoundation
import Speech

/// Batch transcription via Apple's on-device SpeechAnalyzer (macOS 26+). (#255)
///
/// Deliberately stateless: locale assets live in the OS-managed AssetInventory
/// and `SpeechTranscriber` construction is cheap, so there is nothing worth
/// caching between calls. That statelessness is also what lets this actor be
/// stored by the non-`@available` `TranscriptionClientLive` — no stored
/// property here has a macOS-26-only type. (If future work ever needs cached
/// 26-only state, box it as `Any?` and re-cast inside `if #available`.)
actor AppleSpeechClient {
  private let logger = HexLog.appleSpeech

  /// Whether the engine can run at all: macOS 26+ on supported hardware,
  /// built with a toolchain that has the Speech SDK.
  func isSupported() -> Bool {
    guard #available(macOS 26.0, *) else { return false }
    return SpeechTranscriber.isAvailable
  }

  /// Whether assets for the locale resolved from `languagePreference`
  /// (Hex's `outputLanguage` setting; nil = Auto) are installed on-device.
  func isModelInstalled(languagePreference: String?) async -> Bool {
    guard #available(macOS 26.0, *) else { return false }
    return await AppleSpeechEngine.isInstalled(languagePreference: languagePreference)
  }

  /// Downloads and installs the locale assets if missing, reporting native
  /// download progress. Safe to call repeatedly.
  func ensureModel(languagePreference: String?, progress: @escaping (Progress) -> Void) async throws {
    guard #available(macOS 26.0, *) else { throw AppleSpeechError.requiresMacOS26 }
    try await AppleSpeechEngine.ensureAssets(languagePreference: languagePreference, progress: progress)
  }

  /// Transcribes the recorded audio file, installing locale assets first if
  /// needed (slower first run after a language switch, but never a dead end).
  func transcribe(url: URL, languagePreference: String?, progress: @escaping (Progress) -> Void) async throws -> String {
    guard #available(macOS 26.0, *) else { throw AppleSpeechError.requiresMacOS26 }
    return try await AppleSpeechEngine.transcribe(url: url, languagePreference: languagePreference, progress: progress)
  }
}

/// All Speech-SDK calls live here so the surrounding actor needs no
/// availability annotation.
@available(macOS 26.0, *)
private enum AppleSpeechEngine {
  private static let logger = HexLog.appleSpeech

  private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [], // no volatile results — batch semantics, finalized text only
      attributeOptions: []
    )
  }

  private static func resolveLocale(_ preference: String?) async throws -> Locale {
    let supported = await SpeechTranscriber.supportedLocales
    guard !supported.isEmpty else { throw AppleSpeechError.engineUnavailable }
    guard let locale = SpeechLocaleResolution.resolve(preference: preference, supported: supported) else {
      throw AppleSpeechError.unsupportedLanguage(preference ?? "auto")
    }
    return locale
  }

  static func isInstalled(languagePreference: String?) async -> Bool {
    guard SpeechTranscriber.isAvailable else { return false }
    guard let locale = try? await resolveLocale(languagePreference) else { return false }
    let target = locale.identifier(.bcp47)
    let installed = await SpeechTranscriber.installedLocales
    return installed.contains { $0.identifier(.bcp47) == target }
  }

  static func ensureAssets(languagePreference: String?, progress: @escaping (Progress) -> Void) async throws {
    guard SpeechTranscriber.isAvailable else { throw AppleSpeechError.engineUnavailable }
    let locale = try await resolveLocale(languagePreference)
    try await ensureAssets(for: makeTranscriber(locale: locale), locale: locale, progress: progress)
  }

  /// Installs assets for `locale` if missing and keeps it reserved. Safe to
  /// call repeatedly; returns immediately when everything is installed.
  private static func ensureAssets(
    for transcriber: SpeechTranscriber,
    locale: Locale,
    progress: @escaping (Progress) -> Void
  ) async throws {
    let target = locale.identifier(.bcp47)
    let installed = await SpeechTranscriber.installedLocales
    if !installed.contains(where: { $0.identifier(.bcp47) == target }) {
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        logger.notice("Downloading Apple Speech assets for locale=\(target)")
        let nativeProgress = request.progress
        let pollTask = Task {
          while !Task.isCancelled {
            progress(nativeProgress)
            try? await Task.sleep(nanoseconds: 250_000_000)
          }
        }
        defer { pollTask.cancel() }
        try await withTaskCancellationHandler {
          try await request.downloadAndInstall()
        } onCancel: {
          // The user's Cancel button cancels our task; forward it to the OS download.
          nativeProgress.cancel()
        }
        progress(nativeProgress)
        logger.notice("Apple Speech assets installed for locale=\(target)")
      }
    }

    // The system caps how many locales an app may keep reserved
    // (AssetInventory.maximumReservedLocales). Hex only ever needs the active
    // one, so release stale reservations before reserving — otherwise a few
    // language switches could exhaust the quota. Reservation failure is
    // non-fatal: already-installed assets keep working.
    let reserved = await AssetInventory.reservedLocales
    if !reserved.contains(where: { $0.identifier(.bcp47) == target }) {
      for staleLocale in reserved {
        await AssetInventory.release(reservedLocale: staleLocale)
      }
      do {
        try await AssetInventory.reserve(locale: locale)
      } catch {
        logger.error("Could not reserve locale \(target): \(error.localizedDescription)")
      }
    }
  }

  static func transcribe(
    url: URL,
    languagePreference: String?,
    progress: @escaping (Progress) -> Void
  ) async throws -> String {
    guard SpeechTranscriber.isAvailable else { throw AppleSpeechError.engineUnavailable }
    let locale = try await resolveLocale(languagePreference)
    let transcriber = makeTranscriber(locale: locale)
    // Self-heal if assets are missing (e.g. evicted by the OS, or the user
    // switched language and dictated before downloading the new pack).
    try await ensureAssets(for: transcriber, locale: locale, progress: progress)

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    // Drain results concurrently so nothing is dropped while audio is fed in.
    let resultsTask = Task<String, Error> {
      var transcript = AttributedString("")
      for try await result in transcriber.results {
        transcript += result.text
      }
      return String(transcript.characters)
    }
    // Every failure path must run this so no analyzer outlives the request —
    // including TCA effect cancellation (ESC), which surfaces as a thrown
    // CancellationError at the next await.
    func tearDown() async {
      resultsTask.cancel()
      await analyzer.cancelAndFinishNow()
    }

    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: url)
    } catch {
      await tearDown()
      throw error
    }
    let audioDuration = Double(audioFile.length) / max(audioFile.processingFormat.sampleRate, 1)

    let t0 = Date()
    logger.notice("Transcribing with Apple Speech locale=\(locale.identifier(.bcp47)) file=\(url.lastPathComponent)")
    do {
      guard let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) else {
        await tearDown()
        throw AppleSpeechError.noAudioSamples
      }
      try await analyzer.finalizeAndFinish(through: lastSampleTime)
    } catch {
      await tearDown()
      throw error
    }

    do {
      let text = try await awaiting(resultsTask, timeout: max(30, audioDuration + 30))
      logger.info("Apple Speech transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      await tearDown()
      throw error
    }
  }

  /// Awaits `task` but gives up after `timeout` seconds. The cancellation
  /// handler is load-bearing: cancelling a task-group child does not cancel
  /// the unstructured task it is awaiting, so it must be cancelled explicitly
  /// or the results stream could leak past the request.
  private static func awaiting(_ task: Task<String, Error>, timeout: TimeInterval) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        try await withTaskCancellationHandler {
          try await task.value
        } onCancel: {
          task.cancel()
        }
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw AppleSpeechError.resultStreamTimedOut
      }
      guard let first = try await group.next() else {
        throw AppleSpeechError.resultStreamTimedOut
      }
      group.cancelAll()
      return first
    }
  }
}

enum AppleSpeechError: Error, LocalizedError {
  case requiresMacOS26
  case engineUnavailable
  case unsupportedLanguage(String)
  case noAudioSamples
  case resultStreamTimedOut

  var errorDescription: String? {
    switch self {
    case .requiresMacOS26:
      return "Apple Speech requires macOS 26 or later. Choose a different model in Settings → Transcription Model."
    case .engineUnavailable:
      return "Apple Speech is not available on this Mac. Choose a different model in Settings → Transcription Model."
    case let .unsupportedLanguage(code):
      return "Apple Speech does not support the selected output language (\(code)). Pick another language or model in Settings."
    case .noAudioSamples:
      return "No audio reached the Apple Speech engine."
    case .resultStreamTimedOut:
      return "Apple Speech did not finish returning results. Please try again."
    }
  }
}

#else

/// Stub for toolchains without the macOS 26 SDK (Xcode < 26). The engine
/// reports itself unsupported, so the Apple Speech row never appears.
actor AppleSpeechClient {
  func isSupported() -> Bool { false }
  func isModelInstalled(languagePreference: String?) async -> Bool { false }
  func ensureModel(languagePreference: String?, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "AppleSpeech",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Hex was built without SpeechAnalyzer support (requires Xcode 26)."]
    )
  }
  func transcribe(url: URL, languagePreference: String?, progress: @escaping (Progress) -> Void) async throws -> String {
    throw NSError(
      domain: "AppleSpeech",
      code: -3,
      userInfo: [NSLocalizedDescriptionKey: "Apple Speech is not available in this build."]
    )
  }
}

#endif
