import Foundation

enum LegacyModelCacheMigrator {
  static func migrate(
    from legacyDirectory: URL,
    to currentDirectory: URL,
    fileManager: FileManager = .default,
    isValid: (URL) -> Bool
  ) throws -> Bool {
    guard legacyDirectory.standardizedFileURL != currentDirectory.standardizedFileURL,
          fileManager.fileExists(atPath: legacyDirectory.path),
          !isValid(currentDirectory)
    else { return false }

    let backupDirectory = currentDirectory
      .deletingLastPathComponent()
      .appendingPathComponent(".\(currentDirectory.lastPathComponent)-migration-\(UUID().uuidString)")
    let hadCurrentDirectory = fileManager.fileExists(atPath: currentDirectory.path)

    if hadCurrentDirectory {
      try fileManager.moveItem(at: currentDirectory, to: backupDirectory)
    }

    do {
      try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
      guard isValid(currentDirectory) else {
        throw MigrationError.invalidLegacyModel
      }
      if hadCurrentDirectory {
        try? fileManager.removeItem(at: backupDirectory)
      }
      return true
    } catch {
      if fileManager.fileExists(atPath: currentDirectory.path),
         !fileManager.fileExists(atPath: legacyDirectory.path)
      {
        try? fileManager.moveItem(at: currentDirectory, to: legacyDirectory)
      }
      if hadCurrentDirectory, fileManager.fileExists(atPath: backupDirectory.path) {
        try? fileManager.moveItem(at: backupDirectory, to: currentDirectory)
      }
      throw error
    }
  }

  enum MigrationError: Error {
    case invalidLegacyModel
  }
}
