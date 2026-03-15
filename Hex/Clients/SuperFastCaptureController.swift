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

    buffer = Array(repeating: 0, count: buffer.count)
    writeIndex = 0
    validSampleCount = 0
  }
}

private struct SuperFastCaptureConstants {
  static let sampleRate: Double = 16_000
  static let ringBufferDuration: TimeInterval = 2.0
  static let preRollDuration: TimeInterval = 0.75
  static let tapBufferSize: AVAudioFrameCount = 2_048
}

final class SuperFastCaptureController {
  private struct ActiveRecording {
    let url: URL
    let file: AVAudioFile
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

  init(meterContinuation: AsyncStream<Meter>.Continuation) {
    self.meterContinuation = meterContinuation
  }

  deinit {
    stop()
  }

  var isRunning: Bool {
    engine?.isRunning == true
  }

  func startIfNeeded() throws {
    if engine?.isRunning == true {
      return
    }

    stop()

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw NSError(
        domain: "SuperFastCapture",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create the super fast audio converter."]
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
      "Super fast capture armed sampleRate=\(String(format: "%.0f", inputFormat.sampleRate))Hz preRoll=\(String(format: "%.2f", SuperFastCaptureConstants.preRollDuration))s"
    )
  }

  func stop() {
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    engine?.stop()
    engine = nil
    converter = nil

    processingQueue.sync {
      activeRecording = nil
      ringBuffer.clear()
    }
  }

  func beginRecording(to url: URL) throws {
    try startIfNeeded()

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

        let preRollFrameCount = Int(
          SuperFastCaptureConstants.preRollDuration * SuperFastCaptureConstants.sampleRate
        )
        let preRollSamples = ringBuffer.recentSamples(count: preRollFrameCount)
        if !preRollSamples.isEmpty {
          try write(samples: preRollSamples, to: file)
        }

        activeRecording = ActiveRecording(url: url, file: file)
      } catch {
        startError = error
      }
    }

    if let startError {
      throw startError
    }
  }

  func finishRecording() -> URL? {
    processingQueue.sync {
      let url = activeRecording?.url
      activeRecording = nil
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
    guard let converted = convert(buffer),
          converted.frameLength > 0,
          let samples = converted.floatChannelData?[0]
    else {
      return
    }

    let sampleCount = Int(converted.frameLength)
    ringBuffer.append(UnsafeBufferPointer(start: samples, count: sampleCount))

    if activeRecording != nil {
      meterContinuation.yield(meter(for: samples, count: sampleCount))
    }

    guard let recording = activeRecording else { return }
    do {
      try recording.file.write(from: converted)
    } catch {
      logger.error("Failed to write super fast audio: \(error.localizedDescription)")
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
      logger.error("Failed to convert super fast audio: \(error.localizedDescription)")
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
}
