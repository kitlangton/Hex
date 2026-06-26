//
//  AudioRecorder.swift
//  HexIOS
//
//  Minimal microphone capture for the V1 prototype: records 16 kHz mono PCM WAV
//  (the format on-device ASR models expect) via AVAudioRecorder, and handles the
//  mic permission prompt. This is the host-app recording path; it will migrate to
//  a shared HexCore `RecordingClient` (P1-2) once the engine move lands.
//

import AVFoundation
import Foundation

@MainActor
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Microphone access is denied. Enable it in Settings."
            case .couldNotStart: "Could not start recording."
            }
        }
    }

    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?

    /// Prompts for microphone access if undetermined; returns whether it's granted.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Begins recording to a fresh temp file and returns its URL.
    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else { throw RecorderError.couldNotStart }

        self.recorder = recorder
        self.currentURL = url
        return url
    }

    /// Stops recording and returns the file URL (nil if nothing was recording).
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return currentURL
    }
}
