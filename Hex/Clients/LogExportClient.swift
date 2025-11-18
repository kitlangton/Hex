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
  func exportLogs(lastMinutes _: Int) async throws -> URL? {
    guard let destination = try await presentSavePanel() else {
      return nil
    }

    let fileURL = DiagnosticsLogging.logFileURL
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    let data = try Data(contentsOf: fileURL)
    try data.write(to: destination, options: .atomic)
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

}

enum LogExportError: LocalizedError {
  case noDestination

  var errorDescription: String? {
    switch self {
    case .noDestination:
      return "Unable to determine the save location."
  }
  }
}
