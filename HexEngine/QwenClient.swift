import Foundation
import HexCore
import os

#if canImport(MLXAudioSTT)
import MLXAudioSTT
import MLXAudioCore
import MLX
import HuggingFace

actor QwenClient {
  private var model: Qwen3ASRModel?
  private var loadedModelName: String?
  private let logger = HexLog.transcription

  private func cacheDirectory() throws -> URL {
    let base = try URL.hexModelsDirectory
    let mlxDir = base.appendingPathComponent("mlx", isDirectory: true)
    
    try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
    
    return mlxDir
  }

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard modelName.lowercased().contains("qwen") else { return false }
    
    if loadedModelName == modelName, model != nil { return true }

    let fm = FileManager.default
    guard let cacheDir = try? cacheDirectory() else { return false }
    let modelSubdir = modelName.replacingOccurrences(of: "/", with: "_")
    let modelDir = cacheDir.appendingPathComponent("mlx-audio").appendingPathComponent(modelSubdir)

    guard fm.fileExists(atPath: modelDir.path) else { return false }

    let configPath = modelDir.appendingPathComponent("config.json")
    
    guard fm.fileExists(atPath: configPath.path) else { return false }

    if let files = try? fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil) {
      return files.contains { $0.pathExtension == "safetensors" }
    }
    
    return false
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    if loadedModelName == modelName, model != nil { return }

    let t0 = Date()
    
    logger.notice("Starting Qwen3 load variant=\(modelName)")

    let overallProgress = Progress(totalUnitCount: 100)
    
    overallProgress.completedUnitCount = 1
    
    progress(overallProgress)

    let cacheDir = try cacheDirectory()
    let cache = HubCache(cacheDirectory: cacheDir)
    let repoID = Repo.ID(rawValue: modelName)

    guard let repoID else {
      throw NSError(
        domain: "QwenClient",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Invalid Qwen3 repository identifier: \(modelName)"]
      )
    }

    // 1. Download Phase (reports real progress from HubClient, scales 1 to 90)
    logger.info("Resolving or downloading Qwen3 model \(modelName)")
    
    let modelDir = try await ModelUtils.resolveOrDownloadModel(
      client: HubClient(cache: cache),
      cache: cache,
      repoID: repoID,
      requiredExtension: "safetensors",
      progressHandler: { p in
        let pct = Int64(p.fractionCompleted * 89) + 1
        overallProgress.completedUnitCount = pct
        progress(overallProgress)
      }
    )

    // 2. Model loading phase (reports 90-100%)
    overallProgress.completedUnitCount = 90
    
    progress(overallProgress)

    logger.info("Instantiating Qwen3 model from directory \(modelDir.path)")
    
    let loadedModel = try await Qwen3ASRModel.fromModelDirectory(modelDir)
    
    self.model = loadedModel
    self.loadedModelName = modelName

    overallProgress.completedUnitCount = 100
    
    progress(overallProgress)

    logger.notice("Qwen3 ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let model else {
      throw NSError(
        domain: "QwenClient",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Qwen3 model not initialized"]
      )
    }
    
    let t0 = Date()
    
    logger.notice("Transcribing with Qwen3 file=\(url.lastPathComponent)")

    let (sampleRate, audio) = try loadAudioArray(from: url, sampleRate: 16000)

    let output = model.generate(audio: audio)

    logger.info("Qwen3 transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    
    return output.text
  }

  func deleteCaches(modelName: String) async throws {
    let fm = FileManager.default
    let cacheDir = try cacheDirectory()
    let modelSubdir = modelName.replacingOccurrences(of: "/", with: "_")
    let modelDir = cacheDir.appendingPathComponent("mlx-audio").appendingPathComponent(modelSubdir)

    var removedAny = false
    
    if fm.fileExists(atPath: modelDir.path) {
      try fm.removeItem(at: modelDir)
      removedAny = true
      logger.notice("Deleted Qwen3 cache at \(modelDir.path)")
    }

    if let repoID = Repo.ID(rawValue: modelName) {
      let cache = HubCache(cacheDirectory: cacheDir)
      let hubRepoDir = cache.repoDirectory(repo: repoID, kind: .model)

      if fm.fileExists(atPath: hubRepoDir.path) {
        try? fm.removeItem(at: hubRepoDir)
        removedAny = true
        logger.notice("Deleted HuggingFace hub cache at \(hubRepoDir.path)")
      }
    }

    if removedAny {
      if loadedModelName == modelName {
        self.model = nil
        self.loadedModelName = nil
      }
    }
  }
}

#else

actor QwenClient {
  func isModelAvailable(_ modelName: String) async -> Bool { false }
  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "QwenClient",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "MLX support not linked. Link MLXAudioSTT dependency package to Hex."]
    )
  }
  func transcribe(_ url: URL) async throws -> String {
    throw NSError(
      domain: "QwenClient",
      code: -3,
      userInfo: [NSLocalizedDescriptionKey: "Qwen3 ASR not available"]
    )
  }
  func deleteCaches(modelName: String) async throws {}
}

#endif
