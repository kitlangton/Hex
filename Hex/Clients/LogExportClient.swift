import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import UniformTypeIdentifiers

@DependencyClient
struct LogExportClient {
  var exportLogs: @Sendable (_ minutes: Int) async throws -> URL?
}

extension LogExportClient: DependencyKey {
  static var liveValue: LogExportClient {
    LogExportClient { minutes in
      try await LogExportClientLive().exportLogs(lastMinutes: minutes)
    }
  }
}

extension DependencyValues {
  var logExporter: LogExportClient {
    get { self[LogExportClient.self] }
    set { self[LogExportClient.self] = newValue }
  }
}

private struct LogExportClientLive {
  func exportLogs(lastMinutes: Int) async throws -> URL? {
    guard let destination = try await presentSavePanel() else {
      return nil
    }

    let logData = try await collectLogs(lastMinutes: lastMinutes)
    try logData.write(to: destination, options: .atomic)
    return destination
  }

  @MainActor
  private func presentSavePanel() throws -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.log, .plainText]
    panel.nameFieldStringValue = defaultFileName()
    panel.canCreateDirectories = true
    panel.title = "Save Hex Diagnostic Logs"
    panel.prompt = "Save"

    let response = panel.runModal()
    guard response == .OK else { return nil }
    guard let url = panel.url else {
      throw LogExportError.noDestination
    }
    return url
  }

  private func defaultFileName() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return "Hex-Logs-\(formatter.string(from: Date())).log"
  }

  private func collectLogs(lastMinutes: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      Task.detached(priority: .userInitiated) {
        do {
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
          process.arguments = [
            "show",
            "--style", "compact",
            "--predicate", "subsystem == \"\(HexLog.subsystem)\"",
            "--last", "\(lastMinutes)m"
          ]

          let stdout = Pipe()
          let stderr = Pipe()
          process.standardOutput = stdout
          process.standardError = stderr

          try process.run()
          let output = stdout.fileHandleForReading.readDataToEndOfFile()
          let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()

          if process.terminationStatus == 0 {
            continuation.resume(returning: output)
          } else {
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            continuation.resume(throwing: LogExportError.commandFailed(message: message))
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

enum LogExportError: LocalizedError {
  case noDestination
  case commandFailed(message: String)

  var errorDescription: String? {
    switch self {
    case .noDestination:
      return "Unable to determine the save location."
    case let .commandFailed(message):
      return "Failed to export logs: \(message)"
    }
  }
}
