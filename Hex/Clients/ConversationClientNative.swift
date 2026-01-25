//
//  ConversationClientNative.swift
//  Hex
//
//  Native Swift implementation of ConversationClient using MoshiKit.
//  This replaces the Python subprocess approach with pure Swift MLX inference.
//

import Foundation
import HexCore
import AVFoundation

#if canImport(MoshiKit)
import MoshiKit
#endif

private let logger = HexLog.conversation

/// Native Swift actor that manages Moshi speech AI using MoshiKit.
/// Uses MLX for on-device inference without Python dependencies.
actor ConversationClientNative {
    // MARK: - State Machine

    private enum SessionState {
        case idle
        case loading
        case running
        case stopping
    }

    // MARK: - Stored Properties

    #if canImport(MoshiKit)
    /// The MoshiKit instance
    private var moshiKit: MoshiKit?
    #endif

    /// Current session state
    private var sessionState: SessionState = .idle

    /// Continuation for transcript stream
    private var transcriptContinuation: AsyncStream<String>.Continuation?

    /// Continuation for state stream
    private var stateContinuation: AsyncStream<ConversationState>.Continuation?

    /// Currently loaded persona
    private var currentPersona: PersonaConfig?

    /// Whether the model has been prepared
    private var modelPrepared: Bool = false

    /// Audio processing task
    private var audioProcessingTask: Task<Void, Never>?

    /// Audio engine for capture and playback
    private var audioEngine: AVAudioEngine?

    /// Input node for microphone
    private var inputNode: AVAudioInputNode?

    /// Player node for output
    private var playerNode: AVAudioPlayerNode?

    /// Buffer for accumulating audio samples
    private var inputBuffer: [Float] = []

    /// Thread-safe check for session active
    nonisolated var isSessionActiveSync: Bool {
        return false  // Best-effort sync check
    }

    // MARK: - Constants

    /// Samples per frame (24kHz / 12.5Hz = 1920)
    private let samplesPerFrame: Int = 1920

    /// Sample rate for Moshi
    private let sampleRate: Double = 24000.0

    // MARK: - Public Methods

    /// Start a conversation session with the given configuration
    func startSession(_ config: ConversationConfig) async throws {
        guard sessionState == .idle else {
            logger.warning("Cannot start session: already in state \(String(describing: self.sessionState))")
            throw ConversationError.sessionAlreadyActive
        }

        sessionState = .loading
        emitState(.loading(progress: 0.0))

        logger.info("Starting native conversation session with persona: \(config.persona.name)")

        #if canImport(MoshiKit)
        do {
            // Load MoshiKit if not already loaded
            if moshiKit == nil {
                emitState(.loading(progress: 0.1))

                moshiKit = try await MoshiKit.load(
                    quantization: config.quantization,
                    progressHandler: { [weak self] progress, status in
                        Task { [weak self] in
                            await self?.emitState(.loading(progress: Double(progress) * 0.7))
                        }
                        logger.info("Model loading: \(status) (\(Int(progress * 100))%)")
                    }
                )
            }

            emitState(.loading(progress: 0.8))

            // Create persona
            let persona = MoshiPersona(
                name: config.persona.name,
                textPrompt: config.persona.textPrompt,
                voicePreset: config.persona.voicePreset,
                voiceEmbeddingPath: config.persona.voiceEmbeddingPath
            )

            // Start session with persona
            try await moshiKit!.startSession(persona: persona)

            emitState(.loading(progress: 0.9))

            // Set up audio
            try await setupAudio(
                inputDeviceID: config.inputDeviceID,
                outputDeviceID: config.outputDeviceID
            )

            // Start audio processing
            startAudioProcessing()

            sessionState = .running
            emitState(.ready)

            // Transition to active after brief delay
            try await Task.sleep(for: .milliseconds(100))
            emitState(.active(speaking: false, listening: true))

            logger.info("Native conversation session started successfully")
        } catch {
            sessionState = .idle
            emitState(.error(error.localizedDescription))
            throw error
        }
        #else
        throw ConversationError.modelNotFound("MoshiKit not available")
        #endif
    }

    /// Stop the current conversation session
    func stopSession() async {
        guard sessionState == .running || sessionState == .loading else {
            logger.debug("No active session to stop")
            return
        }

        sessionState = .stopping
        logger.info("Stopping native conversation session")

        // Stop audio processing
        audioProcessingTask?.cancel()
        audioProcessingTask = nil

        // Stop audio engine
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        playerNode = nil

        #if canImport(MoshiKit)
        // Stop MoshiKit session
        await moshiKit?.stopSession()
        #endif

        sessionState = .idle
        emitState(.idle)
        logger.info("Native conversation session stopped")
    }

    /// Check if a session is currently active
    func isSessionActive() -> Bool {
        return sessionState == .running
    }

    /// Stream of transcript text
    nonisolated func transcriptStream() -> AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            Task {
                await self.setTranscriptContinuation(continuation)
            }

            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.clearTranscriptContinuation()
                }
            }
        }
    }

    /// Stream of conversation state changes
    nonisolated func stateStream() -> AsyncStream<ConversationState> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            Task {
                await self.setStateContinuationAndEmitCurrent(continuation)
            }

            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.clearStateContinuation()
                }
            }
        }
    }

    /// Sets the transcript continuation
    private func setTranscriptContinuation(_ continuation: AsyncStream<String>.Continuation) {
        self.transcriptContinuation = continuation
    }

    /// Sets the state continuation and emits current state
    private func setStateContinuationAndEmitCurrent(_ continuation: AsyncStream<ConversationState>.Continuation) {
        self.stateContinuation = continuation

        let currentState: ConversationState
        switch sessionState {
        case .idle: currentState = .idle
        case .loading: currentState = .loading(progress: 0.5)
        case .running: currentState = .active(speaking: false, listening: true)
        case .stopping: currentState = .loading(progress: 0.0)
        }
        continuation.yield(currentState)
    }

    /// Load a persona configuration
    func loadPersona(_ persona: PersonaConfig) async throws {
        logger.info("Loading persona: \(persona.name)")
        currentPersona = persona

        if sessionState == .running {
            logger.info("Session active, restarting with new persona")
            await stopSession()

            let config = ConversationConfig(persona: persona)
            try await startSession(config)
        }
    }

    /// Get available voice presets
    func getVoicePresets() -> [VoicePreset] {
        return VoicePreset.allPresets
    }

    /// Prepare the model (download/verify availability)
    func prepareModel(progressCallback: @escaping (Progress) -> Void) async throws {
        logger.info("Preparing MoshiKit model")

        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)

        #if canImport(MoshiKit)
        // Load model
        moshiKit = try await MoshiKit.load(
            quantization: 4,
            progressHandler: { loadProgress, _ in
                progress.completedUnitCount = Int64(loadProgress * 100)
                progressCallback(progress)
            }
        )

        modelPrepared = true
        logger.info("MoshiKit model preparation complete")
        #else
        throw ConversationError.modelNotFound("MoshiKit not available")
        #endif
    }

    /// Check if the model is ready
    func isModelReady() -> Bool {
        #if canImport(MoshiKit)
        return modelPrepared || moshiKit != nil
        #else
        return false
        #endif
    }

    /// Cleanup all resources
    func cleanup() async {
        logger.info("Cleaning up ConversationClientNative resources")
        await stopSession()

        #if canImport(MoshiKit)
        moshiKit = nil
        #endif

        modelPrepared = false
    }

    // MARK: - Private Methods

    private func clearTranscriptContinuation() {
        transcriptContinuation = nil
    }

    private func clearStateContinuation() {
        stateContinuation = nil
    }

    private func emitState(_ state: ConversationState) {
        stateContinuation?.yield(state)
    }

    private func emitTranscript(_ text: String) {
        transcriptContinuation?.yield(text)
    }

    // MARK: - Audio Setup

    private func setupAudio(inputDeviceID: String?, outputDeviceID: String?) async throws {
        audioEngine = AVAudioEngine()

        guard let engine = audioEngine else {
            throw ConversationError.launchFailed("Failed to create audio engine")
        }

        inputNode = engine.inputNode

        // Create player node for output
        playerNode = AVAudioPlayerNode()
        engine.attach(playerNode!)

        // Connect player to output
        let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!

        engine.connect(playerNode!, to: engine.mainMixerNode, format: outputFormat)

        // Set up input tap for microphone
        let inputFormat = inputNode!.outputFormat(forBus: 0)

        inputNode!.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            Task { [weak self] in
                await self?.processInputBuffer(buffer)
            }
        }

        // Start engine
        try engine.start()

        logger.info("Audio engine started")
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) async {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        // Resample if needed (input might not be 24kHz)
        let inputFormat = inputNode?.outputFormat(forBus: 0)
        let inputSampleRate = inputFormat?.sampleRate ?? 44100

        let resampled: [Float]
        if inputSampleRate != sampleRate {
            // Simple linear resampling
            let ratio = sampleRate / inputSampleRate
            let outputCount = Int(Double(frameCount) * ratio)
            resampled = (0 ..< outputCount).map { i in
                let srcIdx = Double(i) / ratio
                let idx = Int(srcIdx)
                let frac = Float(srcIdx - Double(idx))
                if idx + 1 < samples.count {
                    return samples[idx] * (1 - frac) + samples[idx + 1] * frac
                }
                return samples[min(idx, samples.count - 1)]
            }
        } else {
            resampled = samples
        }

        // Accumulate samples
        inputBuffer.append(contentsOf: resampled)

        // Process full frames
        while inputBuffer.count >= samplesPerFrame {
            let frame = Array(inputBuffer.prefix(samplesPerFrame))
            inputBuffer.removeFirst(samplesPerFrame)

            await processAudioFrame(frame)
        }
    }

    private func processAudioFrame(_ frame: [Float]) async {
        #if canImport(MoshiKit)
        guard let kit = moshiKit, sessionState == .running else { return }

        do {
            if let outputFrame = try await kit.processAudioFrame(frame) {
                // Play output audio
                await playAudioFrame(outputFrame)

                // Update state based on output level
                let outputLevel = outputFrame.map { abs($0) }.max() ?? 0
                if outputLevel > 0.01 {
                    emitState(.active(speaking: true, listening: true))
                } else {
                    emitState(.active(speaking: false, listening: true))
                }
            }
        } catch {
            logger.error("Error processing audio frame: \(error.localizedDescription)")
        }
        #endif
    }

    private func playAudioFrame(_ samples: [Float]) async {
        guard let playerNode = playerNode, let engine = audioEngine else { return }

        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channelData = buffer.floatChannelData {
            for (i, sample) in samples.enumerated() {
                channelData[0][i] = sample
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func startAudioProcessing() {
        audioProcessingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))

                // Keep the run loop active
                await self?.checkAudioState()
            }
        }
    }

    private func checkAudioState() async {
        // Periodic check of audio engine state
        if audioEngine?.isRunning == false {
            logger.warning("Audio engine stopped unexpectedly")
        }
    }
}

// MARK: - Fallback Factory

/// Factory to create either native or subprocess-based client
enum ConversationClientFactory {
    /// Check if native (MoshiKit) implementation is available
    static var isNativeAvailable: Bool {
        #if canImport(MoshiKit)
        return true
        #else
        return false
        #endif
    }

    /// Create the preferred conversation client
    static func createClient() -> any ConversationClientProtocol {
        if isNativeAvailable {
            return ConversationClientNative()
        } else {
            return ConversationClientLive()
        }
    }
}

// MARK: - Protocol Conformance

/// Protocol that both native and subprocess clients conform to
protocol ConversationClientProtocol: Actor {
    func startSession(_ config: ConversationConfig) async throws
    func stopSession() async
    func isSessionActive() -> Bool
    nonisolated func transcriptStream() -> AsyncStream<String>
    nonisolated func stateStream() -> AsyncStream<ConversationState>
    func loadPersona(_ persona: PersonaConfig) async throws
    func getVoicePresets() -> [VoicePreset]
    func prepareModel(progressCallback: @escaping (Progress) -> Void) async throws
    func isModelReady() -> Bool
    func cleanup() async
}

// Conformance extensions
extension ConversationClientNative: ConversationClientProtocol {}
extension ConversationClientLive: ConversationClientProtocol {}
