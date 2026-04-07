import AVFoundation
import Foundation
import HexCore

@main
struct HexCLI {
  private static let models: [(name: String, id: String, language: String, size: String)] = [
    ("Parakeet TDT v3", "parakeet-tdt-0.6b-v3-coreml", "Multilingual", "650 MB"),
    ("Parakeet TDT v2", "parakeet-tdt-0.6b-v2-coreml", "English", "650 MB"),
    ("Whisper Small (Tiny)", "openai_whisper-tiny", "Multilingual", "73 MB"),
    ("Whisper Medium (Base)", "openai_whisper-base", "Multilingual", "140 MB"),
    ("Whisper Large v3", "openai_whisper-large-v3-v20240930", "Multilingual", "1.5 GB"),
  ]

  static func main() async throws {
    if hasFlag("--help") || hasFlag("-h") {
      printUsage()
      return
    }

    do {
      configureCachePaths()

      let modelID = try await resolveModel()
      guard await requestMicrophoneAccess() else {
        fail("Microphone permission denied. Grant access to your terminal in System Settings -> Privacy & Security -> Microphone")
      }

      let transcriber = CLITranscriber()
      try await transcriber.loadModel(modelID)

      let recorder = CLIRecorder()
      let audioURL = try recorder.prepare()
      let outputPath = flagValue("--output") ?? flagValue("-o")

      fputs("Recording... press Enter or Ctrl+C to stop\n", stderr)
      try recorder.startRecording()

      let stopMonitor = CLIStopMonitor()
      defer { stopMonitor.cancel() }

      let stopTrigger = await stopMonitor.waitForStop()
      if stopTrigger == .sigint {
        fputs("\nStopping recording...\n", stderr)
      }

      try await recorder.stopRecording()

      fputs("Transcribing...\n", stderr)
      let text = try await transcriber.transcribe(audioURL: audioURL, model: modelID)
      defer { try? FileManager.default.removeItem(at: audioURL) }

      print(text)

      if let outputPath {
        try text.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
        fputs("Written to \(outputPath)\n", stderr)
      }
    } catch {
      fail(error.localizedDescription)
    }
  }

  private static func resolveModel() async throws -> String {
    if let explicit = flagValue("--model") ?? flagValue("-m") {
      return explicit
    }

    let transcriber = CLITranscriber()
    for model in models {
      if await transcriber.isDownloaded(model.id) {
        fputs("Found model: \(model.name)\n", stderr)
        return model.id
      }
    }

    fputs("\nNo model found. Choose one to download:\n\n", stderr)
    for (index, model) in models.enumerated() {
      let suffix = index == 0 ? " (recommended)" : ""
      fputs("  [\(index + 1)] \(model.name) - \(model.language), \(model.size)\(suffix)\n", stderr)
    }
    fputs("\nEnter number [1]: ", stderr)

    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let choice = Int(input) ?? 1
    guard (1...models.count).contains(choice) else {
      throw CLIUsageError.invalidModelChoice
    }
    return models[choice - 1].id
  }

  private static func configureCachePaths() {
    guard let appSupport = try? URL.hexApplicationSupport else {
      return
    }
    let cache = appSupport.appendingPathComponent("cache", isDirectory: true)
    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    setenv("XDG_CACHE_HOME", cache.path, 1)
  }

  private static func requestMicrophoneAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private static func flagValue(_ flag: String) -> String? {
    let args = Array(CommandLine.arguments.dropFirst())
    if let index = args.firstIndex(of: flag), args.indices.contains(index + 1) {
      return args[index + 1]
    }

    let prefix = "\(flag)="
    return args.first { $0.hasPrefix(prefix) }?.dropFirst(prefix.count).description
  }

  private static func hasFlag(_ flag: String) -> Bool {
    CommandLine.arguments.contains(flag)
  }

  private static func printUsage() {
    let usage = """
    Usage: hex-cli [--model MODEL_ID] [--output PATH]

    Record audio from the default microphone until you press Enter or Ctrl+C, then transcribe it locally.

    Options:
      -m, --model   Use a specific model identifier
      -o, --output  Write the transcript to a file as well as stdout
      -h, --help    Show this help text
    """
    print(usage)
  }

  private static func fail(_ message: String) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(1)
  }
}

private enum CLIUsageError: LocalizedError {
  case invalidModelChoice

  var errorDescription: String? {
    switch self {
    case .invalidModelChoice:
      return "Invalid model choice"
    }
  }
}
