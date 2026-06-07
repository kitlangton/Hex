import AVFoundation
import Foundation
import HexCore

private final class FloatRingBuffer {
  private let lock = NSLock()
  private var buffer: [Float]
  private var writeIndex = 0
  private var validSampleCount = 0

  init(capacity: Int) {
    buffer = Array(repeating: 0, count: max(1, capacity))
  }

  func append(_ samples: UnsafeBufferPointer<Float>) {
    guard !samples.isEmpty else { return }

    lock.lock()
    defer { lock.unlock() }

    for sample in samples {
      buffer[writeIndex] = sample
      writeIndex = (writeIndex + 1) % buffer.count
    }

    validSampleCount = min(buffer.count, validSampleCount + samples.count)
  }

  func recentSamples(count requestedCount: Int) -> [Float] {
    lock.lock()
    defer { lock.unlock() }

    let sampleCount = min(max(0, requestedCount), validSampleCount)
    guard sampleCount > 0 else { return [] }

    let startIndex = (writeIndex - sampleCount + buffer.count) % buffer.count
    if startIndex + sampleCount <= buffer.count {
      return Array(buffer[startIndex ..< startIndex + sampleCount])
    }

    let firstChunk = Array(buffer[startIndex ..< buffer.count])
    let secondChunk = Array(buffer[0 ..< (sampleCount - firstChunk.count)])
    return firstChunk + secondChunk
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }

    writeIndex = 0
    validSampleCount = 0
  }

  func fillDuration(sampleRate: Double) -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    guard sampleRate > 0 else { return 0 }
    return Double(validSampleCount) / sampleRate
  }
}

private struct SuperFastCaptureConstants {
  static let sampleRate: Double = 16_000
  static let ringBufferDuration: TimeInterval = 1.0
  static let defaultPreRollDuration: TimeInterval = 0.45
  /// Short ring-buffer seed for live preview only (not the saved recording).
  static let previewPreRollDuration: TimeInterval = 0.12
  static let previewMinimumDuration: TimeInterval = 0.12
  /// Stop accumulating in-memory preview PCM beyond this duration; recording to file continues.
  static let previewMaximumDuration: TimeInterval = 600
  static let captureReadyMinimumRingDuration: TimeInterval = 0.15
  static let captureReadyPrewarmRingDuration: TimeInterval = 0.20
  static let captureWarmUpTimeout: TimeInterval = 1.5
  static let captureReadyTimeout: TimeInterval = 2.5
  static let tapBufferSize: AVAudioFrameCount = 4_096
  static let fallbackStopGracePeriod: TimeInterval = 0.05
  static let minimumStopGracePeriod: TimeInterval = 0.02
  static let maximumStopGracePeriod: TimeInterval = 0.08
  static let stopGraceSafetyMargin: TimeInterval = 0.008
  static let callbackTimingWindowSize = 8
  static let configChangeGracePeriod: TimeInterval = 2.0
  static let startRetryCount = 3
  static let startRetryDelay: TimeInterval = 0.15
}

enum CaptureRecordingMode: String {
  case standard = "standard"
  case superFast = "super-fast"

  var preRollDuration: TimeInterval {
    switch self {
    case .standard:
      0
    case .superFast:
      SuperFastCaptureConstants.defaultPreRollDuration
    }
  }

  var keepsWarmBuffer: Bool {
    self == .superFast
  }
}

final class SuperFastCaptureController {
  enum Readiness {
    static let minimumRingDuration = SuperFastCaptureConstants.captureReadyMinimumRingDuration
    static let prewarmRingDuration = SuperFastCaptureConstants.captureReadyPrewarmRingDuration
    static let warmUpTimeout = SuperFastCaptureConstants.captureWarmUpTimeout
    static let readyTimeout = SuperFastCaptureConstants.captureReadyTimeout
  }

  struct StopTimingEstimate {
    let gracePeriod: TimeInterval
    let callbackInterval: TimeInterval
    let bufferDuration: TimeInterval
  }

  private struct ActiveRecording {
    let url: URL
    let file: AVAudioFile
    let requestedAt: Date
    let prependedDuration: TimeInterval
    var didLogFirstBuffer: Bool
  }

  private let logger = HexLog.recording
  private let processingQueue = DispatchQueue(label: "com.kitlangton.Hex.SuperFastCapture")
  private let meterContinuation: AsyncStream<Meter>.Continuation
  private let liveAudioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
  private let ringBuffer = FloatRingBuffer(
    capacity: Int(SuperFastCaptureConstants.sampleRate * SuperFastCaptureConstants.ringBufferDuration)
  )
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: SuperFastCaptureConstants.sampleRate,
    channels: 1,
    interleaved: false
  )!

  private var engine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private var configurationChangeObserver: NSObjectProtocol?
  private var activeRecording: ActiveRecording?
  private var isLiveMonitoring = false
  private var didLogFirstLiveBuffer = false
  private var keepWarmBuffer = false
  private var lastProcessedBufferAt: Date?
  private var recentCallbackIntervals: [TimeInterval] = []
  private var recentBufferDurations: [TimeInterval] = []
  private var previewSamples: [Float] = []
  private var didLogPreviewSampleCap = false
  private var lastArmedAt: Date?
  private let onEngineConfigurationChange: @Sendable () -> Void

  init(
    meterContinuation: AsyncStream<Meter>.Continuation,
    liveAudioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation? = nil,
    onEngineConfigurationChange: @escaping @Sendable () -> Void
  ) {
    self.meterContinuation = meterContinuation
    self.liveAudioContinuation = liveAudioContinuation
    self.onEngineConfigurationChange = onEngineConfigurationChange
  }

  deinit {
    stop()
  }

  var isRunning: Bool {
    engine?.isRunning == true
  }

  var isRecording: Bool {
    processingQueue.sync { activeRecording != nil }
  }

  var currentRecordingURL: URL? {
    processingQueue.sync { activeRecording?.url }
  }

  var previewCaptureDuration: TimeInterval {
    processingQueue.sync {
      guard activeRecording != nil || isLiveMonitoring else { return 0 }
      return Double(previewSamples.count) / SuperFastCaptureConstants.sampleRate
    }
  }

  /// Writes accumulated PCM from the active recording to a standalone WAV for live preview.
  /// In-progress capture files are not readable until finalized, so preview uses memory instead.
  func makePreviewSnapshotURL(
    minimumDuration: TimeInterval = SuperFastCaptureConstants.previewMinimumDuration
  ) -> URL? {
    let snapshotData = processingQueue.sync { () -> (samples: [Float], duration: TimeInterval)? in
      guard activeRecording != nil || isLiveMonitoring else { return nil }

      let duration = Double(previewSamples.count) / SuperFastCaptureConstants.sampleRate
      guard duration >= minimumDuration else { return nil }
      return (previewSamples, duration)
    }

    guard let snapshotData else { return nil }
    let (samples, duration) = snapshotData

    let snapshotURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("hex-preview-\(UUID().uuidString).wav")

    do {
      if FileManager.default.fileExists(atPath: snapshotURL.path) {
        try FileManager.default.removeItem(at: snapshotURL)
      }

      let file = try AVAudioFile(
        forWriting: snapshotURL,
        settings: [
          AVFormatIDKey: Int(kAudioFormatLinearPCM),
          AVSampleRateKey: SuperFastCaptureConstants.sampleRate,
          AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: true,
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
      try write(samples: samples, to: file)
      logger.debug(
        "Preview snapshot written duration=\(String(format: "%.3f", duration))s samples=\(samples.count) file=\(snapshotURL.lastPathComponent)"
      )
      return snapshotURL
    } catch {
      logger.debug("Failed to write preview snapshot: \(error.localizedDescription)")
      return nil
    }
  }

  var stopTimingEstimate: StopTimingEstimate {
    processingQueue.sync {
      let callbackInterval = recentCallbackIntervals.max() ?? 0
      let bufferDuration = recentBufferDurations.max() ?? 0
      let observedCadence = max(callbackInterval, bufferDuration)
      let gracePeriod = min(
        max(
          observedCadence > 0
            ? observedCadence + SuperFastCaptureConstants.stopGraceSafetyMargin
            : SuperFastCaptureConstants.fallbackStopGracePeriod,
          SuperFastCaptureConstants.minimumStopGracePeriod
        ),
        SuperFastCaptureConstants.maximumStopGracePeriod
      )
      return StopTimingEstimate(
        gracePeriod: gracePeriod,
        callbackInterval: callbackInterval,
        bufferDuration: bufferDuration
      )
    }
  }

  var ringBufferFillDuration: TimeInterval {
    processingQueue.sync {
      ringBuffer.fillDuration(sampleRate: SuperFastCaptureConstants.sampleRate)
    }
  }

  /// Waits until the capture engine is running and the warm ring buffer has enough audio
  /// to seed the recording pre-roll (critical for the first hotkey press after launch).
  func waitUntilReady(
    minimumRingDuration: TimeInterval = SuperFastCaptureConstants.captureReadyMinimumRingDuration,
    timeout: TimeInterval = SuperFastCaptureConstants.captureReadyTimeout
  ) async -> Bool {
    guard minimumRingDuration > 0 else {
      return processingQueue.sync { engine?.isRunning == true }
    }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if Task.isCancelled { return false }

      let isReady = processingQueue.sync { () -> Bool in
        guard engine?.isRunning == true else { return false }
        return ringBuffer.fillDuration(sampleRate: SuperFastCaptureConstants.sampleRate) >= minimumRingDuration
      }
      if isReady { return true }

      try? await Task.sleep(for: .milliseconds(25))
    }

    return processingQueue.sync { engine?.isRunning == true }
  }

  func startIfNeeded(reason: String = "unknown", keepWarmBuffer: Bool = false) throws {
    let didDisableWarmBuffer = self.keepWarmBuffer && !keepWarmBuffer
    self.keepWarmBuffer = keepWarmBuffer
    if didDisableWarmBuffer {
      processingQueue.sync {
        if activeRecording == nil {
          ringBuffer.clear()
        }
      }
    }

    if engine?.isRunning == true {
      logger.debug("Capture engine already armed reason=\(reason)")
      return
    }

    var lastError: Error?
    for attempt in 0 ..< SuperFastCaptureConstants.startRetryCount {
      stop(reason: attempt == 0 ? "restart-before-arm" : "restart-before-arm-retry-\(attempt + 1)")

      do {
        try startEngineOnce(reason: reason, attempt: attempt + 1)
        lastArmedAt = Date()
        return
      } catch {
        lastError = error
        guard isRecoverableStartError(error), attempt + 1 < SuperFastCaptureConstants.startRetryCount else {
          throw error
        }
        logger.notice(
          "Capture engine start failed, retrying reason=\(reason) attempt=\(attempt + 2)/\(SuperFastCaptureConstants.startRetryCount) error=\(error.localizedDescription)"
        )
        Thread.sleep(forTimeInterval: SuperFastCaptureConstants.startRetryDelay * Double(attempt + 1))
      }
    }

    if let lastError {
      throw lastError
    }
  }

  private func startEngineOnce(reason: String, attempt: Int) throws {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    engine.prepare()
    let tapFormat = inputNode.outputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
      throw NSError(
        domain: "SuperFastCapture",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create the capture engine audio converter."]
      )
    }
    if tapFormat.channelCount > 1 {
      converter.channelMap = [NSNumber(value: 0)]
    }

    self.converter = converter

    inputNode.installTap(onBus: 0, bufferSize: SuperFastCaptureConstants.tapBufferSize, format: tapFormat) {
      [weak self] buffer, _ in
      self?.enqueue(buffer)
    }

    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      self.converter = nil
      throw error
    }
    self.engine = engine
    configurationChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      self?.handleConfigurationChange()
    }
    logger.notice(
      "Capture engine armed reason=\(reason) attempt=\(attempt) tapSampleRate=\(String(format: "%.0f", tapFormat.sampleRate))Hz channels=\(tapFormat.channelCount) ringBuffer=\(String(format: "%.2f", SuperFastCaptureConstants.ringBufferDuration))s defaultPreRoll=\(String(format: "%.2f", SuperFastCaptureConstants.defaultPreRollDuration))s"
    )
  }

  private func isRecoverableStartError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "com.apple.coreaudio.avfaudio" && nsError.code == -10868
  }

  func stop(reason: String = "unknown") {
    if engine != nil {
      logger.notice("Capture engine stopped reason=\(reason)")
    }
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    if let configurationChangeObserver {
      NotificationCenter.default.removeObserver(configurationChangeObserver)
      self.configurationChangeObserver = nil
    }
    engine?.stop()
    engine = nil
    converter = nil

    processingQueue.sync {
      activeRecording = nil
      isLiveMonitoring = false
      didLogFirstLiveBuffer = false
      ringBuffer.clear()
      lastProcessedBufferAt = nil
      recentCallbackIntervals.removeAll(keepingCapacity: false)
      recentBufferDurations.removeAll(keepingCapacity: false)
    }
  }

  private func handleConfigurationChange() {
    logger.notice("Capture engine configuration changed")

    let isRecording = processingQueue.sync { activeRecording != nil }
    if isRecording {
      onEngineConfigurationChange()
      return
    }

    if let lastArmedAt,
       Date().timeIntervalSince(lastArmedAt) < SuperFastCaptureConstants.configChangeGracePeriod
    {
      logger.debug(
        "Re-arming capture engine after config change within grace period armedAgo=\(String(format: "%.3f", Date().timeIntervalSince(lastArmedAt)))s"
      )
      do {
        try startIfNeeded(reason: "config-change-rearm", keepWarmBuffer: keepWarmBuffer)
      } catch {
        logger.error("Capture engine re-arm after config change failed: \(error.localizedDescription)")
      }
      return
    }

    onEngineConfigurationChange()
  }

  func beginRecording(to url: URL, requestedAt: Date = Date(), mode: CaptureRecordingMode) throws {
    try startIfNeeded(reason: "begin-recording", keepWarmBuffer: mode.keepsWarmBuffer)

    var startError: Error?
    processingQueue.sync {
      do {
        let file = try AVAudioFile(
          forWriting: url,
          settings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: SuperFastCaptureConstants.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
          ],
          commonFormat: .pcmFormatFloat32,
          interleaved: false
        )

        let preRollDuration = mode.preRollDuration
        let preRollFrameCount = Int(preRollDuration * SuperFastCaptureConstants.sampleRate)
        let preRollSamples = ringBuffer.recentSamples(count: preRollFrameCount)
        let prependedDuration = Double(preRollSamples.count) / SuperFastCaptureConstants.sampleRate
        if !preRollSamples.isEmpty {
          try write(samples: preRollSamples, to: file)
          if let liveAudioContinuation,
             let preRollBuffer = makePCMBuffer(from: preRollSamples)
          {
            liveAudioContinuation.yield(preRollBuffer)
          }
        }

        // Live preview uses post-hotkey audio plus a short ring-buffer seed so the
        // first words aren't missed, without the full pre-roll that caused ghost tokens.
        let previewPreRollFrameCount = Int(
          SuperFastCaptureConstants.previewPreRollDuration * SuperFastCaptureConstants.sampleRate
        )
        previewSamples = ringBuffer.recentSamples(count: previewPreRollFrameCount)
        didLogPreviewSampleCap = false

        logger.notice(
          "Capture engine recording file opened prepended=\(String(format: "%.3f", prependedDuration))s requestedPreRoll=\(String(format: "%.3f", preRollDuration))s"
        )
        activeRecording = ActiveRecording(
          url: url,
          file: file,
          requestedAt: requestedAt,
          prependedDuration: prependedDuration,
          didLogFirstBuffer: false
        )
      } catch {
        startError = error
      }
    }

    if let startError {
      throw startError
    }
  }

  func beginLiveMonitoring() throws {
    try startIfNeeded(reason: "begin-live-monitoring", keepWarmBuffer: false)
    processingQueue.sync {
      isLiveMonitoring = true
      didLogFirstLiveBuffer = false
      previewSamples.removeAll(keepingCapacity: true)
      didLogPreviewSampleCap = false
    }
    logger.notice("Capture engine live monitoring started")
  }

  func endLiveMonitoring() {
    processingQueue.sync {
      isLiveMonitoring = false
    }
    logger.notice("Capture engine live monitoring stopped")
  }

  func finishRecording(clearBuffer: Bool = true) -> URL? {
    processingQueue.sync {
      let url = activeRecording?.url
      activeRecording = nil
      previewSamples.removeAll(keepingCapacity: true)
      didLogPreviewSampleCap = false
      if clearBuffer {
        ringBuffer.clear()
      }
      return url
    }
  }

  func clearWarmBuffer() {
    processingQueue.sync {
      guard activeRecording == nil else { return }
      ringBuffer.clear()
    }
  }

  private func enqueue(_ buffer: AVAudioPCMBuffer) {
    guard let copy = clone(buffer) else { return }
    processingQueue.async { [weak self] in
      self?.process(copy)
    }
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    let now = Date()
    if let lastProcessedBufferAt {
      appendRecentMetric(now.timeIntervalSince(lastProcessedBufferAt), to: &recentCallbackIntervals)
    }
    lastProcessedBufferAt = now
    appendRecentMetric(Double(buffer.frameLength) / buffer.format.sampleRate, to: &recentBufferDurations)

    guard let converted = convert(buffer),
          converted.frameLength > 0,
          let samples = converted.floatChannelData?[0]
    else {
      return
    }

    let sampleCount = Int(converted.frameLength)
    if keepWarmBuffer, activeRecording == nil {
      ringBuffer.append(UnsafeBufferPointer(start: samples, count: sampleCount))
    }

    if activeRecording != nil {
      meterContinuation.yield(meter(for: samples, count: sampleCount))
    }

    if activeRecording != nil || isLiveMonitoring {
      if let liveAudioContinuation, let liveBuffer = clone(converted) {
        if !didLogFirstLiveBuffer {
          didLogFirstLiveBuffer = true
          logger.notice("Capture engine yielding first live audio buffer frames=\(liveBuffer.frameLength)")
        }
        liveAudioContinuation.yield(liveBuffer)
      }
    }

    if activeRecording != nil || isLiveMonitoring {
      let maxPreviewSamples = Int(
        SuperFastCaptureConstants.previewMaximumDuration * SuperFastCaptureConstants.sampleRate
      )
      if previewSamples.count < maxPreviewSamples {
        let remaining = maxPreviewSamples - previewSamples.count
        let appendCount = min(sampleCount, remaining)
        if appendCount > 0 {
          previewSamples.append(
            contentsOf: UnsafeBufferPointer(start: samples, count: appendCount)
          )
        }
        if appendCount < sampleCount, !didLogPreviewSampleCap {
          didLogPreviewSampleCap = true
          logger.notice(
            "Live preview in-memory buffer capped at \(String(format: "%.0f", SuperFastCaptureConstants.previewMaximumDuration))s; recording continues, final transcription unaffected"
          )
        }
      }
    }

    guard var recording = activeRecording else { return }
    if !recording.didLogFirstBuffer {
      let timeToFirstBuffer = Date().timeIntervalSince(recording.requestedAt)
      logger.notice(
        "Capture engine first buffer latency=\(String(format: "%.3f", timeToFirstBuffer))s prepended=\(String(format: "%.3f", recording.prependedDuration))s frames=\(sampleCount)"
      )
      recording.didLogFirstBuffer = true
      activeRecording = recording
    }

    do {
      try recording.file.write(from: converted)
    } catch {
      logger.error("Failed to write capture engine audio: \(error.localizedDescription)")
      activeRecording = nil
      previewSamples.removeAll(keepingCapacity: true)
      didLogPreviewSampleCap = false
    }
  }

  private func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let converter else { return nil }

    let sampleRateRatio = targetFormat.sampleRate / inputBuffer.format.sampleRate
    let frameCapacity = AVAudioFrameCount(
      max(1, (Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
    )

    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
      return nil
    }

    var error: NSError?
    var consumedInput = false
    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if consumedInput {
        outStatus.pointee = .noDataNow
        return nil
      }

      consumedInput = true
      outStatus.pointee = .haveData
      return inputBuffer
    }

    if let error {
      logger.error("Failed to convert capture engine audio: \(error.localizedDescription)")
      return nil
    }

    switch status {
    case .haveData, .inputRanDry, .endOfStream:
      return outputBuffer.frameLength > 0 ? outputBuffer : nil
    case .error:
      return nil
    @unknown default:
      return nil
    }
  }

  private func write(samples: [Float], to file: AVAudioFile) throws {
    guard !samples.isEmpty,
          let buffer = makePCMBuffer(from: samples)
    else {
      return
    }

    try file.write(from: buffer)
  }

  private func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
          let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)),
          let channelData = buffer.floatChannelData?[0]
    else {
      return nil
    }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { sampleBuffer in
      guard let baseAddress = sampleBuffer.baseAddress else { return }
      channelData.update(from: baseAddress, count: sampleBuffer.count)
    }
    return buffer
  }

  private func meter(for samples: UnsafePointer<Float>, count: Int) -> Meter {
    guard count > 0 else {
      return Meter(averagePower: 0, peakPower: 0)
    }

    var sumOfSquares: Float = 0
    var peak: Float = 0
    for index in 0 ..< count {
      let sample = samples[index]
      let magnitude = abs(sample)
      sumOfSquares += sample * sample
      peak = max(peak, magnitude)
    }

    let rms = sqrt(sumOfSquares / Float(count))
    return Meter(averagePower: Double(rms), peakPower: Double(peak))
  }

  private func clone(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
      return nil
    }

    copy.frameLength = buffer.frameLength

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in sourceBuffers.indices {
      let source = sourceBuffers[index]
      let destination = destinationBuffers[index]
      guard let sourceData = source.mData, let destinationData = destination.mData else { continue }
      memcpy(destinationData, sourceData, Int(source.mDataByteSize))
      destinationBuffers[index].mDataByteSize = source.mDataByteSize
    }

    return copy
  }

  private func appendRecentMetric(_ value: TimeInterval, to metrics: inout [TimeInterval]) {
    guard value.isFinite, value > 0 else { return }
    metrics.append(value)
    if metrics.count > SuperFastCaptureConstants.callbackTimingWindowSize {
      metrics.removeFirst(metrics.count - SuperFastCaptureConstants.callbackTimingWindowSize)
    }
  }
}
