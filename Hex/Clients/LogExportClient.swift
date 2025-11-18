import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import OSLog
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
  func exportLogs(lastMinutes minutes: Int) async throws -> URL? {
    guard let destination = try await presentSavePanel() else {
      return nil
    }

    let normalizedMinutes = max(1, minutes)
    let payload = try collectLogs(lastMinutes: normalizedMinutes)
    try payload.write(to: destination, atomically: true, encoding: .utf8)
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

  private func collectLogs(lastMinutes minutes: Int) throws -> String {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let startDate = Date().addingTimeInterval(-Double(minutes) * 60)
    let position = store.position(date: startDate)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    var lines: [String] = []
    for entry in try store.getEntries(at: position) {
      guard let logEntry = entry as? OSLogEntryLog else { continue }
      guard logEntry.subsystem == HexLog.subsystem else { continue }

      let timestamp = formatter.string(from: logEntry.date)
      let level = logEntry.level.displayName
      lines.append("[\(timestamp)] \(level) \(logEntry.category): \(logEntry.composedMessage)")
    }

    if lines.isEmpty {
      lines.append("No Hex log entries captured in the last \(minutes) minute(s).")
    }
    return lines.joined(separator: "\n")
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

private extension OSLogEntryLog.Level {
  var displayName: String {
    switch self {
    case .undefined:
      return "UNDEFINED"
    case .debug:
      return "DEBUG"
    case .info:
      return "INFO"
    case .notice:
      return "NOTICE"
    case .error:
      return "ERROR"
    case .fault:
      return "FAULT"
    @unknown default:
      return "UNKNOWN"
    }
  }
}
