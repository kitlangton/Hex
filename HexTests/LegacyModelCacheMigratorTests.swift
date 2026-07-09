import Foundation
import XCTest

@testable import Hex

final class LegacyModelCacheMigratorTests: XCTestCase {
  func testReplacesIncompleteCurrentDirectoryWithValidLegacyDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let legacy = root.appendingPathComponent("model-coreml")
    let current = root.appendingPathComponent("model")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try Data("complete".utf8).write(to: legacy.appendingPathComponent("model.bin"))
    try Data("partial".utf8).write(to: current.appendingPathComponent("model.bin.partial"))

    let migrated = try LegacyModelCacheMigrator.migrate(from: legacy, to: current) {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.bin").path)
    }

    XCTAssertTrue(migrated)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("model.bin").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("model.bin.partial").path))
  }

  func testRestoresBothDirectoriesWhenLegacyDirectoryIsInvalid() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let legacy = root.appendingPathComponent("model-coreml")
    let current = root.appendingPathComponent("model")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try Data("legacy".utf8).write(to: legacy.appendingPathComponent("legacy.bin"))
    try Data("partial".utf8).write(to: current.appendingPathComponent("partial.bin"))

    XCTAssertThrowsError(
      try LegacyModelCacheMigrator.migrate(from: legacy, to: current) { _ in false }
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("legacy.bin").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("partial.bin").path))
  }
}
