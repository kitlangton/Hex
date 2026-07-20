import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import HexCore

/// On-demand recording through an input Audio Queue.
///
/// Unlike `AVAudioEngine`, an input Audio Queue has no output graph. Binding the queue directly
/// to the selected microphone prevents capture from opening the default output device as part
/// of a duplex graph (which can switch Bluetooth headphones to their call profile), and avoids
/// changing macOS's global default input device.
final class InputOnlyCaptureController {
  enum FinishRecordingResult {
    case captured(URL)
    case failed(RecordingFailure)
    case idle
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
    var didLogFirstBuffer: Bool
  }

  private static let sampleRate: Double = 16_000
  private static let fallbackStopGracePeriod: TimeInterval = 0.05
  private static let minimumStopGracePeriod: TimeInterval = 0.02
  private static let maximumStopGracePeriod: TimeInterval = 0.08
  private static let stopGraceSafetyMargin: TimeInterval = 0.008
  private static let timingWindowSize = 8
  private static let queueBufferDuration: TimeInterval = 0.05
  private static let queueBufferCount = 3

  private let logger = HexLog.recording
  private let processingQueue = DispatchQueue(label: "com.kitlangton.Hex.InputOnlyCapture")
  private let meterContinuation: AsyncStream<Meter>.Continuation
  // Audio Queue requires interleaved linear PCM. With one channel this only affects the
  // buffer layout; conversion below writes Hex's existing non-interleaved file format.
  private let queueFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: InputOnlyCaptureController.sampleRate,
    channels: 1,
    interleaved: true
  )!
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: InputOnlyCaptureController.sampleRate,
    channels: 1,
    interleaved: false
  )!

  private var audioQueue: AudioQueueRef?
  private var converter: AVAudioConverter?
  private var activeRecording: ActiveRecording?
  private var recordingFailure: RecordingFailure?
  private var captureGeneration = 0
  private var lastProcessedBufferAt: Date?
  private var recentCallbackIntervals: [TimeInterval] = []
  private var recentBufferDurations: [TimeInterval] = []
  private var didLogConversionFailure = false

  init(meterContinuation: AsyncStream<Meter>.Continuation) {
    self.meterContinuation = meterContinuation
  }

  deinit {
    detachAudioQueue()
  }

  var isRunning: Bool {
    audioQueue != nil
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
            ? observedCadence + Self.stopGraceSafetyMargin
            : Self.fallbackStopGracePeriod,
          Self.minimumStopGracePeriod
        ),
        Self.maximumStopGracePeriod
      )
      return StopTimingEstimate(
        gracePeriod: gracePeriod,
        callbackInterval: callbackInterval,
        bufferDuration: bufferDuration
      )
    }
  }

  func beginRecording(to url: URL, deviceID: AudioDeviceID, requestedAt: Date = Date()) throws {
    stop(reason: "restart-before-recording")

    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: Self.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true,
      ],
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )

    processingQueue.sync {
      activeRecording = ActiveRecording(
        url: url,
        file: file,
        requestedAt: requestedAt,
        didLogFirstBuffer: false
      )
      recordingFailure = nil
      didLogConversionFailure = false
    }

    do {
      try startAudioQueue(deviceID: deviceID, reason: "begin-recording")
    } catch {
      processingQueue.sync {
        activeRecording = nil
        recordingFailure = nil
      }
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  /// Rebinds input after an input-device/configuration change while retaining the open file.
  func restartPreservingRecording(deviceID: AudioDeviceID, reason: String) throws {
    logger.notice("Restarting input-only capture preserving recording reason=\(reason)")
    detachAudioQueue()
    try startAudioQueue(deviceID: deviceID, reason: reason)
  }

  func finishRecording() -> FinishRecordingResult {
    detachAudioQueue()
    return processingQueue.sync {
      let result: FinishRecordingResult
      if let recordingFailure {
        result = .failed(recordingFailure)
      } else if let recording = activeRecording {
        if recording.didLogFirstBuffer {
          result = .captured(recording.url)
        } else {
          logger.error("Input-only capture stopped without receiving usable audio")
          try? FileManager.default.removeItem(at: recording.url)
          result = .failed(.noCapturedAudio)
        }
      } else {
        result = .idle
      }
      activeRecording = nil
      recordingFailure = nil
      lastProcessedBufferAt = nil
      recentCallbackIntervals.removeAll(keepingCapacity: false)
      recentBufferDurations.removeAll(keepingCapacity: false)
      didLogConversionFailure = false
      return result
    }
  }

  func stop(reason: String) {
    if audioQueue != nil {
      logger.notice("Input-only capture stopped reason=\(reason)")
    }
    detachAudioQueue()
    processingQueue.sync {
      activeRecording = nil
      recordingFailure = nil
      lastProcessedBufferAt = nil
      recentCallbackIntervals.removeAll(keepingCapacity: false)
      recentBufferDurations.removeAll(keepingCapacity: false)
      didLogConversionFailure = false
    }
  }

  private func startAudioQueue(deviceID: AudioDeviceID, reason: String) throws {
    var streamDescription = queueFormat.streamDescription.pointee
    let generation = processingQueue.sync {
      captureGeneration += 1
      return captureGeneration
    }
    var newAudioQueue: AudioQueueRef?
    try check(
      AudioQueueNewInputWithDispatchQueue(
        &newAudioQueue,
        &streamDescription,
        0,
        processingQueue
      ) { [weak self] queue, buffer, _, _, _ in
        self?.processAudioQueueBuffer(
          queue,
          buffer: buffer,
          generation: generation
        )
      },
      operation: "create input Audio Queue"
    )
    guard let newAudioQueue else {
      throw makeError(operation: "create input Audio Queue", status: kAudio_ParamError)
    }

    do {
      var uid = try deviceUID(for: deviceID)
      try check(
        AudioQueueSetProperty(
          newAudioQueue,
          kAudioQueueProperty_CurrentDevice,
          &uid,
          UInt32(MemoryLayout<CFString>.size)
        ),
        operation: "bind input Audio Queue device"
      )

      guard let converter = AVAudioConverter(from: queueFormat, to: targetFormat) else {
        throw makeError(operation: "create input format converter", status: kAudio_ParamError)
      }
      processingQueue.sync {
        self.converter = converter
      }

      let framesPerBuffer = max(
        1,
        UInt32((Self.sampleRate * Self.queueBufferDuration).rounded())
      )
      let bufferByteSize = framesPerBuffer * streamDescription.mBytesPerFrame
      for _ in 0..<Self.queueBufferCount {
        var buffer: AudioQueueBufferRef?
        try check(
          AudioQueueAllocateBuffer(newAudioQueue, bufferByteSize, &buffer),
          operation: "allocate input Audio Queue buffer"
        )
        guard let buffer else {
          throw makeError(operation: "allocate input Audio Queue buffer", status: kAudio_MemFullError)
        }
        try check(
          AudioQueueEnqueueBuffer(newAudioQueue, buffer, 0, nil),
          operation: "enqueue input Audio Queue buffer"
        )
      }

      audioQueue = newAudioQueue
      try check(AudioQueueStart(newAudioQueue, nil), operation: "start input Audio Queue")
      logger.notice(
        "Input-only Audio Queue started reason=\(reason) device=\(deviceID, privacy: .public) sampleRate=\(Self.sampleRate, privacy: .public)Hz outputGraph=none"
      )
    } catch {
      AudioQueueDispose(newAudioQueue, true)
      audioQueue = nil
      processingQueue.sync {
        self.converter = nil
      }
      throw error
    }
  }

  private func detachAudioQueue() {
    processingQueue.sync {
      captureGeneration += 1
    }
    guard let audioQueue else { return }
    AudioQueueStop(audioQueue, true)
    AudioQueueDispose(audioQueue, true)
    self.audioQueue = nil
    processingQueue.sync {
      converter = nil
    }
  }

  private func processAudioQueueBuffer(
    _ queue: AudioQueueRef,
    buffer: AudioQueueBufferRef,
    generation: Int
  ) {
    guard Self.shouldProcessCallback(
      callbackGeneration: generation,
      currentGeneration: captureGeneration
    ) else { return }
    defer {
      if Self.shouldProcessCallback(
        callbackGeneration: generation,
        currentGeneration: captureGeneration
      ) {
        let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if status != noErr {
          logger.error(
            "Failed to re-enqueue input Audio Queue buffer status=\(status, privacy: .public)"
          )
        }
      }
    }

    let byteCount = Int(buffer.pointee.mAudioDataByteSize)
    let bytesPerFrame = Int(queueFormat.streamDescription.pointee.mBytesPerFrame)
    guard byteCount > 0, bytesPerFrame > 0 else { return }
    let source = buffer.pointee.mAudioData
    let frameCount = AVAudioFrameCount(byteCount / bytesPerFrame)
    guard frameCount > 0,
      let inputBuffer = AVAudioPCMBuffer(pcmFormat: queueFormat, frameCapacity: frameCount)
    else { return }
    inputBuffer.frameLength = frameCount
    let destination = inputBuffer.mutableAudioBufferList.pointee.mBuffers.mData
    memcpy(destination, source, byteCount)
    process(inputBuffer, generation: generation)
  }

  private func process(_ inputBuffer: AVAudioPCMBuffer, generation: Int) {
    guard Self.shouldProcessCallback(
      callbackGeneration: generation,
      currentGeneration: captureGeneration
    ) else { return }
    guard let converted = convert(inputBuffer) else {
      if !didLogConversionFailure {
        logger.error(
          "Input-only capture received Audio Queue data but conversion produced no output"
        )
        didLogConversionFailure = true
      }
      return
    }
    guard converted.frameLength > 0, let samplePointer = converted.floatChannelData?[0] else {
      return
    }
    let sampleCount = Int(converted.frameLength)

    let now = Date()
    if let lastProcessedBufferAt {
      appendRecentMetric(now.timeIntervalSince(lastProcessedBufferAt), to: &recentCallbackIntervals)
    }
    lastProcessedBufferAt = now
    appendRecentMetric(
      Double(inputBuffer.frameLength) / inputBuffer.format.sampleRate,
      to: &recentBufferDurations
    )

    meterContinuation.yield(meter(for: samplePointer, count: sampleCount))
    guard var recording = activeRecording else { return }
    if !recording.didLogFirstBuffer {
      logger.notice(
        "Input-only capture first buffer latency=\(String(format: "%.3f", Date().timeIntervalSince(recording.requestedAt)))s frames=\(sampleCount)"
      )
      recording.didLogFirstBuffer = true
      activeRecording = recording
    }

    do {
      try recording.file.write(from: converted)
    } catch {
      logger.error("Failed to write input-only capture audio: \(error.localizedDescription)")
      activeRecording = nil
      recordingFailure = .captureWriteFailed(error.localizedDescription)
      try? FileManager.default.removeItem(at: recording.url)
    }
  }

  private func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let converter else { return nil }
    let sampleRateRatio = targetFormat.sampleRate / inputBuffer.format.sampleRate
    let frameCapacity = AVAudioFrameCount(
      max(1, (Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
    )
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: frameCapacity
      )
    else { return nil }

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
      logger.error("Failed to convert input-only capture audio: \(error.localizedDescription)")
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

  nonisolated static func shouldProcessCallback(
    callbackGeneration: Int,
    currentGeneration: Int
  ) -> Bool {
    callbackGeneration == currentGeneration
  }

  private func deviceUID(for deviceID: AudioDeviceID) throws -> CFString {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &uid) { pointer in
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        pointer
      )
    }
    try check(status, operation: "read input device UID")
    guard let uid else {
      throw makeError(operation: "read input device UID", status: kAudio_ParamError)
    }
    return uid
  }

  private func meter(for samples: UnsafePointer<Float>, count: Int) -> Meter {
    guard count > 0 else { return Meter(averagePower: 0, peakPower: 0) }
    var sumOfSquares: Float = 0
    var peak: Float = 0
    for index in 0..<count {
      let sample = samples[index]
      sumOfSquares += sample * sample
      peak = max(peak, abs(sample))
    }
    return Meter(
      averagePower: Double(sqrt(sumOfSquares / Float(count))),
      peakPower: Double(peak)
    )
  }

  private func appendRecentMetric(_ value: TimeInterval, to metrics: inout [TimeInterval]) {
    metrics.append(value)
    if metrics.count > Self.timingWindowSize {
      metrics.removeFirst(metrics.count - Self.timingWindowSize)
    }
  }

  private func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else { throw makeError(operation: operation, status: status) }
  }

  private func makeError(operation: String, status: OSStatus) -> NSError {
    NSError(
      domain: "InputOnlyCapture",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Failed to \(operation) (Core Audio status \(status))."]
    )
  }
}
