import Foundation
#if canImport(CoreML)
import CoreML
#endif
import WhisperKit

private let transcriptionLogger = HexLog.transcription
private let modelsLogger = HexLog.models
private let parakeetLogger = HexLog.parakeet

public final class HexTranscriptionEngine: @unchecked Sendable {
  private var whisperKit: WhisperKit?
  private var currentModelName: String?
  private var parakeet: ParakeetClient

  private lazy var modelsBaseFolder: URL = {
    do {
      return try URL.hexModelsDirectory
    } catch {
      fatalError("Could not create Application Support folder: \(error)")
    }
  }()

  public init(parakeetModelConfiguration: MLModelConfiguration? = nil) {
    parakeet = ParakeetClient(modelConfiguration: parakeetModelConfiguration)
  }

  public func downloadAndLoadModel(
    variant: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    if isParakeet(variant) {
      try await parakeet.ensureLoaded(modelName: variant, progress: progressCallback)
      currentModelName = variant
      return
    }

    let resolvedVariant = await resolveVariant(variant)
    if resolvedVariant.isEmpty {
      throw NSError(
        domain: "TranscriptionClient",
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Cannot download model: Empty model name"]
      )
    }

    let overallProgress = Progress(totalUnitCount: 100)
    overallProgress.completedUnitCount = 0
    progressCallback(overallProgress)

    modelsLogger.info("Preparing model download and load for \(resolvedVariant)")

    if !(await isModelDownloaded(resolvedVariant)) {
      try await downloadModelIfNeeded(variant: resolvedVariant) { downloadProgress in
        let fraction = downloadProgress.fractionCompleted * 0.5
        overallProgress.completedUnitCount = Int64(fraction * 100)
        progressCallback(overallProgress)
      }
    } else {
      overallProgress.completedUnitCount = 50
      progressCallback(overallProgress)
    }

    try await loadWhisperKitModel(resolvedVariant) { loadingProgress in
      let fraction = 0.5 + (loadingProgress.fractionCompleted * 0.5)
      overallProgress.completedUnitCount = Int64(fraction * 100)
      progressCallback(overallProgress)
    }

    overallProgress.completedUnitCount = 100
    progressCallback(overallProgress)
  }

  public func deleteModel(variant: String) async throws {
    if isParakeet(variant) {
      parakeet.deleteCaches(modelName: variant)
      if currentModelName == variant {
        unloadCurrentModel()
      }
      return
    }

    let modelFolder = modelPath(for: variant)
    guard FileManager.default.fileExists(atPath: modelFolder.path) else {
      return
    }

    if currentModelName == variant {
      unloadCurrentModel()
    }

    try FileManager.default.removeItem(at: modelFolder)
    modelsLogger.info("Deleted model \(variant)")
  }

  public func isModelDownloaded(_ modelName: String) async -> Bool {
    if isParakeet(modelName) {
      let available = parakeet.isModelAvailable(modelName)
      parakeetLogger.debug("Parakeet available? \(available)")
      return available
    }

    let modelFolderPath = modelPath(for: modelName).path
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: modelFolderPath) else {
      return false
    }

    do {
      let contents = try fileManager.contentsOfDirectory(atPath: modelFolderPath)
      guard !contents.isEmpty else {
        return false
      }

      let hasModelFiles = contents.contains { $0.hasSuffix(".mlmodelc") || $0.contains("model") }
      let tokenizerFolderPath = tokenizerPath(for: modelName).path
      let hasTokenizer = fileManager.fileExists(atPath: tokenizerFolderPath)
      return hasModelFiles && hasTokenizer
    } catch {
      return false
    }
  }

  public func getRecommendedModels() async -> ModelSupport {
    await WhisperKit.recommendedRemoteModels()
  }

  public func getAvailableModels() async throws -> [String] {
    var names = try await WhisperKit.fetchAvailableModels()
    #if canImport(FluidAudio)
    for model in ParakeetModel.allCases.reversed() {
      if !names.contains(model.identifier) {
        names.insert(model.identifier, at: 0)
      }
    }
    #endif
    return names
  }

  public func transcribe(
    url: URL,
    model: String,
    options: DecodingOptions,
    progressCallback: @escaping (Progress) -> Void
  ) async throws -> String {
    let startAll = Date()

    if isParakeet(model) {
      transcriptionLogger.notice("Transcribing with Parakeet model=\(model) file=\(url.lastPathComponent)")
      let startLoad = Date()
      try await downloadAndLoadModel(variant: model, progressCallback: progressCallback)
      transcriptionLogger.info("Parakeet ensureLoaded took \(String(format: "%.2f", Date().timeIntervalSince(startLoad)))s")

      let preparedClip = try ParakeetClipPreparer.ensureMinimumDuration(url: url, logger: parakeetLogger)
      defer { preparedClip.cleanup() }

      let startTranscription = Date()
      let text = try await parakeet.transcribe(preparedClip.url)
      transcriptionLogger.info("Parakeet transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTranscription)))s")
      transcriptionLogger.info("Parakeet request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")
      return text
    }

    let resolvedModel = await resolveVariant(model)
    if whisperKit == nil || resolvedModel != currentModelName {
      unloadCurrentModel()
      let startLoad = Date()
      try await downloadAndLoadModel(variant: resolvedModel, progressCallback: progressCallback)
      let loadDuration = Date().timeIntervalSince(startLoad)
      transcriptionLogger.info("WhisperKit ensureLoaded model=\(resolvedModel) took \(String(format: "%.2f", loadDuration))s")
    }

    guard let whisperKit else {
      throw NSError(
        domain: "TranscriptionClient",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to initialize WhisperKit for model: \(resolvedModel)"]
      )
    }

    transcriptionLogger.notice("Transcribing with WhisperKit model=\(resolvedModel) file=\(url.lastPathComponent)")
    let startTranscription = Date()
    let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
    transcriptionLogger.info("WhisperKit transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTranscription)))s")
    transcriptionLogger.info("WhisperKit request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)))s")
    return results.map(\.text).joined(separator: " ")
  }

  public func transcribe(url: URL, model: String) async throws -> String {
    try await transcribe(url: url, model: model, options: DecodingOptions()) { _ in }
  }

  private func resolveVariant(_ variant: String) async -> String {
    guard variant.contains("*") || variant.contains("?") else {
      return variant
    }

    let names: [String]
    do {
      names = try await WhisperKit.fetchAvailableModels()
    } catch {
      return variant
    }

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
    let sanitizedVariant = variant.components(separatedBy: CharacterSet(charactersIn: "./\\")).joined(separator: "_")

    return modelsBaseFolder
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent(sanitizedVariant, isDirectory: true)
  }

  private func tokenizerPath(for variant: String) -> URL {
    modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
  }

  private func unloadCurrentModel() {
    whisperKit = nil
    currentModelName = nil
  }

  private func downloadModelIfNeeded(
    variant: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let modelFolder = modelPath(for: variant)
    let downloaded = await isModelDownloaded(variant)

    if FileManager.default.fileExists(atPath: modelFolder.path), !downloaded {
      try FileManager.default.removeItem(at: modelFolder)
    }

    if downloaded {
      return
    }

    modelsLogger.info("Downloading model \(variant)")

    let parentDirectory = modelFolder.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

    do {
      let tempFolder = try await WhisperKit.download(
        variant: variant,
        downloadBase: nil,
        useBackgroundSession: false,
        progressCallback: progressCallback
      )

      try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
      try moveContents(of: tempFolder, to: modelFolder)
      modelsLogger.info("Downloaded model to \(modelFolder.path)")
    } catch {
      FileManager.default.removeItemIfExists(at: modelFolder)
      modelsLogger.error("Error downloading model \(variant): \(error.localizedDescription)")
      throw error
    }
  }

  private func loadWhisperKitModel(
    _ modelName: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let loadingProgress = Progress(totalUnitCount: 100)
    loadingProgress.completedUnitCount = 0
    progressCallback(loadingProgress)

    let config = WhisperKitConfig(
      model: modelName,
      modelFolder: modelPath(for: modelName).path,
      tokenizerFolder: tokenizerPath(for: modelName),
      prewarm: false,
      load: true
    )

    whisperKit = try await WhisperKit(config)
    currentModelName = modelName

    loadingProgress.completedUnitCount = 100
    progressCallback(loadingProgress)
    modelsLogger.info("Loaded WhisperKit model \(modelName)")
  }

  private func moveContents(of sourceFolder: URL, to destinationFolder: URL) throws {
    let fileManager = FileManager.default
    let items = try fileManager.contentsOfDirectory(atPath: sourceFolder.path)
    for item in items {
      let source = sourceFolder.appendingPathComponent(item)
      let destination = destinationFolder.appendingPathComponent(item)
      try fileManager.moveItem(at: source, to: destination)
    }
  }
}
