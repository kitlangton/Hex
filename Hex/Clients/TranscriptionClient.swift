//
//  TranscriptionClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import WhisperKit

private let transcriptionLogger = HexLog.transcription
private let modelsLogger = HexLog.models
private let parakeetLogger = HexLog.parakeet

/// A client that downloads and loads WhisperKit models, then transcribes audio files using the loaded model.
/// Exposes progress callbacks to report overall download-and-load percentage and transcription progress.
@DependencyClient
struct TranscriptionClient {
  /// Transcribes an audio file at the specified `URL` using the named `model`.
  /// Reports transcription progress via `progressCallback`.
  var transcribe: @Sendable (URL, String, DecodingOptions, @escaping (Progress) -> Void) async throws -> String

  /// Ensures a model is downloaded (if missing) and loaded into memory, reporting progress via `progressCallback`.
  var downloadModel: @Sendable (String, @escaping (Progress) -> Void) async throws -> Void

  /// Deletes a model from disk if it exists
  var deleteModel: @Sendable (String) async throws -> Void

  /// Checks if a named model is already downloaded on this system.
  var isModelDownloaded: @Sendable (String) async -> Bool = { _ in false }

  /// Fetches a recommended set of models for the user's hardware from Hugging Face's `argmaxinc/whisperkit-coreml`.
  var getRecommendedModels: @Sendable () async throws -> ModelSupport

  /// Lists all model variants found in `argmaxinc/whisperkit-coreml`.
  var getAvailableModels: @Sendable () async throws -> [String]
}

extension TranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = TranscriptionClientLive()
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

/// An `actor` that manages WhisperKit models by downloading (from Hugging Face),
//  loading them into memory, and then performing transcriptions.

actor TranscriptionClientLive {
  // MARK: - Stored Properties

  /// The current in-memory `WhisperKit` instance, if any.
  private var whisperKit: WhisperKit?

  /// The name of the currently loaded model, if any.
  private var currentModelName: String?
  private var parakeet: ParakeetClient = ParakeetClient()

  /// The base folder under which we store model data (e.g., ~/Library/Application Support/...).
  private lazy var modelsBaseFolder: URL = {
    do {
      return try URL.hexModelsDirectory
    } catch {
      fatalError("Could not create Application Support folder: \(error)")
    }
  }()

  // MARK: - Public Methods

  /// Ensures the given `variant` model is downloaded and loaded, reporting
  /// overall progress (0%–50% for downloading, 50%–100% for loading).
  func downloadAndLoadModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
    // If Parakeet, use Parakeet client path
    if isParakeet(variant) {
      try await parakeet.ensureLoaded(modelName: variant, progress: progressCallback)
      currentModelName = variant
      return
    }
    // Resolve wildcard patterns (e.g., "distil*large-v3") to a concrete variant
    let variant = await resolveVariant(variant)
    // Special handling for corrupted or malformed variant names
    if variant.isEmpty {
      throw NSError(
        domain: "TranscriptionClient",
        code: -3,
        userInfo: [
          NSLocalizedDescriptionKey: "Cannot download model: Empty model name",
        ]
      )
    }

    let overallProgress = Progress(totalUnitCount: 100)
    overallProgress.completedUnitCount = 0
    progressCallback(overallProgress)

    modelsLogger.info("Preparing model download and load for \(variant)")

    // 1) Model download phase (0-50% progress)
    if !(await isModelDownloaded(variant)) {
      try await downloadModelIfNeeded(variant: variant) { downloadProgress in
        let fraction = downloadProgress.fractionCompleted * 0.5
        overallProgress.completedUnitCount = Int64(fraction * 100)
        progressCallback(overallProgress)
      }
    } else {
      // Skip download phase if already downloaded
      overallProgress.completedUnitCount = 50
      progressCallback(overallProgress)
    }

    // 2) Model loading phase (50-100% progress)
    try await loadWhisperKitModel(variant) { loadingProgress in
      let fraction = 0.5 + (loadingProgress.fractionCompleted * 0.5)
      overallProgress.completedUnitCount = Int64(fraction * 100)
      progressCallback(overallProgress)
    }

    // Final progress update
    overallProgress.completedUnitCount = 100
    progressCallback(overallProgress)
  }

  /// Deletes a model from disk if it exists
  func deleteModel(variant: String) async throws {
    if isParakeet(variant) {
      try await parakeet.deleteCaches(modelName: variant)
      if currentModelName == variant { unloadCurrentModel() }
      return
    }
    let modelFolder = modelPath(for: variant)

    // Check if the model exists
    guard FileManager.default.fileExists(atPath: modelFolder.path) else {
      // Model doesn't exist, nothing to delete
      return
    }

    // If this is the currently loaded model, unload it first
    if currentModelName == variant {
      unloadCurrentModel()
    }

    // Delete the model directory
    try FileManager.default.removeItem(at: modelFolder)

    modelsLogger.info("Deleted model \(variant)")
  }

  /// Returns `true` if the model is already downloaded to local application support or Documents folder.
  /// Performs a thorough check to ensure the model files are actually present and usable.
  func isModelDownloaded(_ modelName: String) async -> Bool {
    if isParakeet(modelName) {
      let available = await parakeet.isModelAvailable(modelName)
      parakeetLogger.debug("Parakeet available? \(available)")
      return available
    }
    let fileManager = FileManager.default

    for candidate in modelCandidatePaths(for: modelName) {
      let modelFolderPath = candidate.path
      guard fileManager.fileExists(atPath: modelFolderPath) else { continue }

      do {
        let contents = try fileManager.contentsOfDirectory(atPath: modelFolderPath)
        guard !contents.isEmpty else { continue }

        let hasModelFiles = contents.contains { $0.hasSuffix(".mlmodelc") || $0.contains("model") || $0 == "config.json" }
        let tokenizerFolderPath = candidate.appendingPathComponent("tokenizer", isDirectory: true).path
        let hasTokenizer = fileManager.fileExists(atPath: tokenizerFolderPath) || contents.contains(where: { $0.contains("tokenizer") })

        if hasModelFiles && hasTokenizer {
          return true
        }
      } catch {
        continue
      }
    }
    return false
  }

  /// Returns a list of recommended models based on current device hardware.
  func getRecommendedModels() async -> ModelSupport {
    await WhisperKit.recommendedRemoteModels()
  }

  /// Lists all model variants available in remote repository plus local models in App Support and Documents.
  func getAvailableModels() async throws -> [String] {
    var names = (try? await WhisperKit.fetchAvailableModels()) ?? []
    #if canImport(FluidAudio)
    for model in ParakeetModel.allCases.reversed() {
      if !names.contains(model.identifier) { names.insert(model.identifier, at: 0) }
    }
    #endif

    let fm = FileManager.default
    var scanDirectories: [URL] = []

    if let baseDir = try? URL.hexModelsDirectory.appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true) {
      scanDirectories.append(baseDir)
    }

    let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first
    if let docsURL {
      scanDirectories.append(docsURL.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true))
      scanDirectories.append(docsURL.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true))
      scanDirectories.append(docsURL.appendingPathComponent("models", isDirectory: true))
      scanDirectories.append(docsURL)
    }

    for dir in scanDirectories {
      guard let subdirs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
      for subdir in subdirs {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue {
          let folderName = subdir.lastPathComponent
          if folderName != "argmaxinc" && folderName != "whisperkit-coreml" && folderName != "huggingface" && folderName != "models" {
            if let contents = try? fm.contentsOfDirectory(atPath: subdir.path),
               contents.contains(where: { $0.hasSuffix(".mlmodelc") || $0.contains("model") || $0 == "tokenizer" || $0 == "config.json" }) {
              if !names.contains(folderName) {
                names.append(folderName)
              }
            }
          }
        }
      }
    }

    return names
  }

  /// Transcribes the audio file at `url` using a `model` name.
  /// If the model is not yet loaded (or if it differs from the current model), it is downloaded and loaded first.
  /// Transcription progress can be monitored via `progressCallback`.
  func transcribe(
    url: URL,
    model: String,
    options: DecodingOptions,
    progressCallback: @escaping (Progress) -> Void
  ) async throws -> String {
    let startAll = Date()
    if isParakeet(model) {
      transcriptionLogger.notice("Transcribing with Parakeet model=\(model) file=\(url.lastPathComponent)")
      let startLoad = Date()
      try await downloadAndLoadModel(variant: model) { p in
        progressCallback(p)
      }
      transcriptionLogger.info("Parakeet ensureLoaded took \(String(format: "%.2f", Date().timeIntervalSince(startLoad)), privacy: .public)s")
      let preparedClip = try ParakeetClipPreparer.ensureMinimumDuration(url: url, logger: parakeetLogger)
      defer { preparedClip.cleanup() }
      let startTx = Date()
      let text = try await parakeet.transcribe(preparedClip.url)
      transcriptionLogger.info("Parakeet transcription took \(String(format: "%.2f", Date().timeIntervalSince(startTx)), privacy: .public)s")
      transcriptionLogger.info("Parakeet request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)), privacy: .public)s")
      return text
    }
    let model = await resolveVariant(model)
    // Load or switch to the required model if needed.
    if whisperKit == nil || model != currentModelName {
      unloadCurrentModel()
      let startLoad = Date()
      try await downloadAndLoadModel(variant: model) { p in
        // Debug logging, or scale as desired:
        progressCallback(p)
      }
      let loadDuration = Date().timeIntervalSince(startLoad)
      transcriptionLogger.info("WhisperKit ensureLoaded model=\(model, privacy: .public) took \(String(format: "%.2f", loadDuration), privacy: .public)s")
    }

    guard let whisperKit = whisperKit else {
      throw NSError(
        domain: "TranscriptionClient",
        code: -1,
        userInfo: [
          NSLocalizedDescriptionKey: "Failed to initialize WhisperKit for model: \(model)",
        ]
      )
    }

    // Check if parallel mode is requested via concurrentWorkerCount > 0
    let useParallel = options.concurrentWorkerCount > 0
    let audioLen = try await audioDuration(of: url)

    if useParallel {
      transcriptionLogger.notice("Using parallel chunked transcription for model=\(model, privacy: .public) file=\(url.lastPathComponent, privacy: .public) duration=\(String(format: "%.1f", audioLen), privacy: .public)s")
      let text = try await transcribeParallel(whisperKit: whisperKit, url: url, model: model, options: options)
      transcriptionLogger.info("Parallel transcription total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)), privacy: .public)s")
      return text
    }

    // Standard transcription path.
    transcriptionLogger.notice("Transcribing with WhisperKit model=\(model, privacy: .public) file=\(url.lastPathComponent, privacy: .public)")
    let startTx = Date()
    let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
    let txDuration = Date().timeIntervalSince(startTx)
    transcriptionLogger.info("WhisperKit transcription took \(String(format: "%.2f", txDuration), privacy: .public)s for \(String(format: "%.1f", audioLen), privacy: .public)s audio (realtime=\(String(format: "%.1f", audioLen/txDuration), privacy: .public)x)")
    transcriptionLogger.info("WhisperKit request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startAll)), privacy: .public)s")

    let text = results.map(\.text).joined(separator: " ")
    return text
  }

  /// Splits audio into chunks and transcribes them concurrently using WhisperKit's existing pipeline.
  private func transcribeParallel(
    whisperKit: WhisperKit,
    url: URL,
    model: String,
    options: DecodingOptions
  ) async throws -> String {
    // Load audio into memory
    let loadStart = Date()
    let audioArray = try await loadAudioArray(from: url)
    let loadTime = Date().timeIntervalSince(loadStart)
    let totalSamples = audioArray.count
    let sampleRate = WhisperKit.sampleRate
    let totalDuration = Double(totalSamples) / Double(sampleRate)
    transcriptionLogger.info("Parallel: audio load took \(String(format: "%.3f", loadTime), privacy: .public)s for \(String(format: "%.1f", totalDuration), privacy: .public)s audio")

    // Split into fixed 30s chunks
    let chunkSec = 30
    let chunkSamples = chunkSec * sampleRate
    var chunks: [[Float]] = []
    var offset = 0
    while offset < totalSamples {
      let end = min(offset + chunkSamples, totalSamples)
      let chunk = Array(audioArray[offset..<end])
      chunks.append(chunk)
      offset = end
    }
    let numChunks = chunks.count
    transcriptionLogger.info("Parallel: split into \(numChunks, privacy: .public) chunks of \(chunkSec, privacy: .public)s each")

    // Use WhisperKit's built-in concurrent transcription for robustness
    let txStart = Date()
    var chunkOptions = options
    // Disable VAD chunking since we pre-split, no timestamps for pure text
    chunkOptions.chunkingStrategy = .none
    chunkOptions.clipTimestamps = []
    chunkOptions.verbose = false

    let results = await whisperKit.transcribeWithResults(
      audioArrays: chunks,
      decodeOptions: chunkOptions,
      callback: nil
    )

    let totalTxTime = Date().timeIntervalSince(txStart)

    var texts: [String] = []
    var successCount = 0
    for result in results {
      switch result {
      case .success(let transcriptionResults):
        let text = transcriptionResults.map(\.text).joined(separator: " ")
        texts.append(text)
        successCount += 1
      case .failure(let error):
        transcriptionLogger.error("Parallel: chunk failed: \(error.localizedDescription)")
        texts.append("")
      }
    }

    let realtimeFactor = totalDuration / totalTxTime
    transcriptionLogger.notice("Parallel: \(successCount, privacy: .public)/\(numChunks, privacy: .public) chunks OK in \(String(format: "%.3f", totalTxTime), privacy: .public)s for \(String(format: "%.1f", totalDuration), privacy: .public)s audio (realtime=\(String(format: "%.1f", realtimeFactor), privacy: .public)x)")
    transcriptionLogger.info("Parallel: naive sequential estimate ~\(String(format: "%.1f", totalTxTime * Double(numChunks) / Double(ProcessInfo.processInfo.activeProcessorCount)), privacy: .public)s (assuming \(ProcessInfo.processInfo.activeProcessorCount, privacy: .public) cores)")

    return texts.joined(separator: " ")
  }

  /// Loads audio file into a float array, returns 16kHz mono PCM.
  private func loadAudioArray(from url: URL) async throws -> [Float] {
    let audioFile = try AVAudioFile(forReading: url)
    let format = audioFile.processingFormat
    let frameCount = UInt32(audioFile.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      throw NSError(domain: "TranscriptionClient", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
    }
    try audioFile.read(into: buffer)

    let srcRate = Float(format.sampleRate)
    let targetRate = Float(WhisperKit.sampleRate)

    if format.commonFormat == .pcmFormatFloat32 {
      let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
      if srcRate != targetRate {
        return resample(samples, from: srcRate, to: targetRate)
      }
      return samples
    } else if format.commonFormat == .pcmFormatInt16 {
      let intSamples = Array(UnsafeBufferPointer(start: buffer.int16ChannelData?[0], count: Int(buffer.frameLength)))
      let samples = intSamples.map { Float($0) / Float(Int16.max) }
      if srcRate != targetRate {
        return resample(samples, from: srcRate, to: targetRate)
      }
      return samples
    }
    throw NSError(domain: "TranscriptionClient", code: -6, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
  }

  /// Simple linear resampling
  private func resample(_ samples: [Float], from srcRate: Float, to dstRate: Float) -> [Float] {
    let ratio = srcRate / dstRate
    let outLen = Int(Float(samples.count) / ratio)
    var out = [Float](repeating: 0, count: outLen)
    for i in 0..<outLen {
      let srcIdx = Float(i) * ratio
      let lo = Int(srcIdx)
      let hi = min(lo + 1, samples.count - 1)
      let frac = srcIdx - Float(lo)
      out[i] = samples[lo] * (1 - frac) + samples[hi] * frac
    }
    return out
  }

  /// Returns audio duration in seconds.
  private func audioDuration(of url: URL) async throws -> TimeInterval {
    let audioFile = try AVAudioFile(forReading: url)
    return TimeInterval(audioFile.length) / audioFile.processingFormat.sampleRate
  }

  // MARK: - Private Helpers

  /// Resolve wildcard patterns (e.g. "distil*large-v3") to a concrete model name.
  /// Preference: downloaded > non-turbo > any match.
  private func resolveVariant(_ variant: String) async -> String {
    guard variant.contains("*") || variant.contains("?") else { return variant }

    let names: [String]
    do { names = try await WhisperKit.fetchAvailableModels() } catch { return variant }

    // Build tuple array with download status for matching models
    var models: [(name: String, isDownloaded: Bool)] = []
    for name in names where ModelPatternMatcher.matches(variant, name) {
      models.append((name, await isModelDownloaded(name)))
    }

    return ModelPatternMatcher.resolvePattern(variant, from: models) ?? variant
  }

  private func isParakeet(_ name: String) -> Bool {
    ParakeetModel(rawValue: name) != nil
  }

  private func modelCandidatePaths(for variant: String) -> [URL] {
    let sanitizedVariant = variant.components(separatedBy: CharacterSet(charactersIn: "./\\")).joined(separator: "_")
    var candidates: [URL] = []

    // 1. Application Support default models directory
    candidates.append(
      modelsBaseFolder
        .appendingPathComponent("argmaxinc")
        .appendingPathComponent("whisperkit-coreml")
        .appendingPathComponent(sanitizedVariant, isDirectory: true)
    )

    // 2. ~/Documents directory & subpaths
    let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    if let docsURL {
      candidates.append(docsURL.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(sanitizedVariant)", isDirectory: true))
      candidates.append(docsURL.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(sanitizedVariant)", isDirectory: true))
      candidates.append(docsURL.appendingPathComponent("models/\(sanitizedVariant)", isDirectory: true))
      candidates.append(docsURL.appendingPathComponent(sanitizedVariant, isDirectory: true))
    }

    return candidates
  }

  /// Creates or returns the local folder (on disk) for a given `variant` model.
  private func modelPath(for variant: String) -> URL {
    let fm = FileManager.default
    for candidate in modelCandidatePaths(for: variant) {
      if fm.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    let sanitizedVariant = variant.components(separatedBy: CharacterSet(charactersIn: "./\\")).joined(separator: "_")
    return modelsBaseFolder
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent(sanitizedVariant, isDirectory: true)
  }

  /// Creates or returns the local folder for the tokenizer files of a given `variant`.
  private func tokenizerPath(for variant: String) -> URL {
    modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
  }

  // Unloads any currently loaded model (clears `whisperKit` and `currentModelName`).
  private func unloadCurrentModel() {
    whisperKit = nil
    currentModelName = nil
  }

  /// Downloads the model to a temporary folder (if it isn't already on disk),
  /// then moves it into its final folder in `modelsBaseFolder`.
  private func downloadModelIfNeeded(
    variant: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let modelFolder = modelPath(for: variant)

    // If the model folder exists but isn't a complete model, clean it up
    let isDownloaded = await isModelDownloaded(variant)
    if FileManager.default.fileExists(atPath: modelFolder.path), !isDownloaded {
      try FileManager.default.removeItem(at: modelFolder)
    }

    // If model is already fully downloaded, we're done
    if isDownloaded {
      return
    }

    modelsLogger.info("Downloading model \(variant)")

    // Create parent directories
    let parentDir = modelFolder.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

    do {
      // Download directly using the exact variant name provided
      // WhisperKit 0.15.0 changed downloader params: passing
      // "argmaxinc/whisperkit-coreml" to a parameter interpreted as a host
      // yields NSURLErrorCannotFindHost in production builds that need
      // to fetch models for the first time. Let WhisperKit use its
      // default repo/host (Hugging Face) by omitting the repo/host arg.
      let tempFolder = try await WhisperKit.download(
        variant: variant,
        downloadBase: nil,
        useBackgroundSession: false,
        progressCallback: { progress in
          progressCallback(progress)
        }
      )

      // Ensure target folder exists
      try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)

      // Move the downloaded snapshot to the final location
      try moveContents(of: tempFolder, to: modelFolder)

      modelsLogger.info("Downloaded model to \(modelFolder.path)")
    } catch {
      // Clean up any partial download if an error occurred
      FileManager.default.removeItemIfExists(at: modelFolder)

      // Rethrow the original error
      modelsLogger.error("Error downloading model \(variant): \(error.localizedDescription)")
      throw error
    }
  }

  /// Loads a local model folder via `WhisperKitConfig`, optionally reporting load progress.
  private func loadWhisperKitModel(
    _ modelName: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let loadingProgress = Progress(totalUnitCount: 100)
    loadingProgress.completedUnitCount = 0
    progressCallback(loadingProgress)

    let modelFolder = modelPath(for: modelName)
    let tokenizerFolder = tokenizerPath(for: modelName)

    // Use WhisperKit's config to load the model
    let config = WhisperKitConfig(
      model: modelName,
      modelFolder: modelFolder.path,
      tokenizerFolder: tokenizerFolder,
      // verbose: true,
      // logLevel: .debug,
      prewarm: false,
      load: true
    )

    // The initializer automatically calls `loadModels`.
    whisperKit = try await WhisperKit(config)
    currentModelName = modelName

    // Finalize load progress
    loadingProgress.completedUnitCount = 100
    progressCallback(loadingProgress)

    modelsLogger.info("Loaded WhisperKit model \(modelName)")
  }

  /// Moves all items from `sourceFolder` into `destFolder` (shallow move of directory contents).
  private func moveContents(of sourceFolder: URL, to destFolder: URL) throws {
    let fileManager = FileManager.default
    let items = try fileManager.contentsOfDirectory(atPath: sourceFolder.path)
    for item in items {
      let src = sourceFolder.appendingPathComponent(item)
      let dst = destFolder.appendingPathComponent(item)
      try fileManager.moveItem(at: src, to: dst)
    }
  }
}
