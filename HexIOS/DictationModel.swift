//
//  DictationModel.swift
//  HexIOS
//
//  Observable orchestrator for the prototype: model loading, mic permission,
//  record → transcribe → history. UI-facing state only; the actual work is done
//  by AudioRecorder (main actor) and WhisperTranscriber (its own actor).
//

import Foundation
import Observation

struct DictationEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

@MainActor
@Observable
final class DictationModel {
    enum ModelState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    /// WhisperKit short model name. "base" balances size/accuracy for a first run.
    let modelName = "base"

    private(set) var modelState: ModelState = .loading
    private(set) var phase: Phase = .idle
    private(set) var entries: [DictationEntry] = []
    var errorMessage: String?

    private let recorder = AudioRecorder()
    private let transcriber = WhisperTranscriber()

    var canRecord: Bool { modelState == .ready && phase != .transcribing }

    var recordButtonTitle: String {
        switch phase {
        case .idle: "Start Dictation"
        case .recording: "Stop"
        case .transcribing: "Transcribing…"
        }
    }

    /// Load the model + request mic permission. Call once from `.task`.
    func prepare() async {
        _ = await recorder.requestPermission()
        do {
            try await transcriber.load(model: modelName)
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func toggleRecording() async {
        switch phase {
        case .idle: await startRecording()
        case .recording: await stopAndTranscribe()
        case .transcribing: break
        }
    }

    private func startRecording() async {
        guard modelState == .ready else { return }
        guard await recorder.requestPermission() else {
            errorMessage = AudioRecorder.RecorderError.permissionDenied.localizedDescription
            return
        }
        do {
            _ = try recorder.start()
            phase = .recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopAndTranscribe() async {
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        phase = .transcribing
        defer { phase = .idle }
        do {
            let text = try await transcriber.transcribe(url: url)
            try? FileManager.default.removeItem(at: url)
            guard !text.isEmpty else { return }
            entries.insert(DictationEntry(text: text, date: Date()), at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
