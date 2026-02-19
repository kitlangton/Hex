//
//  TextCleanupClient.swift
//  Hex
//

import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let cleanupLogger = HexLog.textCleanup

@DependencyClient
struct TextCleanupClient {
  /// Cleans up a voice transcript: regex pass (always) → GECToR grammar correction (if enabled and model loaded).
  var cleanUp: @Sendable (_ text: String, _ grammarCorrection: Bool) async throws -> String

  /// Downloads and loads the GECToR model into memory, reporting progress.
  var loadModel: @Sendable (@escaping (Progress) -> Void) async throws -> Void

  /// Returns true if the GECToR model is loaded and ready for inference.
  var isModelLoaded: @Sendable () async -> Bool = { false }

  /// Returns true if the GECToR model files are downloaded to disk.
  var isModelDownloaded: @Sendable () async -> Bool = { false }

  /// Unloads the GECToR model from memory.
  var unloadModel: @Sendable () async -> Void = {}

  /// Deletes downloaded GECToR model files from disk and unloads from memory.
  var deleteModel: @Sendable () async throws -> Void
}

extension TextCleanupClient: DependencyKey {
  static var liveValue: Self {
    let gector = GECToRInference()

    return Self(
      cleanUp: { text, grammarCorrection in
        // Phase 1: Regex cleanup (always runs, ~0ms)
        let regexStart = Date()
        let regexCleaned = RegexCleanupPass.apply(text)
        let regexElapsed = Date().timeIntervalSince(regexStart)
        cleanupLogger.info("Regex cleanup took \(String(format: "%.2f", regexElapsed * 1000))ms input_len=\(text.count) output_len=\(regexCleaned.count)")

        guard !regexCleaned.isEmpty else {
          throw TextCleanupError.emptyResponse
        }

        // Phase 2: GECToR grammar correction (only if enabled)
        guard grammarCorrection else {
          return regexCleaned
        }

        if await !gector.isLoaded, await gector.isModelDownloaded() {
          cleanupLogger.info("GECToR model files found, auto-loading...")
          do {
            try await gector.loadModel { _ in }
            cleanupLogger.info("GECToR auto-load succeeded")
          } catch {
            cleanupLogger.error("GECToR auto-load failed: \(error.localizedDescription)")
          }
        }

        let isLoaded = await gector.isLoaded
        guard isLoaded else {
          cleanupLogger.info("GECToR not loaded, returning regex-only result")
          return regexCleaned
        }

        do {
          let gectorStart = Date()
          let corrected = try await gector.correct(regexCleaned)
          let gectorElapsed = Date().timeIntervalSince(gectorStart)
          cleanupLogger.info("GECToR correction took \(String(format: "%.2f", gectorElapsed * 1000))ms output_len=\(corrected.count)")

          guard !corrected.isEmpty else {
            cleanupLogger.warning("GECToR returned empty result, falling back to regex")
            return regexCleaned
          }
          return corrected
        } catch {
          cleanupLogger.error("GECToR inference failed: \(error.localizedDescription), falling back to regex")
          return regexCleaned
        }
      },
      loadModel: { progress in
        try await gector.loadModel(progress: progress)
      },
      isModelLoaded: {
        await gector.isLoaded
      },
      isModelDownloaded: {
        await gector.isModelDownloaded()
      },
      unloadModel: {
        await gector.unload()
      },
      deleteModel: {
        try await gector.deleteModel()
      }
    )
  }
}

extension DependencyValues {
  var textCleanup: TextCleanupClient {
    get { self[TextCleanupClient.self] }
    set { self[TextCleanupClient.self] = newValue }
  }
}

// MARK: - Errors

enum TextCleanupError: Error, LocalizedError {
  case modelNotLoaded
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded: return "Text cleanup model is not loaded"
    case .emptyResponse: return "Text cleanup returned empty result"
    }
  }
}
