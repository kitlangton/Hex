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
}

private struct SuperFastCaptureConstants {
  static let sampleRate: Double = 16_000
  static let ringBufferDuration: TimeInterval = 1.0
  static let defaultPreRollDuration: TimeInterval = 0.45
  static let tapBufferSize: AVAudioFrameCount = 2_048
  static let fallbackStopGracePeriod: TimeInterval = 0.05
  static let minimumStopGracePeriod: TimeInterval = 0.02
  static let maximumStopGracePeriod: TimeInterval = 0.08
  static let stopGraceSafetyMargin: TimeInterval = 0.008
  static let callbackTimingWindowSize = 8
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
  private var activeRecording: ActiveRecording?
  private var keepWarmBuffer = false
  private var lastProcessedBufferAt: Date?
  private var recentCallbackIntervals: [TimeInterval] = []
  private var recentBufferDurations: [TimeInterval] = []

  init(meterContinuation: AsyncStream<Meter>.Continuation) {
    self.meterContinuation = meterContinuation
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

    stop(reason: "restart-before-arm")

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw NSError(
        domain: "SuperFastCapture",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create the capture engine audio converter."]
      )
    }

    self.converter = converter

    inputNode.installTap(onBus: 0, bufferSize: SuperFastCaptureConstants.tapBufferSize, format: inputFormat) {
      [weak self] buffer, _ in
      self?.enqueue(buffer)
    }

    engine.prepare()
    try engine.start()
    self.engine = engine
    logger.notice(
      "Capture engine armed reason=\(reason) sampleRate=\(String(format: "%.0f", inputFormat.sampleRate))Hz ringBuffer=\(String(format: "%.2f", SuperFastCaptureConstants.ringBufferDuration))s defaultPreRoll=\(String(format: "%.2f", SuperFastCaptureConstants.defaultPreRollDuration))s"
    )
  }

  func stop(reason: String = "unknown") {
    if engine != nil {
      logger.notice("Capture engine stopped reason=\(reason)")
    }
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    engine?.stop()
    engine = nil
    converter = nil

    processingQueue.sync {
      activeRecording = nil
      ringBuffer.clear()
      lastProcessedBufferAt = nil
      recentCallbackIntervals.removeAll(keepingCapacity: false)
      recentBufferDurations.removeAll(keepingCapacity: false)
    }
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
        }

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

  func finishRecording(clearBuffer: Bool = true) -> URL? {
    processingQueue.sync {
      let url = activeRecording?.url
      activeRecording = nil
      if clearBuffer {
        ringBuffer.clear()
      }
      return url
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
          let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)),
          let channelData = buffer.floatChannelData?[0]
    else {
      return
    }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { sampleBuffer in
      guard let baseAddress = sampleBuffer.baseAddress else { return }
      channelData.update(from: baseAddress, count: sampleBuffer.count)
    }
    try file.write(from: buffer)
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
