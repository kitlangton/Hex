//
//  GECToRInference.swift
//  Hex
//

import Foundation
import HexCore
import OnnxRuntimeBindings

private let logger = HexLog.textCleanup

/// Actor managing GECToR model download, loading, and inference via ONNX Runtime.
///
/// The model files are downloaded from S3 on first use and stored in:
/// `~/Library/Application Support/com.kitlangton.Hex/models/gector/`
///
/// Inference runs up to 3 iterative correction passes, early-exiting when all tokens are $KEEP.
actor GECToRInference {

  // MARK: - Configuration

  private static let modelBaseURL = "https://hex-updates.s3.amazonaws.com/models/gector"
  private static let modelFiles = [
    "gector-roberta-base-int8.onnx",
    "labels.txt",
    "verb_forms.json",
  ]

  // MARK: - State

  private var session: ORTSession?
  private var tokenizer: RobertaTokenizer?
  private var tagVocabulary: TagVocabulary?
  private var verbForms: VerbFormDictionary?

  var isLoaded: Bool { session != nil }

  // MARK: - Model Directory

  private var modelDirectory: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport
      .appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent("gector", isDirectory: true)
  }

  // MARK: - Download & Load

  /// Download model files (if needed) and load into memory.
  func loadModel(progress: @escaping (Progress) -> Void) async throws {
    let overallProgress = Progress(totalUnitCount: 100)
    progress(overallProgress)

    // Phase 1: Download (0-50%)
    try await downloadIfNeeded { downloadProgress in
      overallProgress.completedUnitCount = Int64(downloadProgress * 50)
      progress(overallProgress)
    }

    // Phase 2: Load (50-100%)
    overallProgress.completedUnitCount = 50
    progress(overallProgress)
    try loadFromDisk()

    overallProgress.completedUnitCount = 100
    progress(overallProgress)
    logger.info("GECToR model loaded successfully")
  }

  /// Unload model from memory.
  func unload() {
    session = nil
    tokenizer = nil
    tagVocabulary = nil
    verbForms = nil
    logger.info("GECToR model unloaded")
  }

  /// Delete downloaded model files from disk and unload from memory.
  func deleteModel() throws {
    unload()
    let fm = FileManager.default
    let dir = modelDirectory
    for file in Self.modelFiles {
      let path = dir.appendingPathComponent(file)
      fm.removeItemIfExists(at: path)
    }
    logger.info("GECToR model files deleted")
  }

  /// Check if all model files are downloaded.
  func isModelDownloaded() -> Bool {
    let fm = FileManager.default
    let dir = modelDirectory
    logger.info("GECToR model directory: \(dir.path, privacy: .public)")
    for file in Self.modelFiles {
      let path = dir.appendingPathComponent(file).path
      let exists = fm.fileExists(atPath: path)
      logger.info("GECToR check \(file, privacy: .public): \(exists ? "found" : "MISSING", privacy: .public)")
      if !exists { return false }
    }
    return true
  }

  // MARK: - Inference

  /// Correct grammar in the given text. Runs up to `iterations` passes.
  /// Returns the corrected text, or the original if no corrections were made.
  func correct(_ text: String, iterations: Int = 3) throws -> String {
    guard let session, let tokenizer, let tagVocabulary, let verbForms else {
      throw GECToRError.modelNotLoaded
    }

    var currentText = text

    for iteration in 0..<iterations {
      let startTime = Date()

      // Tokenize
      let words = currentText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard !words.isEmpty else { return currentText }

      let (tokenIds, wordBoundaries) = tokenizer.encode(currentText)

      // Create input tensors
      let inputIds = tokenIds.map { Int64($0) }
      let attentionMask = [Int64](repeating: 1, count: tokenIds.count)
      let seqLen = tokenIds.count

      let inputIdsTensor = try createInt64Tensor(inputIds, shape: [1, seqLen])
      let attentionMaskTensor = try createInt64Tensor(attentionMask, shape: [1, seqLen])

      // Run inference
      let outputs = try session.run(
        withInputs: [
          "input_ids": inputIdsTensor,
          "attention_mask": attentionMaskTensor,
        ],
        outputNames: ["logits"],
        runOptions: nil
      )

      guard let logitsValue = outputs["logits"] else {
        throw GECToRError.missingOutput
      }

      // Parse logits → per-token predictions
      let predictions = try parseLogits(logitsValue, seqLen: seqLen, numLabels: tagVocabulary.count)

      // Align to word-level edit tags
      let editTags = SubwordAlignment.align(
        predictions: predictions,
        wordBoundaries: wordBoundaries,
        vocabulary: tagVocabulary
      )

      // Check if all tags are KEEP (early exit)
      let allKeep = editTags.allSatisfy { tag in
        if case .keep = tag { return true }
        return false
      }

      let elapsed = Date().timeIntervalSince(startTime) * 1000
      logger.info("GECToR iteration \(iteration + 1): \(String(format: "%.1f", elapsed))ms, allKeep=\(allKeep)")

      if allKeep { break }

      // Apply edits
      let corrected = SubwordAlignment.applyEdits(
        words: words,
        tags: editTags,
        verbForms: verbForms
      )

      // If no change, stop iterating
      if corrected == currentText { break }
      currentText = corrected
    }

    return currentText
  }

  // MARK: - Private: Download

  private func downloadIfNeeded(progress: @escaping (Double) -> Void) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

    // Check which files need downloading
    var filesToDownload = [(String, URL)]()
    for fileName in Self.modelFiles {
      let localPath = modelDirectory.appendingPathComponent(fileName)
      if !fm.fileExists(atPath: localPath.path) {
        guard let remoteURL = URL(string: "\(Self.modelBaseURL)/\(fileName)") else {
          throw GECToRError.invalidURL(fileName)
        }
        filesToDownload.append((fileName, remoteURL))
      }
    }

    guard !filesToDownload.isEmpty else {
      progress(1.0)
      return
    }

    logger.info("GECToR: downloading \(filesToDownload.count) files")

    for (index, (fileName, remoteURL)) in filesToDownload.enumerated() {
      let localPath = modelDirectory.appendingPathComponent(fileName)
      let tempPath = localPath.appendingPathExtension("download")

      // Clean up any partial download
      fm.removeItemIfExists(at: tempPath)

      let (tempFileURL, response) = try await URLSession.shared.download(from: remoteURL)

      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
        throw GECToRError.downloadFailed(fileName, httpResponse.statusCode)
      }

      // Move from temp location to our download path, then to final path
      try fm.moveItem(at: tempFileURL, to: tempPath)
      // Remove existing file if present (shouldn't be, but safe)
      fm.removeItemIfExists(at: localPath)
      try fm.moveItem(at: tempPath, to: localPath)

      let fileProgress = Double(index + 1) / Double(filesToDownload.count)
      progress(fileProgress)
      logger.info("GECToR: downloaded \(fileName)")
    }
  }

  // MARK: - Private: Load

  private func loadFromDisk() throws {
    let vocabURL = Bundle.main.url(forResource: "roberta_vocab", withExtension: "json")
    let mergesURL = Bundle.main.url(forResource: "roberta_merges", withExtension: "txt")

    guard let vocabURL, let mergesURL else {
      throw GECToRError.missingBundledTokenizerData
    }

    let vocabData = try Data(contentsOf: vocabURL)
    let mergesData = try Data(contentsOf: mergesURL)
    self.tokenizer = try RobertaTokenizer(vocabData: vocabData, mergesData: mergesData)

    let labelsData = try Data(contentsOf: modelDirectory.appendingPathComponent("labels.txt"))
    self.tagVocabulary = try TagVocabulary(labelsData: labelsData)

    let verbFormsData = try Data(contentsOf: modelDirectory.appendingPathComponent("verb_forms.json"))
    self.verbForms = try VerbFormDictionary(jsonData: verbFormsData)

    // Create ONNX Runtime session
    let modelPath = modelDirectory.appendingPathComponent("gector-roberta-base-int8.onnx").path
    let env = try ORTEnv(loggingLevel: .warning)
    let sessionOptions = try ORTSessionOptions()
    try sessionOptions.setLogSeverityLevel(.warning)

    // Use CoreML execution provider if available for acceleration
    try sessionOptions.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())

    self.session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: sessionOptions)
    logger.info("GECToR: ONNX session created")
  }

  // MARK: - Private: Tensor Helpers

  private func createInt64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
    let nsShape = shape.map { NSNumber(value: $0) }
    let data = values.withUnsafeBufferPointer { buffer in
      Data(buffer: buffer)
    }
    let mutableData = NSMutableData(data: data)
    return try ORTValue(
      tensorData: mutableData,
      elementType: .int64,
      shape: nsShape
    )
  }

  /// Parse [1, seq_len, num_labels] logits tensor into per-token (tagIndex, confidence) pairs.
  private func parseLogits(
    _ value: ORTValue,
    seqLen: Int,
    numLabels: Int
  ) throws -> [(tagIndex: Int, confidence: Float)] {
    let tensorData = try value.tensorData() as Data

    // Logits are Float32: [1, seqLen, numLabels]
    let floatCount = tensorData.count / MemoryLayout<Float>.size
    guard floatCount == seqLen * numLabels else {
      throw GECToRError.unexpectedShape(expected: seqLen * numLabels, got: floatCount)
    }

    let floats = tensorData.withUnsafeBytes { buffer in
      Array(buffer.bindMemory(to: Float.self))
    }

    var predictions = [(tagIndex: Int, confidence: Float)]()
    predictions.reserveCapacity(seqLen)

    for i in 0..<seqLen {
      let offset = i * numLabels
      let logits = floats[offset..<(offset + numLabels)]

      // Find argmax and softmax confidence
      var maxIdx = 0
      var maxVal = logits[offset]
      for j in 1..<numLabels {
        let val = logits[offset + j]
        if val > maxVal {
          maxVal = val
          maxIdx = j
        }
      }

      // Simple softmax for confidence of top prediction
      let expMax = exp(maxVal)
      var expSum: Float = 0
      for j in 0..<numLabels {
        expSum += exp(logits[offset + j])
      }
      let confidence = expMax / expSum

      predictions.append((tagIndex: maxIdx, confidence: confidence))
    }

    return predictions
  }
}

// MARK: - Errors

enum GECToRError: Error, LocalizedError {
  case modelNotLoaded
  case invalidURL(String)
  case downloadFailed(String, Int)
  case missingBundledTokenizerData
  case missingOutput
  case unexpectedShape(expected: Int, got: Int)

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      return "GECToR model is not loaded"
    case .invalidURL(let file):
      return "Invalid download URL for \(file)"
    case .downloadFailed(let file, let status):
      return "Failed to download \(file): HTTP \(status)"
    case .missingBundledTokenizerData:
      return "Missing bundled roberta_vocab.json or roberta_merges.txt"
    case .missingOutput:
      return "ONNX Runtime session returned no logits output"
    case .unexpectedShape(let expected, let got):
      return "Unexpected tensor shape: expected \(expected) floats, got \(got)"
    }
  }
}
