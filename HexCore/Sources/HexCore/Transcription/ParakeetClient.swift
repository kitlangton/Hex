import Foundation

#if canImport(FluidAudio)
import CoreML
import FluidAudio

final class ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private let logger = HexLog.parakeet
  private let modelConfiguration: MLModelConfiguration?
  private let vendorDirectories = [
    "fluidaudio/Models",
    "FluidAudio/Models",
  ]

  init(modelConfiguration: MLModelConfiguration? = nil) {
    self.modelConfiguration = modelConfiguration
  }

  func isModelAvailable(_ modelName: String) -> Bool {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      logger.error("Unknown Parakeet variant requested: \(modelName)")
      return false
    }
    if currentVariant == variant, asr != nil {
      return true
    }

    logger.debug("Checking Parakeet availability variant=\(variant.identifier)")
    for directory in modelDirectories(variant) {
      if directoryContainsMLModelC(directory) {
        logger.notice("Found Parakeet cache at \(directory.path)")
        return true
      }
    }
    logger.debug("No Parakeet cache detected variant=\(variant.identifier)")
    return false
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    if currentVariant == variant, asr != nil {
      return
    }
    if currentVariant != variant {
      asr = nil
      models = nil
    }

    let startedAt = Date()
    logger.notice("Starting Parakeet load variant=\(variant.identifier)")
    let loadingProgress = Progress(totalUnitCount: 100)
    loadingProgress.completedUnitCount = 1
    progress(loadingProgress)

    let downloadedModels = try await AsrModels.downloadAndLoad(
      configuration: modelConfiguration,
      version: variant.asrVersion
    )
    models = downloadedModels

    let manager = AsrManager(config: .init())
    try await manager.initialize(models: downloadedModels)
    asr = manager
    currentVariant = variant

    loadingProgress.completedUnitCount = 100
    progress(loadingProgress)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let asr else {
      throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"])
    }

    let startedAt = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent)")
    let result = try await asr.transcribe(url)
    logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
    return result.text
  }

  func deleteCaches(modelName: String) {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      return
    }

    let fileManager = FileManager.default
    var removedAny = false
    for directory in modelDirectories(variant) {
      if fileManager.fileExists(atPath: directory.path) {
        try? fileManager.removeItem(at: directory)
        removedAny = true
      }
    }

    if removedAny {
      asr = nil
      models = nil
      if currentVariant == variant {
        currentVariant = nil
      }
    }
  }

  private func directoryContainsMLModelC(_ directory: URL) -> Bool {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: directory.path) else {
      return false
    }

    if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) {
      for case let url as URL in enumerator {
        if url.pathExtension == "mlmodelc" || url.lastPathComponent.hasSuffix(".mlmodelc") {
          return true
        }
      }
    }
    return false
  }

  private func modelDirectories(_ variant: ParakeetModel) -> [URL] {
    let fileManager = FileManager.default
    var results: [URL] = []

    for root in candidateRoots() {
      for vendorDirectory in vendorDirectories {
        let base = root.appendingPathComponent(vendorDirectory, isDirectory: true)
        let direct = base.appendingPathComponent(variant.identifier, isDirectory: true)
        results.append(direct)

        if let items = try? fileManager.contentsOfDirectory(
          at: base,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: .skipsHiddenFiles
        ) {
          for item in items where item.lastPathComponent.hasPrefix(variant.identifier) && item != direct {
            results.append(item)
          }
        }
      }
    }

    return results
  }

  private func candidateRoots() -> [URL] {
    let fileManager = FileManager.default
    let xdgCache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    let applicationSupport = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let appCache = try? URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
    let userCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
    return [xdgCache, appCache, applicationSupport, userCache].compactMap { $0 }
  }
}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2:
      return .v2
    case .multilingualV3:
      return .v3
    }
  }
}

#else

final class ParakeetClient {
  init(modelConfiguration: Any? = nil) {}

  func isModelAvailable(_ modelName: String) -> Bool { false }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Hex."]
    )
  }

  func transcribe(_ url: URL) async throws -> String {
    throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"])
  }

  func deleteCaches(modelName: String) {}
}

#endif
