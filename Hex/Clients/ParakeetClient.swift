import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private let logger = HexLog.parakeet
  private let vendorDirs = [
    // Our app-specific cache path convention (under XDG or com.kitlangton.Hex/cache)
    "fluidaudio/Models",
    "FluidAudio/Models"
  ]

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      logger.error("Unknown Parakeet variant requested: \(modelName)")
      return false
    }
    if currentVariant == variant, asr != nil { return true }

    let directory = AsrModels.defaultCacheDirectory(for: variant.asrVersion)
    migrateLegacyCacheIfNeeded(variant, to: directory)
    let available = AsrModels.modelsExist(
      at: directory,
      version: variant.asrVersion
    )
    if available {
      logger.notice("Found Parakeet cache at \(directory.path)")
    } else {
      logger.debug("No Parakeet cache detected variant=\(variant.identifier) path=\(directory.path)")
    }
    return available
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    if currentVariant == variant, asr != nil { return }
    if currentVariant != variant {
      asr = nil
      models = nil
    }
    migrateLegacyCacheIfNeeded(
      variant,
      to: AsrModels.defaultCacheDirectory(for: variant.asrVersion)
    )
    let t0 = Date()
    logger.notice("Starting Parakeet load variant=\(variant.identifier)")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    // Use FluidAudio's byte-weighted progress. Polling the cache directory
    // size doesn't work: files are downloaded to a temporary location and
    // only moved into the cache once each completes, so the bar sat at 5%
    // until the ~600MB encoder landed. FluidAudio re-emits a 0–1 range per
    // internal stage (download, per-model compile), so only move forward.
    let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion) { downloadProgress in
      let mapped = Int64((downloadProgress.fractionCompleted * 98).rounded()) + 1
      if mapped > p.completedUnitCount, mapped < 100 {
        p.completedUnitCount = mapped
        progress(p)
      }
    }
    self.models = models
    let manager = AsrManager(config: .init(), models: models)
    self.asr = manager
    self.currentVariant = variant
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  private func migrateLegacyCacheIfNeeded(_ variant: ParakeetModel, to directory: URL) {
    let legacyDirectory = directory
      .deletingLastPathComponent()
      .appendingPathComponent(variant.identifier, isDirectory: true)

    do {
      if try LegacyModelCacheMigrator.migrate(
        from: legacyDirectory,
        to: directory,
        isValid: {
          AsrModels.modelsExist(at: $0, version: variant.asrVersion)
        }
      ) {
        logger.notice("Migrated legacy Parakeet cache from \(legacyDirectory.path) to \(directory.path)")
      }
    } catch {
      logger.error("Failed to migrate legacy Parakeet cache: \(error.localizedDescription)")
    }
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent)")
    var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let result = try await asr.transcribe(url, decoderState: &decoderState)
    logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return result.text
  }

  // Delete cached Parakeet models from known locations and reset state
  func deleteCaches(modelName: String) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else { return }
    let fm = FileManager.default

    var removedAny = false
    for dir in modelDirectories(variant) {
      if fm.fileExists(atPath: dir.path) {
        try? fm.removeItem(at: dir)
        removedAny = true
      }
    }

    // Reset live objects so a future download can proceed cleanly
    if removedAny {
      self.asr = nil
      self.models = nil
      if currentVariant == variant {
        currentVariant = nil
      }
    }
  }

  /// Returns all candidate directories where a Parakeet model might be cached.
  /// Includes both exact matches and prefixed directories (e.g. versioned folders).
  private func modelDirectories(_ variant: ParakeetModel) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = [AsrModels.defaultCacheDirectory(for: variant.asrVersion)]

    for root in candidateRoots() {
      for vendor in vendorDirs {
        let base = root.appendingPathComponent(vendor, isDirectory: true)
        // Exact match directory
        let direct = base.appendingPathComponent(variant.identifier, isDirectory: true)
        result.append(direct)
        // Prefixed directories (e.g. versioned folders)
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
          for item in items where item.lastPathComponent.hasPrefix(variant.identifier) && item != direct {
            result.append(item)
          }
        }
      }
    }
    var seen = Set<String>()
    return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  private func candidateRoots() -> [URL] {
    let fm = FileManager.default
    let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let appCache = try? URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
    let userCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
    return [xdg, appCache, appSupport, userCache].compactMap { $0 }
  }
}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    }
  }
}

#else

actor ParakeetClient {
  func isModelAvailable(_ modelName: String) async -> Bool { false }
  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Hex."]
    )
  }
  func transcribe(_ url: URL) async throws -> String { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func deleteCaches(modelName: String) async throws {}
}

#endif
