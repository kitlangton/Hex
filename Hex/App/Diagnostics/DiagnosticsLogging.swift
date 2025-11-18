import Foundation
import Logging

enum DiagnosticsLogging {
  private static var destination: FileLogDestination?
  private static var isBootstrapped = false

  static var logDirectory: URL {
    let support = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return support?
      .appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
      .appendingPathComponent("Logs", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())
  }

  static var logFileURL: URL {
    logDirectory.appendingPathComponent("hex-diagnostics.log")
  }

  static func bootstrapIfNeeded() {
    guard !isBootstrapped else { return }
    do {
      try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    } catch {
      NSLog("Failed to create log directory: \(error)")
    }
    let destination = FileLogDestination(url: logFileURL)
    self.destination = destination
    LoggingSystem.bootstrap { label in
      var handlers: [LogHandler] = [FileLogHandler(label: label, destination: destination)]
      handlers.append(StreamLogHandler.standardError(label: label))
      return MultiplexLogHandler(handlers)
    }
    let bootstrapLogger = Logger(label: "com.kitlangton.Hex.Diagnostics")
    bootstrapLogger.notice("Swift diagnostics logging initialized", metadata: ["file": .string(logFileURL.path)])
    isBootstrapped = true
  }
}

private final class FileLogDestination {
  private let url: URL
  private let queue = DispatchQueue(label: "com.kitlangton.Hex.Diagnostics.FileLogger")
  private var handle: FileHandle?
  private let maxSize: UInt64 = 2 * 1024 * 1024 // 2 MB

  init(url: URL) {
    self.url = url
    prepareHandle()
  }

  func write(_ text: String) {
    queue.async { [weak self] in
      guard let self else { return }
      if let data = text.data(using: .utf8) {
        self.handle?.seekToEndOfFile()
        self.handle?.write(data)
        self.truncateIfNeeded()
      }
    }
  }

  private func prepareHandle() {
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
  }

  private func truncateIfNeeded() {
    guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
          size > maxSize,
          let handle
    else { return }
    let truncateSize = size / 2
    if let data = try? Data(contentsOf: url).suffix(Int(truncateSize)) {
      try? data.write(to: url, options: .atomic)
      try? handle.close()
      self.handle = try? FileHandle(forWritingTo: url)
    }
  }
}

private struct FileLogHandler: LogHandler {
  let label: String
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .info
  private let destination: FileLogDestination

  init(label: String, destination: FileLogDestination) {
    self.label = label
    self.destination = destination
  }

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
    var composed = "[\(timestamp())] \(level.rawValue.uppercased()) \(label): \(message)"
    let combined = metadata?.merging(self.metadata, uniquingKeysWith: { $1 }) ?? self.metadata
    if !combined.isEmpty {
      composed.append(" \(combined)")
    }
    destination.write(composed + "\n")
  }

  private func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }
}

private struct MultiplexLogHandler: LogHandler {
  var logLevel: Logger.Level {
    get { handlers.map(\.logLevel).min() ?? .trace }
    set { handlers.indices.forEach { handlers[$0].logLevel = newValue } }
  }

  var metadata: Logger.Metadata {
    get { handlers.first?.metadata ?? [:] }
    set { handlers.indices.forEach { handlers[$0].metadata = newValue } }
  }

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { handlers.first?[metadataKey: key] }
    set { handlers.indices.forEach { handlers[$0][metadataKey: key] = newValue } }
  }

  private var handlers: [LogHandler]

  init(_ handlers: [LogHandler]) {
    self.handlers = handlers
  }

  func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
    handlers.forEach { $0.log(level: level, message: message, metadata: metadata, source: source, file: file, function: function, line: line) }
  }
}
