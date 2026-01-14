import Accelerate
import AVFoundation
import CoreML
import Dependencies
import DependenciesMacros
import FluidAudio
import Foundation
import HexCore
import SentencepieceTokenizer

// MARK: - Preprocessing (DSP)

fileprivate struct SenseVoicePreprocess {
  
  struct CMVN: Sendable {
    let means: [Float]
    let vars: [Float]
    
    init(means: [Float], vars: [Float]) {
      self.means = means
      self.vars = vars
    }
  }

  // MARK: - Audio Loading

  static func loadAudioMono16k(url: URL) async throws -> [Float] {
    // Avoid a common race: after stopRecording(), the file may exist but still report length=0 briefly.
    // Also avoid AVAudioConverter for Hex's default recording format (16kHz/mono/Float32), which can be flaky.
    for attempt in 0..<10 {
      do {
        let file = try AVAudioFile(forReading: url)
        if file.length == 0 {
          if attempt < 9 { try await Task.sleep(for: .milliseconds(30)); continue }
          return []
        }

        let inputFormat = file.processingFormat

        // Fast path: Hex's default recorder outputs 16kHz mono Float32 PCM.
        if inputFormat.commonFormat == .pcmFormatFloat32,
           inputFormat.sampleRate == 16_000,
           inputFormat.channelCount == 1
        {
          let maxCap = Int(UInt32.max)
          let inCap = max(1, Int(min(file.length, Int64(maxCap))))
          guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inCap)) else {
            return []
          }
          try file.read(into: inBuffer)

          let n = Int(inBuffer.frameLength)
          guard n > 0 else { return [] }

          if let ch = inBuffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ch, count: n))
          }

          // Interleaved fallback.
          let mData = inBuffer.audioBufferList.pointee.mBuffers.mData
          guard let mData else { return [] }
          let ptr = mData.assumingMemoryBound(to: Float.self)
          return Array(UnsafeBufferPointer(start: ptr, count: n))
        }

        // General path: resample / reformat to 16k mono Float32.
        guard let outputFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: 16_000,
          channels: 1,
          interleaved: false
        ) else {
          throw NSError(domain: "SenseVoice", code: -12, userInfo: [NSLocalizedDescriptionKey: "Failed to create output audio format"])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
          throw NSError(domain: "SenseVoice", code: -11, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        let maxCap = Int(UInt32.max)
        let inCap = max(1, Int(min(file.length, Int64(maxCap))))
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inCap)) else {
          return []
        }
        try file.read(into: inBuffer)

        if inBuffer.frameLength == 0 {
          if attempt < 9 { try await Task.sleep(for: .milliseconds(30)); continue }
          return []
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outCap = max(1, Int(Double(inBuffer.frameLength) * ratio) + 1)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outCap)) else {
          return []
        }

        var didProvide = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
          if didProvide {
            outStatus.pointee = .endOfStream
            return nil
          }
          didProvide = true
          outStatus.pointee = .haveData
          return inBuffer
        }

        if status == .error {
          throw error ?? NSError(domain: "SenseVoice", code: -13, userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed"])
        }

        let n = Int(outBuffer.frameLength)
        guard n > 0, let ch = outBuffer.floatChannelData?[0] else {
          if attempt < 9 { try await Task.sleep(for: .milliseconds(30)); continue }
          return []
        }

        return Array(UnsafeBufferPointer(start: ch, count: n))
      } catch {
        if attempt < 9 {
          try await Task.sleep(for: .milliseconds(30))
          continue
        }
        throw error
      }
    }

    return []
  }

  // MARK: - Features (fbank)

  static func computeFbank(waveform: ArraySlice<Float>) throws -> [[Float]] {
    let (sr, frameLen, frameShift, nfft, nMels) = (Float(16_000), 400, 160, 512, 80)
    if waveform.count < frameLen { return [] }

    let x = waveform.map { $0 * 32768.0 } // SenseVoice scaling
    var window = [Float](repeating: 0, count: frameLen)
    for i in 0..<frameLen {
      window[i] = 0.54 - 0.46 * cos(2 * .pi * Float(i) / Float(frameLen - 1))
    }
    let melFilters = kaldiMelFilterbank(sampleRate: sr, nfft: nfft, nMels: nMels, lowHz: 20, highHz: 0)

    guard let dft = vDSP.DFT(count: nfft, direction: .forward, transformType: .complexComplex, ofType: Float.self) else {
      throw NSError(domain: "SenseVoice", code: -20, userInfo: [NSLocalizedDescriptionKey: "DFT setup failed"])
    }

    let frameCount = 1 + (x.count - frameLen) / frameShift
    var feats = [[Float]]()
    feats.reserveCapacity(frameCount)

    var (real, imag) = ([Float](repeating: 0, count: nfft), [Float](repeating: 0, count: nfft))
    var padded = [Float](repeating: 0, count: nfft)
    let inputImag = [Float](repeating: 0, count: nfft)
    var frame = [Float](repeating: 0, count: frameLen)
    var power = [Float](repeating: 0, count: nfft/2+1)

    for i in 0..<frameCount {
      let start = i * frameShift
      for j in 0..<frameLen {
        frame[j] = x[start + j]
      }

      // Pre-emphasis
      if frameLen >= 2 {
        for j in stride(from: frameLen - 1, through: 1, by: -1) { frame[j] -= 0.97 * frame[j - 1] }
        frame[0] -= 0.97 * frame[0]
      }

      vDSP_vmul(frame, 1, window, 1, &padded, 1, vDSP_Length(frameLen)) // Windowing
      dft.transform(inputReal: padded, inputImaginary: inputImag, outputReal: &real, outputImaginary: &imag) // FFT

      // Power + Mel
      for k in 0..<power.count {
        power[k] = real[k] * real[k] + imag[k] * imag[k]
      }

      var melRow = [Float](repeating: 0, count: nMels)
      for (m, f) in melFilters.enumerated() {
        var sum: Float = 0
        vDSP_dotpr(power, 1, f, 1, &sum, vDSP_Length(min(power.count, f.count)))
        melRow[m] = log(max(sum, 1e-10))
      }
      feats.append(melRow)
    }
    return feats
  }

  private static func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
  private static func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

  private static func kaldiMelFilterbank(sampleRate: Float, nfft: Int, nMels: Int, lowHz: Float, highHz: Float) -> [[Float]] {
    let nyquist = 0.5 * sampleRate
    let highFreq = (highHz > 0) ? highHz : (nyquist + highHz)
    let fftBinWidth = sampleRate / Float(nfft)
    let (melLow, melHigh) = (hzToMel(lowHz), hzToMel(highFreq))
    let melDelta = (melHigh - melLow) / Float(nMels + 1)
    let numFFTBins = nfft / 2 + 1

    return (0..<nMels).map { bin in
      let leftMel = melLow + Float(bin) * melDelta
      let centerMel = melLow + Float(bin + 1) * melDelta
      let rightMel = melLow + Float(bin + 2) * melDelta

      return (0..<numFFTBins).map { i in
        let mel = hzToMel(fftBinWidth * Float(i))
        if mel > leftMel && mel < rightMel {
          return mel <= centerMel ? (mel - leftMel) / (centerMel - leftMel) : (rightMel - mel) / (rightMel - centerMel)
        }
        return 0.0
      }
    }
  }

  static func applyLFR(feat: [[Float]], lfrM: Int, lfrN: Int) -> [[Float]] {
    guard !feat.isEmpty else { return [] }
    let (T, leftPad) = (feat.count, (lfrM - 1) / 2)
    let padded = Array(repeating: feat[0], count: leftPad) + feat
    
    return (0..<Int(ceil(Double(T) / Double(lfrN)))).map { i in
      let start = i * lfrN
      guard start < padded.count else { return [] } // Should not happen with ceil logic but safe
      return (0..<lfrM).flatMap { padded[min(start + $0, padded.count - 1)] }
    }
  }

  static func applyCMVN(feat: [[Float]], cmvn: CMVN) -> [[Float]] {
    guard !feat.isEmpty else { return [] }
    return feat.map { frame in
      zip(frame, zip(cmvn.means, cmvn.vars)).map { ($0 + $1.0) * $1.1 }
    }
  }

  // MARK: - CoreML arrays

  static func makeSpeechMultiArray(_ feat: [[Float]]) throws -> MLMultiArray {
    let T = feat.count
    let F = 560
    let arr = try MLMultiArray(shape: [1, NSNumber(value: T), NSNumber(value: F)], dataType: .float32)

    let strides = arr.strides.map { $0.intValue }
    let ptr = arr.dataPointer.bindMemory(to: Float32.self, capacity: arr.count)

    for t in 0..<T {
      let frame = feat[t]
      for f in 0..<F {
        let index = 0 * strides[0] + t * strides[1] + f * strides[2]
        ptr[index] = (f < frame.count) ? frame[f] : 0
      }
    }

    return arr
  }
}

// MARK: - Postprocessing (Decoding)

fileprivate struct SenseVoicePostprocess {
  
  static func greedyCTCDecode(logits: MLMultiArray, length: Int, blankID: Int) -> [Int] {
    let shape = logits.shape.map { $0.intValue }
    guard shape.count == 3 else { return [] }
    let (T, V, strides) = (min(length, shape[1]), shape[2], logits.strides.map { $0.intValue })
    let ptr = logits.dataPointer.bindMemory(to: Float16.self, capacity: logits.count)
    
    // Argmax per frame
    let raw = (0..<T).map { t in
      var (best, bestVal) = (0, -Float16.greatestFiniteMagnitude)
      for v in 0..<V {
        let val = ptr[t * strides[1] + v * strides[2]] // Assuming batch=0
        if val > bestVal { (best, bestVal) = (v, val) }
      }
      return best
    }

    // Collapse repeats & filter blanks
    return raw.reduce(into: [Int]()) { res, id in
      if id != blankID && id != res.last { res.append(id) }
    }
  }

  static func postprocess(_ text: String) -> String {
    let stripped = text.replacingOccurrences(of: #"<\|[^>]+\|>"#, with: "", options: .regularExpression)
    return stripped.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty && $0 != "\u{0000}" }
      .joined(separator: " ")
  }

  static func mapLanguageAndTextnorm(language: String?, useITN: Bool) -> (Int32, Int32) {
    let lang = (language ?? "auto").lowercased()
    let lid: Int32 = switch true {
      case lang.hasPrefix("zh"): 3
      case lang.hasPrefix("en"): 4
      case lang.hasPrefix("yue") || lang.hasPrefix("yu"): 7
      case lang.hasPrefix("ja"): 11
      case lang.hasPrefix("ko"): 12
      default: 0
    }
    return (lid, useITN ? 14 : 15)
  }
}

// MARK: - SenseVoiceClient

actor SenseVoiceClient {
  enum Error: LocalizedError {
    case unsupportedVariant(String)
    case missingCoreMLAsset(String)
    case invalidCMVN

    var errorDescription: String? {
      switch self {
      case let .unsupportedVariant(name):
        return "Unsupported SenseVoice variant: \(name)"
      case let .missingCoreMLAsset(message):
        return message
      case .invalidCMVN:
        return "Invalid SenseVoice CMVN (am.mvn) file."
      }
    }
  }

  private let modelsBaseFolder: URL

  private var model: MLModel?
  private var tokenizer: SentencepieceTokenizer?
  private var cmvn: SenseVoicePreprocess.CMVN?
  private var currentVariant: SenseVoiceModel?

  private var vadManager: VadManager?

  init(modelsBaseFolder: URL) {
    self.modelsBaseFolder = modelsBaseFolder
  }


  func unload() {
    model = nil
    tokenizer = nil
    cmvn = nil
    currentVariant = nil
    vadManager = nil
  }

  func releaseVad() {
    vadManager = nil
  }

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard let variant = SenseVoiceModel(rawValue: modelName) else { return false }
    if currentVariant == variant, model != nil, tokenizer != nil, cmvn != nil { return true }
    return requiredAssetPaths(for: variant).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
  }

  func deleteCaches(modelName: String) async throws {
    guard let variant = SenseVoiceModel(rawValue: modelName) else { return }
    let dir = modelDirectory(for: variant)
    if FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.removeItem(at: dir)
    }
    // Also release Silero VAD (CoreML/Metal resources) so it doesn't stay resident.
    vadManager = nil
    if currentVariant == variant {
      unload()
    }
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = SenseVoiceModel(rawValue: modelName) else { throw Error.unsupportedVariant(modelName) }
    if currentVariant == variant, model != nil, tokenizer != nil, cmvn != nil { return }

    model = nil
    tokenizer = nil
    cmvn = nil
    currentVariant = nil

    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    try FileManager.default.createDirectory(at: modelDirectory(for: variant), withIntermediateDirectories: true)

    // 1) Ensure tokenizer/config/cmvn (fast; from ModelScope)
    try await ensureRepoAssets(variant: variant)
    p.completedUnitCount = 20
    progress(p)

    // 2) Ensure CoreML compiled model
    try await ensureCoreMLModel(variant: variant) { fraction in
      p.completedUnitCount = 20 + Int64(fraction * 50)
      progress(p)
    }
    p.completedUnitCount = 70
    progress(p)

    // 3) Load everything into memory
    let modelURL = compiledModelURL(for: variant)
    let config = MLModelConfiguration()
    config.computeUnits = .all
    self.model = try MLModel(contentsOf: modelURL, configuration: config)

    let tokenizerURL = tokenizerURL(for: variant)
    // SenseVoice CoreML emits SentencePiece IDs directly (CTC blank=0), so we must not apply HF-style +1 token offset.
    self.tokenizer = try SentencepieceTokenizer(modelPath: tokenizerURL.path, tokenOffset: 0)

    self.cmvn = try loadCMVN(from: cmvnURL(for: variant))

    self.currentVariant = variant
    p.completedUnitCount = 100
    progress(p)
  }

  func transcribe(_ url: URL, language: String?, useITN: Bool) async throws -> String {
    guard let model, let tokenizer, let cmvn else {
      throw NSError(domain: "SenseVoice", code: -1, userInfo: [NSLocalizedDescriptionKey: "SenseVoice not initialized"]) 
    }

    let waveform = try await SenseVoicePreprocess.loadAudioMono16k(url: url)

    func mergeWordOverlaps(_ parts: [String]) -> String {
      guard var outWords = parts.first?.split(whereSeparator: { $0.isWhitespace }).map(String.init), !outWords.isEmpty else {
        return ""
      }

      for part in parts.dropFirst() {
        let words = part.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { continue }

        let maxK = min(12, outWords.count, words.count)
        var kFound = 0
        if maxK > 0 {
          for k in stride(from: maxK, through: 1, by: -1) {
            let suffix = outWords.suffix(k)
            let prefix = words.prefix(k)
            if zip(suffix, prefix).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) {
              kFound = k
              break
            }
          }
        }

        outWords.reserveCapacity(outWords.count + words.count)
        outWords.append(contentsOf: words.dropFirst(kFound))
      }

      return SenseVoicePostprocess.postprocess(outWords.joined(separator: " "))
    }

    func transcribeWaveform(_ waveform: ArraySlice<Float>, chunkIndex: Int?) async throws -> String {
      guard !waveform.isEmpty else { return "" }

      let fbank = try SenseVoicePreprocess.computeFbank(waveform: waveform)
      let lfr = SenseVoicePreprocess.applyLFR(feat: fbank, lfrM: 7, lfrN: 6)
      let norm = SenseVoicePreprocess.applyCMVN(feat: lfr, cmvn: cmvn)
      guard !norm.isEmpty else { return "" }

      let speech = try SenseVoicePreprocess.makeSpeechMultiArray(norm)
      let speechLengths = try MLMultiArray(shape: [1], dataType: .int32)
      speechLengths[0] = NSNumber(value: Int32(norm.count))

      let (langID, textnormID) = SenseVoicePostprocess.mapLanguageAndTextnorm(language: language, useITN: useITN)

      let lang = try MLMultiArray(shape: [1], dataType: .int32)
      lang[0] = NSNumber(value: langID)
      let textnorm = try MLMultiArray(shape: [1], dataType: .int32)
      textnorm[0] = NSNumber(value: textnormID)

      let provider = try MLDictionaryFeatureProvider(dictionary: [
        "speech": MLFeatureValue(multiArray: speech),
        "speech_lengths": MLFeatureValue(multiArray: speechLengths),
        "language": MLFeatureValue(multiArray: lang),
        "textnorm": MLFeatureValue(multiArray: textnorm),
      ])

      let out = try await model.prediction(from: provider)
      guard
        let logits = out.featureValue(for: "ctc_logits")?.multiArrayValue,
        let lens = out.featureValue(for: "encoder_out_lens")?.multiArrayValue
      else {
        throw NSError(domain: "SenseVoice", code: -2, userInfo: [NSLocalizedDescriptionKey: "SenseVoice output missing"])
      }

      let logitLen = (lens.count > 0 ? lens[0].intValue : 0)

      let tokenIDs = SenseVoicePostprocess.greedyCTCDecode(logits: logits, length: logitLen, blankID: 0)

      var text = try tokenizer.decode(tokenIDs)
      text = SenseVoicePostprocess.postprocess(text)
      return text
    }

    // SenseVoice upstream "direct inference" paths often assume short audio.
    // For long recordings, use FluidAudio's Silero VAD segmentation to keep each chunk within a stable duration.
    let sampleRate = 16_000
    let maxSinglePassSeconds: Double = 25
    let maxSinglePassSamples = Int(maxSinglePassSeconds * Double(sampleRate))

    if waveform.count <= maxSinglePassSamples {
      return try await transcribeWaveform(waveform[...], chunkIndex: nil)
    }

    func getVad() async throws -> VadManager {
      if let vadManager { return vadManager }
      // Lazily initialize so short clips do not pay the model load/download cost.
      let m = try await VadManager(config: .default)
      vadManager = m
      return m
    }

    var seg = VadSegmentationConfig.default
    // Keep segments well within typical on-device ASR limits.
    seg.maxSpeechDuration = 14.0
    seg.speechPadding = 0.12

    let vad = try await getVad()
    let segments = try await vad.segmentSpeech(waveform, config: seg)

    var parts: [String] = []
    parts.reserveCapacity(segments.count)

    for (i, s) in segments.enumerated() {
      let a = max(0, min(s.startSample(sampleRate: sampleRate), waveform.count))
      let b = max(a, min(s.endSample(sampleRate: sampleRate), waveform.count))
      if b <= a { continue }
      let chunk = waveform[a..<b]
      let text = try await transcribeWaveform(chunk, chunkIndex: i)
      if !text.isEmpty { parts.append(text) }
    }

    return mergeWordOverlaps(parts)
  }

  // MARK: - Paths

  private func modelDirectory(for variant: SenseVoiceModel) -> URL {
    modelsBaseFolder
      .appendingPathComponent("sensevoice", isDirectory: true)
      .appendingPathComponent("\(variant.identifier)", isDirectory: true)
  }

  private func compiledModelURL(for variant: SenseVoiceModel) -> URL {
    modelDirectory(for: variant).appendingPathComponent("SenseVoiceSmall.mlmodelc", isDirectory: true)
  }

  private func tokenizerURL(for variant: SenseVoiceModel) -> URL {
    modelDirectory(for: variant).appendingPathComponent("chn_jpn_yue_eng_ko_spectok.bpe.model")
  }

  private func configURL(for variant: SenseVoiceModel) -> URL {
    modelDirectory(for: variant).appendingPathComponent("config.yaml")
  }

  private func cmvnURL(for variant: SenseVoiceModel) -> URL {
    modelDirectory(for: variant).appendingPathComponent("am.mvn")
  }

  private func requiredAssetPaths(for variant: SenseVoiceModel) -> [URL] {
    [compiledModelURL(for: variant), tokenizerURL(for: variant), configURL(for: variant), cmvnURL(for: variant)]
  }

  // MARK: - Download / Prepare

  private func ensureRepoAssets(variant: SenseVoiceModel) async throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: tokenizerURL(for: variant).path) {
      try await downloadModelScopeFile("chn_jpn_yue_eng_ko_spectok.bpe.model", to: tokenizerURL(for: variant))
    }
    if !fm.fileExists(atPath: configURL(for: variant).path) {
      try await downloadModelScopeFile("config.yaml", to: configURL(for: variant))
    }
    if !fm.fileExists(atPath: cmvnURL(for: variant).path) {
      try await downloadModelScopeFile("am.mvn", to: cmvnURL(for: variant))
    }
  }

  private func downloadModelScopeFile(_ filePath: String, to dest: URL) async throws {
    // Public, unauthenticated file fetch endpoint.
    let urlString = "https://modelscope.cn/api/v1/models/iic/SenseVoiceSmall/repo?Revision=master&FilePath=\(filePath)"
    guard let url = URL(string: urlString) else {
      throw NSError(domain: "SenseVoice", code: -30, userInfo: [NSLocalizedDescriptionKey: "Invalid ModelScope URL for \(filePath)"])
    }

    let (tmp, _) = try await URLSession.shared.download(from: url)
    FileManager.default.removeItemIfExists(at: dest)
    try FileManager.default.moveItem(at: tmp, to: dest)
  }

  private func ensureCoreMLModel(variant: SenseVoiceModel, progress: ((Double) -> Void)? = nil) async throws {
    if FileManager.default.fileExists(atPath: compiledModelURL(for: variant).path) {
      return
    }

    // 1) Prefer downloading a precompiled .mlmodelc bundle (ideally zipped) from a configurable URL.
    if let coremlURL = ProcessInfo.processInfo.environment["HEX_SENSEVOICE_COREML_URL"].flatMap(URL.init(string:)) {
      try await fetchCoreML(from: coremlURL, into: compiledModelURL(for: variant), progress: progress)
      return
    }

    // 2) Default: Download from Hugging Face (mefengl/SenseVoiceSmall-coreml)
    // We currently only support the "small" variant hosted at this repo.
    guard let hfURL = URL(string: "https://huggingface.co/mefengl/SenseVoiceSmall-coreml/resolve/main/coreml/SenseVoiceSmall.mlmodelc.zip") else {
      throw Error.missingCoreMLAsset("Invalid Hugging Face URL for SenseVoice CoreML model")
    }
    try await fetchCoreML(from: hfURL, into: compiledModelURL(for: variant), progress: progress)
  }

  private func fetchCoreML(from url: URL, into destMLModelC: URL, progress: ((Double) -> Void)? = nil) async throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    if url.isFileURL {
      if url.pathExtension == "mlmodelc" {
        try copyDirectory(from: url, to: destMLModelC)
        return
      }
    }

    let downloaded: URL
    if url.isFileURL {
      let (loc, _) = try await URLSession.shared.download(from: url)
      downloaded = loc
    } else {
      downloaded = try await DownloadManager().download(url: url, progress: progress)
    }

    let zipURL = tmpDir.appendingPathComponent("model.zip")
    try fm.moveItem(at: downloaded, to: zipURL)

    // Unzip into tmp, then move the first .mlmodelc found.
    let unzipDir = tmpDir.appendingPathComponent("unzipped", isDirectory: true)
    try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
    try runProcess("/usr/bin/ditto", ["-x", "-k", zipURL.path, unzipDir.path])

    guard let mlmodelc = findFirstMLModelC(in: unzipDir) else {
      throw Error.missingCoreMLAsset("Downloaded archive did not contain a .mlmodelc bundle.")
    }
    try copyDirectory(from: mlmodelc, to: destMLModelC)
  }

  private func runProcess(_ executable: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args

    let pipe = Pipe()
    p.standardError = pipe
    p.standardOutput = pipe

    try p.run()
    p.waitUntilExit()

    if p.terminationStatus != 0 {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let msg = String(data: data, encoding: .utf8) ?? ""
      throw NSError(domain: "SenseVoice", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Process failed" : msg])
    }
  }

  private func findFirstMLModelC(in dir: URL) -> URL? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
    for case let u as URL in en {
      if u.pathExtension == "mlmodelc" { return u }
    }
    return nil
  }

  private func copyDirectory(from src: URL, to dst: URL) throws {
    let fm = FileManager.default
    fm.removeItemIfExists(at: dst)
    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: src, to: dst)
  }

  // MARK: - CMVN

  private func loadCMVN(from url: URL) throws -> SenseVoicePreprocess.CMVN {
    let text = try String(contentsOf: url, encoding: .utf8)
    var means: [Float] = []
    var vars: [Float] = []

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for i in lines.indices {
      let parts = lines[i].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard let first = parts.first else { continue }
      if first == "<AddShift>", i + 1 < lines.count {
        let parts2 = lines[i + 1].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if parts2.first == "<LearnRateCoef>", parts2.count >= 5 {
          let values = parts2[3..<(parts2.count - 1)]
          means = values.compactMap(Float.init)
        }
      } else if first == "<Rescale>", i + 1 < lines.count {
        let parts2 = lines[i + 1].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if parts2.first == "<LearnRateCoef>", parts2.count >= 5 {
          let values = parts2[3..<(parts2.count - 1)]
          vars = values.compactMap(Float.init)
        }
      }
    }

    guard means.count == 560, vars.count == 560 else { throw Error.invalidCMVN }
    return SenseVoicePreprocess.CMVN(means: means, vars: vars)
  }
}

// MARK: - Download Manager

private class DownloadManager: NSObject, URLSessionDownloadDelegate {
  private var continuation: CheckedContinuation<URL, Error>?
  private var progressHandler: ((Double) -> Void)?
  private let lock = NSLock()
  private var isDone = false

  func download(url: URL, progress: ((Double) -> Void)?) async throws -> URL {
    self.progressHandler = progress
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
      let task = session.downloadTask(with: url)
      task.resume()
      session.finishTasksAndInvalidate()
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    lock.lock()
    defer { lock.unlock() }
    if isDone { return }
    isDone = true
    
    // Move to a safe temp location because 'location' is deleted upon return
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.moveItem(at: location, to: tmp)
      continuation?.resume(returning: tmp)
    } catch {
      continuation?.resume(throwing: error)
    }
    continuation = nil
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    if totalBytesExpectedToWrite > 0 {
      let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
      progressHandler?(p)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    if isDone { return }
    isDone = true
    
    if let error = error {
      continuation?.resume(throwing: error)
    } else {
      // Should have been handled by didFinishDownloadingTo, but just in case
      continuation?.resume(throwing: URLError(.unknown))
    }
    continuation = nil
  }
}
