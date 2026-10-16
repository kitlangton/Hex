import AVFoundation
import Darwin
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
  static let stopDrainTimeout: TimeInterval = 2
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
  enum FinishRecordingResult {
    case captured(URL)
    case failed(RecordingFailure)
    case finalizing
    case idle
  }

  private struct PendingFinish {
    let targetHostTime: UInt64
    let postRollDuration: TimeInterval
    let clearBuffer: Bool
    let continuation: CheckedContinuation<FinishRecordingResult, Never>
  }

  private struct StopBoundary {
    let targetHostTime: UInt64
    var hasReachedTarget = false
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
  private let stopBoundaryLock = NSLock()
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
  private var configurationChangeObserver: NSObjectProtocol?
  private var activeRecording: ActiveRecording?
  private var captureGeneration = 0
  private var recordingFailure: RecordingFailure?
  private var keepWarmBuffer = false
  private var stopBoundary: StopBoundary?
  private var pendingFinish: PendingFinish?
  private var pendingFinishWaiters: [CheckedContinuation<Void, Never>] = []
  private var stopDrainTimeoutTask: Task<Void, Never>?
  private let onEngineConfigurationChange: @Sendable (Int) -> Void

  init(
    meterContinuation: AsyncStream<Meter>.Continuation,
    onEngineConfigurationChange: @escaping @Sendable (Int) -> Void
  ) {
    self.meterContinuation = meterContinuation
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

  func startIfNeeded(reason: String = "unknown", keepWarmBuffer: Bool = false) throws {
    processingQueue.sync {
      let didDisableWarmBuffer = self.keepWarmBuffer && !keepWarmBuffer
      self.keepWarmBuffer = keepWarmBuffer
      if didDisableWarmBuffer, activeRecording == nil {
        ringBuffer.clear()
      }
    }

    if engine?.isRunning == true {
      logger.debug("Capture engine already armed reason=\(reason)")
      return
    }

    stop(reason: "restart-before-arm")
    try armEngine(reason: reason)
  }

  /// Tears down and recreates the engine while keeping the active recording file open, so
  /// capture resumes onto the same file after a device/route change mid-recording
  /// (#251, #252, #218, #226). The ring buffer and active recording survive;
  /// only the engine, tap, and converter are rebuilt.
  func restartPreservingRecording(reason: String) throws {
    logger.notice("Restarting capture engine preserving active recording reason=\(reason)")
    detachEngine()
    try armEngine(reason: reason)
  }

  private func armEngine(reason: String) throws {
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
    if inputFormat.channelCount > 1 {
      converter.channelMap = [NSNumber(value: 0)]
    }

    let generation = processingQueue.sync {
      captureGeneration += 1
      self.converter = converter
      recordingFailure = nil
      return captureGeneration
    }

    inputNode.installTap(onBus: 0, bufferSize: SuperFastCaptureConstants.tapBufferSize, format: inputFormat) {
      [weak self] buffer, time in
      self?.enqueue(buffer, time: time, generation: generation)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      processingQueue.sync {
        captureGeneration += 1
        self.converter = nil
      }
      throw error
    }
    self.engine = engine
    configurationChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      self?.handleConfigurationChange(generation: generation)
    }
    logger.notice(
      "Capture engine armed reason=\(reason) sampleRate=\(String(format: "%.0f", inputFormat.sampleRate))Hz channels=\(inputFormat.channelCount) ringBuffer=\(String(format: "%.2f", SuperFastCaptureConstants.ringBufferDuration))s defaultPreRoll=\(String(format: "%.2f", SuperFastCaptureConstants.defaultPreRollDuration))s"
    )
  }

  func stop(reason: String = "unknown") {
    if engine != nil {
      logger.notice("Capture engine stopped reason=\(reason)")
    }
    detachEngine(clearingRecordingState: true)
  }

  /// Removes the tap, observer, converter, and engine. Bumps the capture generation so
  /// in-flight tap callbacks from the old engine are ignored. Recording state (active file,
  /// ring buffer, timing metrics) is preserved unless `clearingRecordingState` is set, which
  /// is what lets restartPreservingRecording resume capture onto the same file.
  private func detachEngine(clearingRecordingState: Bool = false) {
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    if let configurationChangeObserver {
      NotificationCenter.default.removeObserver(configurationChangeObserver)
      self.configurationChangeObserver = nil
    }
    processingQueue.sync {
      captureGeneration += 1
      converter = nil
      if clearingRecordingState {
        resolvePendingFinish(with: .idle)
        clearStopBoundary()
        activeRecording = nil
        recordingFailure = nil
        ringBuffer.clear()
      }
    }
    engine?.stop()
    engine = nil
  }

  private func handleConfigurationChange(generation: Int) {
    guard processingQueue.sync(execute: { Self.shouldProcessCallback(callbackGeneration: generation, currentGeneration: captureGeneration) }) else {
      return
    }
    logger.notice("Capture engine configuration changed")
    onEngineConfigurationChange(generation)
  }

  static func shouldProcessCallback(callbackGeneration: Int, currentGeneration: Int) -> Bool {
    callbackGeneration == currentGeneration
  }

  func isCurrentGeneration(_ generation: Int) -> Bool {
    processingQueue.sync { generation == captureGeneration }
  }

  func beginRecording(to url: URL, requestedAt: Date = Date(), mode: CaptureRecordingMode) throws {
    try startIfNeeded(reason: "begin-recording", keepWarmBuffer: mode.keepsWarmBuffer)

    var startError: Error?
    processingQueue.sync {
      do {
        recordingFailure = nil
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

  /// Prevents a new capture file from replacing one that is still draining its final PCM
  /// frames. RecordingClient awaits this before it opens a new session.
  func waitForPendingFinish() async {
    await withCheckedContinuation { continuation in
      processingQueue.async { [weak self] in
        guard let self, self.pendingFinish != nil || self.currentStopBoundary() != nil else {
          continuation.resume()
          return
        }
        self.pendingFinishWaiters.append(continuation)
      }
    }
  }

  /// Finalizes at an audio-clock boundary rather than after a wall-clock delay. The hotkey
  /// event supplies the boundary in host time; tap timestamps let us retain every PCM frame
  /// through that point even when Core Audio delivers the final buffer late.
  func finishRecording(
    clearBuffer: Bool = true,
    postRollDuration: TimeInterval = 0
  ) async -> FinishRecordingResult {
    let postRollDuration = max(0, postRollDuration)
    let targetHostTime = mach_absolute_time() + AVAudioTime.hostTime(
      forSeconds: postRollDuration
    )
    guard requestStopBoundary(targetHostTime) else {
      return .finalizing
    }

    return await withCheckedContinuation { continuation in
      processingQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: .idle)
          return
        }
        guard self.activeRecording != nil else {
          self.clearStopBoundary()
          continuation.resume(returning: self.finishResult())
          self.resumePendingFinishWaiters()
          return
        }

        self.pendingFinish = PendingFinish(
          targetHostTime: targetHostTime,
          postRollDuration: postRollDuration,
          clearBuffer: clearBuffer,
          continuation: continuation
        )
        if self.hasReachedStopBoundary(targetHostTime) {
          self.resolvePendingFinish(with: self.finishResult())
          return
        }
        self.scheduleStopDrainTimeout()
      }
    }
  }

  private func enqueue(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, generation: Int) {
    guard let copy = clone(buffer) else { return }
    processingQueue.async { [weak self] in
      self?.process(copy, time: time, generation: generation)
    }
  }

  private func process(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, generation: Int) {
    guard Self.shouldProcessCallback(callbackGeneration: generation, currentGeneration: captureGeneration) else {
      return
    }

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

    let stopBoundary = currentStopBoundary()
    let inputFramesToWrite: Int
    if let stopBoundary,
       time.isHostTimeValid
    {
      inputFramesToWrite = Self.inputFramesToWrite(
        bufferStartHostTime: time.hostTime,
        inputSampleRate: buffer.format.sampleRate,
        inputFrameCount: Int(buffer.frameLength),
        targetHostTime: stopBoundary.targetHostTime
      )
    } else {
      inputFramesToWrite = Int(buffer.frameLength)
    }

    let outputFramesToWrite = Self.outputFramesToWrite(
      convertedFrameCount: Int(converted.frameLength),
      inputFrameCount: Int(buffer.frameLength),
      inputFramesToWrite: inputFramesToWrite
    )

    do {
      if outputFramesToWrite > 0 {
        converted.frameLength = AVAudioFrameCount(outputFramesToWrite)
        try recording.file.write(from: converted)
      }
      if let stopBoundary,
         time.isHostTimeValid,
         Self.bufferReachesTarget(
           bufferStartHostTime: time.hostTime,
           inputSampleRate: buffer.format.sampleRate,
           inputFrameCount: Int(buffer.frameLength),
           targetHostTime: stopBoundary.targetHostTime
         )
      {
        markStopBoundaryReached(stopBoundary.targetHostTime)
        if let pendingFinish {
          let postRollDescription = String(format: "%.3f", pendingFinish.postRollDuration)
          logger.notice("Capture engine finalizing at audio boundary postRoll=\(postRollDescription)s")
          resolvePendingFinish(with: .captured(recording.url))
        }
      }
    } catch {
      logger.error("Failed to write capture engine audio: \(error.localizedDescription)")
      activeRecording = nil
      recordingFailure = .captureWriteFailed(error.localizedDescription)
      FileManager.default.removeItemIfExists(at: recording.url)
      resolvePendingFinish(with: .failed(.captureWriteFailed(error.localizedDescription)))
    }
  }

  /// Maps the desired host-clock boundary onto the buffer's PCM timeline. This uses Core
  /// Audio's timestamp rather than queue or wall-clock timing, so delayed callbacks do not
  /// discard samples that were captured before the stop boundary.
  static func inputFramesToWrite(
    bufferStartHostTime: UInt64,
    inputSampleRate: Double,
    inputFrameCount: Int,
    targetHostTime: UInt64
  ) -> Int {
    guard inputSampleRate > 0, inputFrameCount > 0, targetHostTime > bufferStartHostTime else {
      return 0
    }
    let secondsToTarget = AVAudioTime.seconds(forHostTime: targetHostTime - bufferStartHostTime)
    let frameCount = Int((secondsToTarget * inputSampleRate).rounded(.down))
    return min(max(frameCount, 0), inputFrameCount)
  }

  static func outputFramesToWrite(
    convertedFrameCount: Int,
    inputFrameCount: Int,
    inputFramesToWrite: Int
  ) -> Int {
    guard convertedFrameCount > 0, inputFrameCount > 0, inputFramesToWrite > 0 else {
      return 0
    }
    let ratio = Double(inputFramesToWrite) / Double(inputFrameCount)
    return min(
      convertedFrameCount,
      max(1, Int((Double(convertedFrameCount) * ratio).rounded(.down)))
    )
  }

  static func bufferReachesTarget(
    bufferStartHostTime: UInt64,
    inputSampleRate: Double,
    inputFrameCount: Int,
    targetHostTime: UInt64
  ) -> Bool {
    guard inputSampleRate > 0, inputFrameCount > 0 else { return false }
    let bufferDurationHostTime = AVAudioTime.hostTime(
      forSeconds: Double(inputFrameCount) / inputSampleRate
    )
    return targetHostTime <= bufferStartHostTime + bufferDurationHostTime
  }

  private func requestStopBoundary(_ targetHostTime: UInt64) -> Bool {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    guard stopBoundary == nil else { return false }
    stopBoundary = StopBoundary(targetHostTime: targetHostTime)
    return true
  }

  private func currentStopBoundary() -> StopBoundary? {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    return stopBoundary
  }

  private func markStopBoundaryReached(_ targetHostTime: UInt64) {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    guard stopBoundary?.targetHostTime == targetHostTime else { return }
    stopBoundary?.hasReachedTarget = true
  }

  private func hasReachedStopBoundary(_ targetHostTime: UInt64) -> Bool {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    return stopBoundary?.targetHostTime == targetHostTime && stopBoundary?.hasReachedTarget == true
  }

  private func clearStopBoundary() {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    stopBoundary = nil
  }

  private func scheduleStopDrainTimeout() {
    stopDrainTimeoutTask?.cancel()
    stopDrainTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(SuperFastCaptureConstants.stopDrainTimeout))
      guard !Task.isCancelled else { return }
      self?.processingQueue.async { [weak self] in
        guard let self, self.pendingFinish != nil else { return }
        self.logger.error("Timed out waiting for capture engine to reach the stop audio boundary")
        let failure = RecordingFailure.captureFinalizationTimedOut
        if let url = self.activeRecording?.url {
          FileManager.default.removeItemIfExists(at: url)
        }
        self.resolvePendingFinish(with: .failed(failure))
      }
    }
  }

  private func finishResult() -> FinishRecordingResult {
    if let recordingFailure {
      return .failed(recordingFailure)
    }
    if let url = activeRecording?.url {
      return .captured(url)
    }
    return .idle
  }

  private func resolvePendingFinish(with result: FinishRecordingResult) {
    guard let pendingFinish else { return }
    self.pendingFinish = nil
    clearStopBoundary()
    stopDrainTimeoutTask?.cancel()
    stopDrainTimeoutTask = nil
    activeRecording = nil
    recordingFailure = nil
    if pendingFinish.clearBuffer {
      ringBuffer.clear()
    }
    pendingFinish.continuation.resume(returning: result)
    resumePendingFinishWaiters()
  }

  private func resumePendingFinishWaiters() {
    let waiters = pendingFinishWaiters
    pendingFinishWaiters.removeAll(keepingCapacity: false)
    waiters.forEach { $0.resume() }
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

}
