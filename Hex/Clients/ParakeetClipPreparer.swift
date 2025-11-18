import AVFoundation
import Foundation
import HexCore
import Logging

struct ParakeetClipPreparationResult {
  let url: URL
  private let cleanupURL: URL?

  init(url: URL, cleanupURL: URL?) {
    self.url = url
    self.cleanupURL = cleanupURL
  }

  func cleanup() {
    guard let cleanupURL else { return }
    try? FileManager.default.removeItem(at: cleanupURL)
  }
}

enum ParakeetClipPreparer {
  private enum Error: LocalizedError {
    case unsupportedFormat
    case bufferAllocationFailed

    var errorDescription: String? {
      switch self {
      case .unsupportedFormat:
        return "Parakeet can only pad mono Float32 PCM recordings."
      case .bufferAllocationFailed:
        return "Unable to allocate buffer while preparing Parakeet audio clip."
      }
    }
  }

  // FluidAudio's LastChunkHandling guidance recommends chunk_duration 1.5s,
  // so pad to at least that window to avoid decoder errors.
  static let defaultMinimumDuration: TimeInterval = 1.5

  static func ensureMinimumDuration(
    url: URL,
    minimumDuration: TimeInterval = defaultMinimumDuration,
    logger: Logger = HexLog.parakeet
  ) throws -> ParakeetClipPreparationResult {
    let audioFile = try AVAudioFile(forReading: url)
    let format = audioFile.processingFormat
    let duration = Double(audioFile.length) / format.sampleRate

    logger.debug(
      "Parakeet clip check file=\(url.lastPathComponent) duration=\(String(format: "%.3f", duration))s sampleRate=\(String(format: "%.0f", format.sampleRate))Hz channels=\(format.channelCount)"
    )

    guard duration < minimumDuration else {
      return ParakeetClipPreparationResult(url: url, cleanupURL: nil)
    }

    guard format.commonFormat == .pcmFormatFloat32 else {
      throw Error.unsupportedFormat
    }

    let minimumFrames = AVAudioFrameCount((minimumDuration * format.sampleRate).rounded(.up))
    let existingFrames64 = max(AVAudioFramePosition(0), audioFile.length)
    let sourceCapacity = max(AVAudioFrameCount(min(existingFrames64, AVAudioFramePosition(AVAudioFrameCount.max))), 1)

    guard
      let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sourceCapacity),
      let paddedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: minimumFrames)
    else {
      throw Error.bufferAllocationFailed
    }

    try audioFile.read(into: readBuffer)
    let framesRead = min(readBuffer.frameLength, minimumFrames)

    guard
      let sourceChannels = readBuffer.floatChannelData,
      let paddedChannels = paddedBuffer.floatChannelData
    else {
      throw Error.unsupportedFormat
    }

    let channelCount = Int(format.channelCount)
    for channel in 0..<channelCount {
      let dest = paddedChannels[channel]
      let src = sourceChannels[channel]
      if framesRead > 0 {
        dest.update(from: src, count: Int(framesRead))
      }
      let padCount = Int(minimumFrames - framesRead)
      if padCount > 0 {
        dest.advanced(by: Int(framesRead)).initialize(repeating: 0, count: padCount)
      }
    }
    

    paddedBuffer.frameLength = minimumFrames

    let paddedURL = makePaddedURL(from: url)
    if FileManager.default.fileExists(atPath: paddedURL.path) {
      try FileManager.default.removeItem(at: paddedURL)
    }

    let paddedFile = try AVAudioFile(forWriting: paddedURL, settings: audioFile.fileFormat.settings)
    try paddedFile.write(from: paddedBuffer)

    logger.notice(
      "Padded clip for Parakeet file=\(url.lastPathComponent) original=\(String(format: "%.3f", duration))s paddedTo=\(String(format: "%.3f", minimumDuration))s output=\(paddedURL.lastPathComponent)"
    )

    return ParakeetClipPreparationResult(url: paddedURL, cleanupURL: paddedURL)
  }

  private static func makePaddedURL(from url: URL) -> URL {
    let base = url.deletingLastPathComponent()
    let stem = url.deletingPathExtension().lastPathComponent
    return base.appendingPathComponent("\(stem)-parakeet-padded.wav")
  }
}
