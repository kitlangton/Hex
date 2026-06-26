//
//  WhisperTranscriber.swift
//  HexIOS
//
//  Thin actor around WhisperKit for on-device transcription in the V1 prototype.
//  Loads a model once (first run downloads it from Hugging Face) and reuses it.
//  This deliberately uses WhisperKit directly to get a working device build fast;
//  it will be replaced by the shared HexCore engine (P0-4) + Parakeet later.
//

import Foundation
import WhisperKit

actor WhisperTranscriber {
    enum TranscriberError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The transcription model is not loaded yet." }
    }

    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    var isLoaded: Bool { whisperKit != nil }

    /// Loads `model` (downloading on first use). No-op if already loaded.
    /// Model names accept WhisperKit short forms, e.g. "tiny", "base", "small".
    func load(model: String) async throws {
        if whisperKit != nil, loadedModel == model { return }
        let config = WhisperKitConfig(model: model, prewarm: false, load: true, download: true)
        whisperKit = try await WhisperKit(config)
        loadedModel = model
    }

    /// Transcribes the audio file at `url` into a single trimmed string.
    func transcribe(url: URL) async throws -> String {
        guard let whisperKit else { throw TranscriberError.notLoaded }
        let results = try await whisperKit.transcribe(audioPath: url.path)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
