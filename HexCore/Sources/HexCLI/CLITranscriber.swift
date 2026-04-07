import Foundation
import CoreML
import HexCore

final class CLITranscriber: @unchecked Sendable {
  private let engine: HexTranscriptionEngine = {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    return HexTranscriptionEngine(parakeetModelConfiguration: configuration)
  }()

  func isDownloaded(_ model: String) async -> Bool {
    await engine.isModelDownloaded(model)
  }

  func loadModel(_ model: String) async throws {
    let alreadyCached = await isDownloaded(model)
    if alreadyCached {
      fputs("Loading model...", stderr)
    } else {
      fputs("Downloading model...\n", stderr)
    }

    var lastPercentage = -1
    try await engine.downloadAndLoadModel(variant: model) { progress in
      let percentage = Int(progress.fractionCompleted * 100)
      guard percentage != lastPercentage else {
        return
      }
      lastPercentage = percentage

      if alreadyCached {
        fputs(".", stderr)
      } else {
        let filled = percentage / 5
        let empty = max(0, 20 - filled)
        let bar = String(repeating: "#", count: filled) + String(repeating: "-", count: empty)
        fputs("\r  [\(bar)] \(percentage)%", stderr)
      }
    }

    fputs("\nModel ready\n", stderr)
  }

  func transcribe(audioURL: URL, model: String) async throws -> String {
    try await engine.transcribe(url: audioURL, model: model)
  }
}
