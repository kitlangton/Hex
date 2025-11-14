import Foundation

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?

  func isModelAvailable() async -> Bool {
    if asr != nil { return true }
    let fm = FileManager.default
    // Candidate roots (in priority order): XDG, AppSupport cache, AppSupport, ~/.cache
    let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let appCache = appSupport?.appendingPathComponent("com.kitlangton.Hex/cache", isDirectory: true)
    let userCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)

    let roots = [xdg, appCache, appSupport, userCache].compactMap { $0 }
    let modelId = "parakeet-tdt-0.6b-v3-coreml"
    let vendorDirs = [
      // Our app-specific cache path convention (under XDG or com.kitlangton.Hex/cache)
      "fluidaudio/Models",
      "FluidAudio/Models",
      // FluidAudio default under Application Support root
      "FluidAudio/Models"
    ]
    print("[Parakeet] Checking availability. Roots=\(roots.map(\.path))")
    for root in roots {
      for vendor in vendorDirs {
        let base = root.appendingPathComponent(vendor, isDirectory: true)
        // 1) Direct expected path
        let direct = base.appendingPathComponent(modelId, isDirectory: true)
        if directoryContainsMLModelC(direct) {
          print("[Parakeet] Found mlmodelc under \(direct.path)")
          return true
        }
        // 2) Any folder that starts with the model id
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
          for item in items where item.lastPathComponent.hasPrefix(modelId) {
            if directoryContainsMLModelC(item) {
              print("[Parakeet] Found mlmodelc under \(item.path)")
              return true
            }
          }
        }
      }
    }
    print("[Parakeet] No cached mlmodelc found.")
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

  func ensureLoaded(progress: @escaping (Progress) -> Void) async throws {
    if asr != nil { return }
    let t0 = Date()
    print("[Parakeet] ensureLoaded begin (version=v3)")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    // Best-effort progress polling while FluidAudio downloads
    let fm = FileManager.default
    let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let faDir = support?.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
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

    // Download + load Parakeet TDT v3 (returns when all assets are present)
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    self.models = models
    pollTask.cancel()
    let manager = AsrManager(config: .init())
    try await manager.initialize(models: models)
    self.asr = manager
    p.completedUnitCount = 100
    progress(p)
    print(String(format: "[Parakeet] ensureLoaded end (%.2fs)", Date().timeIntervalSince(t0)))
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

  func transcribe(_ url: URL) async throws -> String {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let t0 = Date()
    print("[Parakeet] transcribe begin file=\(url.lastPathComponent)")
    let result = try await asr.transcribe(url)
    print(String(format: "[Parakeet] transcribe end (%.2fs)", Date().timeIntervalSince(t0)))
    return result.text
  }

  // Delete cached Parakeet models from known locations and reset state
  func deleteCaches() async throws {
    let fm = FileManager.default
    let modelId = "parakeet-tdt-0.6b-v3-coreml"

    // Candidate roots (same order used for detection)
    let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let appCache = appSupport?.appendingPathComponent("com.kitlangton.Hex/cache", isDirectory: true)
    let userCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)

    // Vendor prefixes we consider
    let vendors = [
      "fluidaudio/Models",
      "FluidAudio/Models",
      // FluidAudio default under Application Support root
      "FluidAudio/Models"
    ]

    var removedAny = false
    for root in [xdg, appCache, appSupport, userCache].compactMap({ $0 }) {
      for vendor in vendors {
        let base = root.appendingPathComponent(vendor, isDirectory: true)
        // Remove exact match
        let direct = base.appendingPathComponent(modelId, isDirectory: true)
        if fm.fileExists(atPath: direct.path) {
          try? fm.removeItem(at: direct)
          removedAny = true
        }
        // Remove any prefixed folders
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
          for item in items where item.lastPathComponent.hasPrefix(modelId) {
            try? fm.removeItem(at: item)
            removedAny = true
          }
        }
      }
    }

    // Reset live objects so a future download can proceed cleanly
    if removedAny {
      self.asr = nil
      self.models = nil
    }
  }
}

#else

actor ParakeetClient {
  func isModelAvailable() async -> Bool { false }
  func ensureLoaded(progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Hex."]
    )
  }
  func transcribe(_ url: URL) async throws -> String { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
}

#endif
