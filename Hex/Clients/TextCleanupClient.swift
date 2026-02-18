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
  /// Cleans up a voice transcript: fixes punctuation, capitalization, removes filler words.
  var cleanUp: @Sendable (String) async throws -> String

  /// Pre-loads the cleanup model into memory, reporting download/load progress.
  /// Currently a no-op (regex pass needs no model). Will load GECToR in Phase 2.
  var loadModel: @Sendable (@escaping (Progress) -> Void) async throws -> Void

  /// Returns true if the cleanup model is already loaded.
  /// Currently always true (regex pass needs no model). Will reflect GECToR state in Phase 2.
  var isModelLoaded: @Sendable () async -> Bool = { false }
}

extension TextCleanupClient: DependencyKey {
  static var liveValue: Self {
    Self(
      cleanUp: { text in
        let startTime = Date()
        let cleaned = RegexCleanupPass.apply(text)
        let elapsed = Date().timeIntervalSince(startTime)
        cleanupLogger.info("Regex cleanup took \(String(format: "%.2f", elapsed * 1000))ms input_len=\(text.count) output_len=\(cleaned.count)")

        guard !cleaned.isEmpty else {
          throw TextCleanupError.emptyResponse
        }
        return cleaned
      },
      loadModel: { _ in
        // No-op: regex pass needs no model. GECToR loading will go here in Phase 2.
      },
      isModelLoaded: {
        true // Regex pass is always ready. Will check GECToR state in Phase 2.
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
