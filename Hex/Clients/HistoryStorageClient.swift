import Foundation
import ComposableArchitecture
import XCTestDynamicOverlay

/// A client that centralizes persistence of cleared history and deletion of associated audio files.
struct HistoryStorageClient: Sendable {
  /// Persists the cleared history, then deletes all audio files associated with the provided transcripts.
  /// - Parameters:
  ///   - sharedHistory: The shared TranscriptionHistory storage to persist after clearing its contents.
  ///   - transcripts: The transcripts whose audio files should be deleted (if any).
  var persistClearedHistoryAndDeleteFiles: @Sendable (_ sharedHistory: Shared<TranscriptionHistory>, _ transcripts: [Transcript]) async -> Void
}

extension HistoryStorageClient: DependencyKey {
  static var liveValue: HistoryStorageClient {
    Self(
      persistClearedHistoryAndDeleteFiles: { sharedHistory, transcripts in
        // Persist the cleared history first.
        try? await sharedHistory.save()

        // Delete associated audio files on background threads via FileClient.
        @Dependency(\.fileClient) var fileClient
        let urls = transcripts.compactMap(\.audioPath)
        await withTaskGroup(of: Void.self) { group in
          for url in urls {
            group.addTask {
              try? await fileClient.removeItem(url)
            }
          }
          await group.waitForAll()
        }
      }
    )
  }
}

extension HistoryStorageClient: TestDependencyKey {
  static var previewValue: HistoryStorageClient {
    Self(
      persistClearedHistoryAndDeleteFiles: { sharedHistory, _ in
        // Preview: persist only, do not delete files
        try? await sharedHistory.save()
      }
    )
  }

  static var testValue: HistoryStorageClient {
    Self(
      persistClearedHistoryAndDeleteFiles: { _, _ in
        XCTFail("Unimplemented: HistoryStorageClient.persistClearedHistoryAndDeleteFiles")
      }
    )
  }
}

extension DependencyValues {
  var historyStorage: HistoryStorageClient {
    get { self[HistoryStorageClient.self] }
    set { self[HistoryStorageClient.self] = newValue }
  }
}