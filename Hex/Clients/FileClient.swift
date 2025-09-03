import Foundation
import ComposableArchitecture
import XCTestDynamicOverlay

/// A client that performs file system operations on background-priority threads
/// to avoid blocking the main actor/UI.
struct FileClient: Sendable {
  /// Returns whether a file or directory exists at the given path.
  /// Executed on a background-priority detached task.
  var existsAtPath: @Sendable (_ path: String) async -> Bool

  /// Removes the item at the given URL if it exists.
  /// Executed on a background-priority detached task.
  var removeItem: @Sendable (_ url: URL) async throws -> Void
}

extension FileClient {
  /// Live implementation backed by FileManager, performed on background-priority tasks.
  static let live = Self(
    existsAtPath: { path in
      await Task.detached(priority: .background) {
        FileManager.default.fileExists(atPath: path)
      }.value
    },
    removeItem: { url in
      try await Task.detached(priority: .background) {
        try FileManager.default.removeItem(at: url)
      }.value
    }
  )
}

extension FileClient: DependencyKey {
  static var liveValue: FileClient { .live }
}

extension FileClient: TestDependencyKey {
  /// The preview implementation does nothing and reports no files present.
  static var previewValue: FileClient {
    Self(
      existsAtPath: { _ in false },
      removeItem: { _ in }
    )
  }

  /// The test implementation is unimplemented by default; override in tests as needed.
  static var testValue: FileClient {
    Self(
      existsAtPath: { _ in
        XCTFail("Unimplemented: FileClient.existsAtPath")
        return false
      },
      removeItem: { _ in
        XCTFail("Unimplemented: FileClient.removeItem")
      }
    )
  }
}

extension DependencyValues {
  var fileClient: FileClient {
    get { self[FileClient.self] }
    set { self[FileClient.self] = newValue }
  }
}