import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private var transcribeWaiters: [CheckedContinuation<Void, Never>] = []
  private var isTranscribeSlotHeld = false
  private var lastTranscriberReinitializeAt: Date?
  private let transcriberReinitializeCooldown: TimeInterval = 2.0
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

    logger.debug("Checking Parakeet availability variant=\(variant.identifier)")
    for dir in modelDirectories(variant) {
      if directoryContainsMLModelC(dir) {
        logger.notice("Found Parakeet cache at \(dir.path)")
        return true
      }
    }
    logger.debug("No Parakeet cache detected variant=\(variant.identifier)")
    return false
  }

  private func directoryContainsMLModelC(_ dir: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.path) else { return false }
    if let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
      for case let url as URL in en {
        if url.pathExtension == "mlmodelc" || url.lastPathComponent.hasSuffix(".mlmodelc") { return true }
      }
    }
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
    if currentVariant == variant, asr != nil { return }
    if currentVariant != variant {
      asr = nil
      models = nil
    }
    let t0 = Date()
    logger.notice("Starting Parakeet load variant=\(variant.identifier)")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    // Best-effort progress polling while FluidAudio downloads
    let fm = FileManager.default
    let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let faDir = support?.appendingPathComponent("FluidAudio/Models/\(variant.identifier)", isDirectory: true)
    let pollTask = Task {
      while p.completedUnitCount < 95 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let dir = faDir, let size = directorySize(dir) {
          let target: Double = 650 * 1024 * 1024 // ~650MB
          let frac = max(0.0, min(1.0, Double(size) / target))
          p.completedUnitCount = Int64(5 + frac * 90)
          progress(p)
        }
        if Task.isCancelled { break }
      }
    }
    defer { pollTask.cancel() }

    // Download + load the requested variant (returns when all assets are present)
    let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion)
    self.models = models
    let manager = AsrManager(config: .init())
    try await manager.initialize(models: models)
    self.asr = manager
    self.currentVariant = variant
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in en {
      if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
        total &+= UInt64(vals.fileSize ?? 0)
      }
    }
    return total
  }

  func transcribe(_ url: URL, reinitializeOnEmpty: Bool = true) async throws -> String {
    try Task.checkCancellation()
    await acquireTranscribeSlot()
    defer { releaseTranscribeSlot() }

    guard asr != nil else {
      throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"])
    }

    var text = try await transcribeLocked(url)
    if text.isEmpty, reinitializeOnEmpty {
      let shouldReinitialize: Bool = {
        guard let lastTranscriberReinitializeAt else { return true }
        return Date().timeIntervalSince(lastTranscriberReinitializeAt) >= transcriberReinitializeCooldown
      }()
      if shouldReinitialize {
        logger.notice("Parakeet returned empty text for \(url.lastPathComponent); reinitializing transcriber")
        try await reinitializeTranscriberLocked()
        lastTranscriberReinitializeAt = Date()
        text = try await transcribeLocked(url)
        if text.isEmpty {
          logger.notice("Parakeet returned empty text after reinitialize for \(url.lastPathComponent)")
        }
      } else {
        logger.debug("Parakeet returned empty text for \(url.lastPathComponent); skipping reinitialize cooldown")
      }
    }
    return text
  }

  func resetTranscriberState() async throws {
    await acquireTranscribeSlot()
    defer { releaseTranscribeSlot() }
    guard let asr else { return }
    try await asr.resetDecoderState()
  }

  /// Rebuilds AsrManager from cached models when decoder state becomes corrupted.
  func reinitializeTranscriber() async throws {
    await acquireTranscribeSlot()
    defer { releaseTranscribeSlot() }
    try await reinitializeTranscriberLocked()
  }

  private func transcribeLocked(_ url: URL) async throws -> String {
    guard let asr else {
      throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"])
    }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent)")
    // File-based batch transcribe uses FluidAudio's default `.system` decoder path.
    let result = try await asr.transcribe(url, source: .system)
    logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return result.text
  }

  private func reinitializeTranscriberLocked() async throws {
    guard let models, let variant = currentVariant else { return }
    let manager = AsrManager(config: .init())
    try await manager.initialize(models: models)
    self.asr = manager
    logger.notice("Parakeet transcriber reinitialized variant=\(variant.identifier)")
  }

  /// FluidAudio's AsrManager is not re-entrant; hold this slot for the entire transcribe await.
  private func acquireTranscribeSlot() async {
    if !isTranscribeSlotHeld {
      isTranscribeSlotHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      transcribeWaiters.append(continuation)
    }
  }

  private func releaseTranscribeSlot() {
    if transcribeWaiters.isEmpty {
      isTranscribeSlotHeld = false
      return
    }
    let next = transcribeWaiters.removeFirst()
    next.resume()
  }

  /// Waits until no Parakeet transcribe call is in progress.
  func waitUntilTranscribeIdle() async {
    await acquireTranscribeSlot()
    releaseTranscribeSlot()
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
    var result: [URL] = []

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
    return result
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
  func waitUntilTranscribeIdle() async {}
  func resetTranscriberState() async throws {}
  func reinitializeTranscriber() async throws {}
  func deleteCaches(modelName: String) async throws {}
}

#endif
