//
//  SpeechSynthesizerClient.swift
//  Hex
//
//  Reads agent output aloud with Kokoro (FluidAudio CoreML), an on-device neural
//  TTS model. The ~300 MB model downloads on first use and is cached alongside
//  Parakeet under the app container. Voice identifiers are Kokoro voice names
//  (e.g. "af_heart"); nil selects the recommended default.
//
//  Calling `speak` cancels any in-progress utterance first so the panel never
//  talks over itself.
//

import AVFoundation
import Dependencies
import DependenciesMacros
import FluidAudioTTS
import HexCore

private let speechLogger = HexLog.app

@DependencyClient
struct SpeechSynthesizerClient {
    /// Speaks `text` with the given Kokoro voice (nil = default). Returns once
    /// audio playback has started.
    var speak: @Sendable (String, String?) async -> Void
    var stop: @Sendable () async -> Void
    /// Downloads (if needed) and warms up the Kokoro model, reporting 0...1 progress.
    var prepareKokoro: @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
}

extension SpeechSynthesizerClient: DependencyKey {
    static var liveValue: Self {
        let kokoro = KokoroSpeechLive()
        return .init(
            speak: { text, voiceIdentifier in
                await kokoro.speak(text, voice: KokoroVoice.voiceName(fromIdentifier: voiceIdentifier))
            },
            stop: { await kokoro.stop() },
            prepareKokoro: { progress in
                try await kokoro.prepare(progress: progress)
            }
        )
    }
}

extension DependencyValues {
    var speechSynthesizer: SpeechSynthesizerClient {
        get { self[SpeechSynthesizerClient.self] }
        set { self[SpeechSynthesizerClient.self] = newValue }
    }
}

// MARK: - Kokoro voice identifiers

/// Maps the persisted `agentVoiceIdentifier` to/from Kokoro voice names.
enum KokoroVoice {
    /// Curated, supported subset (FluidAudio's TTS is beta and American English only).
    static let voices: [String] = TtsConstants.availableVoices.filter {
        $0.hasPrefix("af_") || $0.hasPrefix("am_")
    }

    static let defaultVoice = TtsConstants.recommendedVoice

    /// Resolves a stored identifier to a known voice name, tolerating the legacy
    /// "kokoro:" prefix and falling back to the default for unknown values.
    static func voiceName(fromIdentifier identifier: String?) -> String {
        guard var name = identifier else { return defaultVoice }
        if name.hasPrefix("kokoro:") { name = String(name.dropFirst("kokoro:".count)) }
        return voices.contains(name) ? name : defaultVoice
    }

    /// "af_heart" → "Heart — English (US, female)"
    static func label(forVoiceName name: String) -> String {
        let parts = name.split(separator: "_")
        let displayName = parts.last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? name
        let gender = name.hasPrefix("af_") ? "female" : "male"
        return "\(displayName) — English (US, \(gender))"
    }
}

// MARK: - Synthesis + playback

private actor KokoroSpeechLive {
    /// Shared init task so concurrent callers (settings preview + agent panel) join
    /// one download instead of racing to start two.
    private var managerTask: Task<TtSManager, Error>?
    private var player: AVAudioPlayer?
    /// Bumped on every speak/stop so a slow synthesis can't play stale audio.
    private var generation = 0

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await readyManager(progress: progress)
    }

    func speak(_ text: String, voice: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        generation += 1
        let requested = generation
        player?.stop()
        player = nil

        do {
            let manager = try await readyManager()
            let wav = try await manager.synthesize(text: trimmed, voice: voice)
            guard requested == generation else { return } // superseded while synthesizing
            let player = try AVAudioPlayer(data: wav)
            self.player = player
            player.play()
        } catch {
            speechLogger.error("Kokoro synthesis failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
    }

    private func readyManager(progress: (@Sendable (Double) -> Void)? = nil) async throws -> TtSManager {
        if let managerTask {
            return try await managerTask.value
        }
        speechLogger.notice("Initializing Kokoro TTS (downloads the model on first use)")
        let task = Task<TtSManager, Error> {
            let models = try await TtsModels.download(progressHandler: { progress?($0) })
            let manager = TtSManager()
            try await manager.initialize(models: models)
            speechLogger.notice("Kokoro TTS ready")
            return manager
        }
        managerTask = task
        do {
            return try await task.value
        } catch {
            managerTask = nil // allow retry after a failed download
            throw error
        }
    }
}
