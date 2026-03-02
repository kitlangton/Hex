import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import WhisperKit

private let transcriptionLogger = HexLog.transcription
private let modelsLogger = HexLog.models
private let parakeetLogger = HexLog.parakeet

@DependencyClient
struct TranscriptionClient {
  var transcribe: @Sendable (URL, String, DecodingOptions, @escaping (Progress) -> Void) async throws -> String
  var downloadModel: @Sendable (String, @escaping (Progress) -> Void) async throws -> Void
  var deleteModel: @Sendable (String) async throws -> Void
  var isModelDownloaded: @Sendable (String) async -> Bool = { _ in false }
  var getRecommendedModels: @Sendable () async throws -> ModelSupport
  var getAvailableModels: @Sendable () async throws -> [String]
}

extension TranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = TranscriptionClientLiveIOS()
    return Self(
      transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, progressCallback: $3) },
      downloadModel: { try await live.downloadAndLoadModel(variant: $0, progressCallback: $1) },
      deleteModel: { try await live.deleteModel(variant: $0) },
      isModelDownloaded: { await live.isModelDownloaded($0) },
      getRecommendedModels: { await live.getRecommendedModels() },
      getAvailableModels: { try await live.getAvailableModels() }
    )
  }
}

extension DependencyValues {
  var transcription: TranscriptionClient {
    get { self[TranscriptionClient.self] }
    set { self[TranscriptionClient.self] = newValue }
  }
}

actor TranscriptionClientLiveIOS {
  private var whisperKit: WhisperKit?
  private var currentModelName: String?

  #if canImport(FluidAudio)
  private var parakeet = ParakeetClient()
  #endif

  private lazy var modelsBaseFolder: URL = {
    do {
      let appSupportURL = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let ourAppFolder = appSupportURL.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
      let baseURL = ourAppFolder.appendingPathComponent("models", isDirectory: true)
      try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
      return baseURL
    } catch {
      fatalError("Could not create Application Support folder: \(error)")
    }
  }()

  func downloadAndLoadModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
    #if canImport(FluidAudio)
    if isParakeet(variant) {
      try await parakeet.ensureLoaded(modelName: variant, progress: progressCallback)
      currentModelName = variant
      return
    }
    #endif

    let variant = await resolveVariant(variant)
    if variant.isEmpty {
      throw NSError(domain: "TranscriptionClient", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot download model: Empty model name"])
    }

    let overallProgress = Progress(totalUnitCount: 100)
    overallProgress.completedUnitCount = 0
    progressCallback(overallProgress)

    if !(await isModelDownloaded(variant)) {
      try await downloadModelIfNeeded(variant: variant) { downloadProgress in
        let fraction = downloadProgress.fractionCompleted * 0.5
        overallProgress.completedUnitCount = Int64(fraction * 100)
        progressCallback(overallProgress)
      }
    } else {
      overallProgress.completedUnitCount = 50
      progressCallback(overallProgress)
    }

    try await loadWhisperKitModel(variant) { loadingProgress in
      let fraction = 0.5 + (loadingProgress.fractionCompleted * 0.5)
      overallProgress.completedUnitCount = Int64(fraction * 100)
      progressCallback(overallProgress)
    }

    overallProgress.completedUnitCount = 100
    progressCallback(overallProgress)
  }

  func deleteModel(variant: String) async throws {
    #if canImport(FluidAudio)
    if isParakeet(variant) {
      try await parakeet.deleteCaches(modelName: variant)
      if currentModelName == variant { unloadCurrentModel() }
      return
    }
    #endif

    let modelFolder = modelPath(for: variant)
    guard FileManager.default.fileExists(atPath: modelFolder.path) else { return }
    if currentModelName == variant { unloadCurrentModel() }
    try FileManager.default.removeItem(at: modelFolder)
  }

  func isModelDownloaded(_ modelName: String) async -> Bool {
    #if canImport(FluidAudio)
    if isParakeet(modelName) {
      return await parakeet.isModelAvailable(modelName)
    }
    #endif

    let modelFolderPath = modelPath(for: modelName).path
    let fm = FileManager.default
    guard fm.fileExists(atPath: modelFolderPath) else { return false }

    do {
      let contents = try fm.contentsOfDirectory(atPath: modelFolderPath)
      guard !contents.isEmpty else { return false }
      let hasModelFiles = contents.contains { $0.hasSuffix(".mlmodelc") || $0.contains("model") }
      let hasTokenizer = fm.fileExists(atPath: tokenizerPath(for: modelName).path)
      return hasModelFiles && hasTokenizer
    } catch {
      return false
    }
  }

  func getRecommendedModels() async -> ModelSupport {
    await WhisperKit.recommendedRemoteModels()
  }

  func getAvailableModels() async throws -> [String] {
    var names = try await WhisperKit.fetchAvailableModels()
    #if canImport(FluidAudio)
    for model in ParakeetModel.allCases.reversed() {
      if !names.contains(model.identifier) { names.insert(model.identifier, at: 0) }
    }
    #endif
    return names
  }

  func transcribe(
    url: URL, model: String, options: DecodingOptions, progressCallback: @escaping (Progress) -> Void
  ) async throws -> String {
    let startAll = Date()

    #if canImport(FluidAudio)
    if isParakeet(model) {
      transcriptionLogger.notice("Transcribing with Parakeet model=\(model)")
      try await downloadAndLoadModel(variant: model) { p in progressCallback(p) }
      let preparedClip = try ParakeetClipPreparer.ensureMinimumDuration(url: url, logger: parakeetLogger)
      defer { preparedClip.cleanup() }
      let text = try await parakeet.transcribe(preparedClip.url)
      transcriptionLogger.info("Parakeet total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")
      return text
    }
    #endif

    let model = await resolveVariant(model)
    if whisperKit == nil || model != currentModelName {
      unloadCurrentModel()
      try await downloadAndLoadModel(variant: model) { p in progressCallback(p) }
    }

    guard let whisperKit = whisperKit else {
      throw NSError(domain: "TranscriptionClient", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to initialize WhisperKit"])
    }

    transcriptionLogger.notice("Transcribing with WhisperKit model=\(model)")
    let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
    transcriptionLogger.info("WhisperKit total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")
    return results.map(\.text).joined(separator: " ")
  }

  // MARK: - Private

  private func resolveVariant(_ variant: String) async -> String {
    guard variant.contains("*") || variant.contains("?") else { return variant }
    let names: [String]
    do { names = try await WhisperKit.fetchAvailableModels() } catch { return variant }
    var models: [(name: String, isDownloaded: Bool)] = []
    for name in names where ModelPatternMatcher.matches(variant, name) {
      models.append((name, await isModelDownloaded(name)))
    }
    return ModelPatternMatcher.resolvePattern(variant, from: models) ?? variant
  }

  private func isParakeet(_ name: String) -> Bool {
    ParakeetModel(rawValue: name) != nil
  }

  private func modelPath(for variant: String) -> URL {
    let sanitized = variant.components(separatedBy: CharacterSet(charactersIn: "./\\")).joined(separator: "_")
    return modelsBaseFolder
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent(sanitized, isDirectory: true)
  }

  private func tokenizerPath(for variant: String) -> URL {
    modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
  }

  private func unloadCurrentModel() {
    whisperKit = nil
    currentModelName = nil
  }

  private func downloadModelIfNeeded(
    variant: String, progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let modelFolder = modelPath(for: variant)
    let isDownloaded = await isModelDownloaded(variant)
    if FileManager.default.fileExists(atPath: modelFolder.path), !isDownloaded {
      try FileManager.default.removeItem(at: modelFolder)
    }
    if isDownloaded { return }

    let parentDir = modelFolder.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

    do {
      let tempFolder = try await WhisperKit.download(
        variant: variant, downloadBase: nil, useBackgroundSession: false,
        progressCallback: { progressCallback($0) }
      )
      try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
      try moveContents(of: tempFolder, to: modelFolder)
    } catch {
      FileManager.default.removeItemIfExists(at: modelFolder)
      throw error
    }
  }

  private func loadWhisperKitModel(
    _ modelName: String, progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let loadingProgress = Progress(totalUnitCount: 100)
    progressCallback(loadingProgress)

    let config = WhisperKitConfig(
      model: modelName,
      modelFolder: modelPath(for: modelName).path,
      tokenizerFolder: tokenizerPath(for: modelName),
      prewarm: false, load: true
    )
    whisperKit = try await WhisperKit(config)
    currentModelName = modelName

    loadingProgress.completedUnitCount = 100
    progressCallback(loadingProgress)
  }

  private func moveContents(of sourceFolder: URL, to destFolder: URL) throws {
    let items = try FileManager.default.contentsOfDirectory(atPath: sourceFolder.path)
    for item in items {
      try FileManager.default.moveItem(
        at: sourceFolder.appendingPathComponent(item),
        to: destFolder.appendingPathComponent(item)
      )
    }
  }
}
