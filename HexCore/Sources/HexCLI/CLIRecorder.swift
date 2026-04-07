import AVFoundation
import Foundation

final class CLIRecorder: NSObject, @unchecked Sendable {
  private var recorder: AVAudioRecorder?
  private var stopContinuation: CheckedContinuation<Void, Error>?
  private let recordingURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("hex-cli-recording-\(UUID().uuidString).wav")

  func prepare() throws -> URL {
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
    recorder.delegate = self
    guard recorder.prepareToRecord() else {
      throw CLIRecorderError.recorderFailed
    }

    self.recorder = recorder
    return recordingURL
  }

  func startRecording() throws {
    guard let recorder, recorder.record() else {
      throw CLIRecorderError.recorderFailed
    }
  }

  func stopRecording() async throws {
    guard let recorder else {
      throw CLIRecorderError.noRecording
    }

    try await withCheckedThrowingContinuation { continuation in
      stopContinuation = continuation
      recorder.stop()
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: recordingURL.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0 else {
      throw CLIRecorderError.noRecording
    }
  }
}

extension CLIRecorder: AVAudioRecorderDelegate {
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    guard let stopContinuation else {
      return
    }

    self.stopContinuation = nil
    if flag {
      stopContinuation.resume()
    } else {
      stopContinuation.resume(throwing: CLIRecorderError.noRecording)
    }
  }
}

private enum CLIRecorderError: LocalizedError {
  case recorderFailed
  case noRecording

  var errorDescription: String? {
    switch self {
    case .recorderFailed:
      return "Failed to start recording"
    case .noRecording:
      return "No recording was captured"
    }
  }
}
