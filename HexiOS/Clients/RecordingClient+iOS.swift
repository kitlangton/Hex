import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let recordingLogger = HexLog.recording

struct AudioInputDevice: Identifiable, Equatable {
  var id: String
  var name: String
}

@DependencyClient
struct RecordingClient {
  var startRecording: @Sendable () async -> Void = {}
  var stopRecording: @Sendable () async -> URL = { URL(fileURLWithPath: "") }
  var requestMicrophoneAccess: @Sendable () async -> Bool = { false }
  var observeAudioLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
  var getAvailableInputDevices: @Sendable () async -> [AudioInputDevice] = { [] }
  var getDefaultInputDeviceName: @Sendable () async -> String? = { nil }
  var warmUpRecorder: @Sendable () async -> Void = {}
  var cleanup: @Sendable () async -> Void = {}
}

extension RecordingClient: DependencyKey {
  static var liveValue: Self {
    let live = RecordingClientLiveIOS()
    return Self(
      startRecording: { await live.startRecording() },
      stopRecording: { await live.stopRecording() },
      requestMicrophoneAccess: { await live.requestMicrophoneAccess() },
      observeAudioLevel: { await live.observeAudioLevel() },
      getAvailableInputDevices: { [] },
      getDefaultInputDeviceName: { await live.getDefaultInputDeviceName() },
      warmUpRecorder: { await live.warmUpRecorder() },
      cleanup: { await live.cleanup() }
    )
  }
}

struct Meter: Equatable {
  let averagePower: Double
  let peakPower: Double
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}

// MARK: - iOS Recording Implementation

actor RecordingClientLiveIOS {
  private var recorder: AVAudioRecorder?
  private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
  private var isRecorderPrimedForNextSession = false
  private let recorderSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
  ]
  private let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
  private var meterTask: Task<Void, Never>?
  private var interruptionObserver: Any?

  init() {
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }

      if type == .began {
        recordingLogger.notice("Audio session interrupted — stopping recording")
        Task { await self?.handleInterruption() }
      }
    }
  }

  deinit {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func handleInterruption() {
    recorder?.stop()
    stopMeterTask()
  }

  func requestMicrophoneAccess() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  func getDefaultInputDeviceName() -> String? {
    let route = AVAudioSession.sharedInstance().currentRoute
    return route.inputs.first?.portName
  }

  func startRecording() async {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
      try session.setPreferredSampleRate(16000)
      try session.setActive(true)
    } catch {
      recordingLogger.error("Failed to configure audio session: \(error.localizedDescription)")
      return
    }

    do {
      let recorder = try ensureRecorderReadyForRecording()
      guard recorder.record() else {
        recordingLogger.error("AVAudioRecorder refused to start recording")
        return
      }
      startMeterTask()
      recordingLogger.notice("Recording started")
    } catch {
      recordingLogger.error("Failed to start recording: \(error.localizedDescription)")
    }
  }

  func stopRecording() async -> URL {
    let wasRecording = recorder?.isRecording == true
    recorder?.stop()
    stopMeterTask()
    if wasRecording {
      recordingLogger.notice("Recording stopped")
    }

    var exportedURL = recordingURL
    do {
      exportedURL = try duplicateCurrentRecording()
    } catch {
      isRecorderPrimedForNextSession = false
      recordingLogger.error("Failed to copy recording: \(error.localizedDescription)")
    }

    do {
      try primeRecorderForNextSession()
    } catch {
      isRecorderPrimedForNextSession = false
      recordingLogger.error("Failed to prime recorder: \(error.localizedDescription)")
    }

    // Deactivate audio session
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

    return exportedURL
  }

  func warmUpRecorder() async {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
      try session.setPreferredSampleRate(16000)
      try session.setActive(true)
      try primeRecorderForNextSession()
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      recordingLogger.error("Failed to warm up recorder: \(error.localizedDescription)")
    }
  }

  func cleanup() {
    if let recorder = recorder {
      if recorder.isRecording { recorder.stop() }
      self.recorder = nil
    }
    isRecorderPrimedForNextSession = false
    stopMeterTask()
    recordingLogger.notice("RecordingClient cleaned up")
  }

  func observeAudioLevel() -> AsyncStream<Meter> {
    meterStream
  }

  // MARK: - Private Helpers

  private enum RecorderPreparationError: Error {
    case failedToPrepareRecorder
    case missingRecordingOnDisk
  }

  private func ensureRecorderReadyForRecording() throws -> AVAudioRecorder {
    let recorder = try recorderOrCreate()
    if !isRecorderPrimedForNextSession {
      guard recorder.prepareToRecord() else {
        throw RecorderPreparationError.failedToPrepareRecorder
      }
    }
    isRecorderPrimedForNextSession = false
    return recorder
  }

  private func recorderOrCreate() throws -> AVAudioRecorder {
    if let recorder { return recorder }
    let recorder = try AVAudioRecorder(url: recordingURL, settings: recorderSettings)
    recorder.isMeteringEnabled = true
    self.recorder = recorder
    return recorder
  }

  private func duplicateCurrentRecording() throws -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: recordingURL.path) else {
      throw RecorderPreparationError.missingRecordingOnDisk
    }
    let exportURL = recordingURL
      .deletingLastPathComponent()
      .appendingPathComponent("hex-recording-\(UUID().uuidString).wav")
    if fm.fileExists(atPath: exportURL.path) {
      try fm.removeItem(at: exportURL)
    }
    try fm.copyItem(at: recordingURL, to: exportURL)
    return exportURL
  }

  private func primeRecorderForNextSession() throws {
    let recorder = try recorderOrCreate()
    guard recorder.prepareToRecord() else {
      isRecorderPrimedForNextSession = false
      throw RecorderPreparationError.failedToPrepareRecorder
    }
    isRecorderPrimedForNextSession = true
  }

  private func startMeterTask() {
    meterTask = Task {
      while !Task.isCancelled, let r = self.recorder, r.isRecording {
        r.updateMeters()
        let averagePower = r.averagePower(forChannel: 0)
        let averageNormalized = pow(10, averagePower / 20.0)
        let peakPower = r.peakPower(forChannel: 0)
        let peakNormalized = pow(10, peakPower / 20.0)
        meterContinuation.yield(Meter(averagePower: Double(averageNormalized), peakPower: Double(peakNormalized)))
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func stopMeterTask() {
    meterTask?.cancel()
    meterTask = nil
  }
}
