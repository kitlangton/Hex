//
//  ConversationClientLive.swift
//  Hex
//
//  Live implementation of ConversationClient that manages PersonaPlex MLX subprocess.
//

import Foundation
import HexCore

private let logger = HexLog.conversation

/// Actor that manages the PersonaPlex MLX subprocess for full-duplex speech conversations.
/// Uses pipe-based communication for bidirectional data flow.
actor ConversationClientLive {
    // MARK: - State Machine

    private enum SessionState {
        case idle
        case starting
        case running
        case stopping
    }

    // MARK: - Stored Properties

    /// The PersonaPlex subprocess
    private var process: Process?

    /// Pipe for sending commands to PersonaPlex
    private var inputPipe: Pipe?

    /// Pipe for receiving output from PersonaPlex
    private var outputPipe: Pipe?

    /// Pipe for capturing stderr
    private var errorPipe: Pipe?

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

    /// Task for reading output stream
    private var outputReadTask: Task<Void, Never>?

    /// Task for reading error stream
    private var errorReadTask: Task<Void, Never>?

    /// Thread-safe check for session active (called synchronously from outside actor)
    nonisolated var isSessionActiveSync: Bool {
        // Note: This is a best-effort synchronous check.
        // For accurate state, use async methods.
        return false // Will be properly implemented with atomic flag if needed
    }

    // MARK: - PersonaPlex Configuration

    /// Path to the PersonaPlex MLX Python module
    private let personaPlexPath: URL = {
        // First, check if PersonaPlex is bundled inside the app
        if let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("personaplex-mlx") {
            if FileManager.default.fileExists(atPath: bundledPath.path) {
                return bundledPath
            }
        }

        // Fall back to external locations for development
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            homeDir.appendingPathComponent("repos/personaplex-mlx"),
            homeDir.appendingPathComponent("Developer/personaplex-mlx"),
            homeDir.appendingPathComponent("personaplex-mlx"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? candidates[0]
    }()

    /// Path to the bundled Python virtual environment
    private let bundledVenvPath: URL? = {
        if let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("personaplex-mlx/venv") {
            if FileManager.default.fileExists(atPath: bundledPath.path) {
                return bundledPath
            }
        }
        return nil
    }()

    /// Path to the bundled HuggingFace model cache
    private let bundledModelCachePath: URL? = {
        if let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("personaplex-mlx/models") {
            if FileManager.default.fileExists(atPath: bundledPath.path) {
                return bundledPath
            }
        }
        return nil
    }()

    /// Python executable path
    private let pythonPath: String = {
        // First, check for bundled venv Python
        if let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("personaplex-mlx/venv/bin/python3") {
            if FileManager.default.fileExists(atPath: bundledPath.path) {
                return bundledPath.path
            }
        }

        // Fall back to system Python
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/bin/python3"
    }()

    // MARK: - Public Methods

    /// Start a conversation session with the given configuration
    func startSession(_ config: ConversationConfig) async throws {
        guard sessionState == .idle else {
            logger.warning("Cannot start session: already in state \(String(describing: self.sessionState))")
            throw ConversationError.sessionAlreadyActive
        }

        sessionState = .starting
        emitState(.loading(progress: 0.0))

        logger.info("Starting conversation session with persona: \(config.persona.name)")

        do {
            try await launchPersonaPlex(config: config)
            sessionState = .running
            emitState(.active(speaking: false, listening: true))
            logger.info("Conversation session started successfully")
        } catch {
            sessionState = .idle
            emitState(.error(error.localizedDescription))
            throw error
        }
    }

    /// Stop the current conversation session
    func stopSession() async {
        guard sessionState == .running || sessionState == .starting else {
            logger.debug("No active session to stop")
            return
        }

        sessionState = .stopping
        logger.info("Stopping conversation session")

        await terminateProcess()

        sessionState = .idle
        emitState(.idle)
        logger.info("Conversation session stopped")
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

    /// Sets the transcript continuation (actor-isolated helper)
    private func setTranscriptContinuation(_ continuation: AsyncStream<String>.Continuation) {
        self.transcriptContinuation = continuation
    }

    /// Sets the state continuation and emits current state (actor-isolated helper)
    private func setStateContinuationAndEmitCurrent(_ continuation: AsyncStream<ConversationState>.Continuation) {
        self.stateContinuation = continuation

        // Emit current state immediately
        let currentState: ConversationState
        switch sessionState {
        case .idle: currentState = .idle
        case .starting: currentState = .loading(progress: 0.5)
        case .running: currentState = .active(speaking: false, listening: true)
        case .stopping: currentState = .loading(progress: 0.0)
        }
        continuation.yield(currentState)
    }

    /// Load a persona configuration
    func loadPersona(_ persona: PersonaConfig) async throws {
        logger.info("Loading persona: \(persona.name)")
        currentPersona = persona

        // If session is running, we need to restart with new persona
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
        logger.info("Preparing PersonaPlex model")

        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)

        // Check if PersonaPlex is available
        guard FileManager.default.fileExists(atPath: personaPlexPath.path) else {
            throw ConversationError.modelNotFound(
                "PersonaPlex not found at \(personaPlexPath.path)"
            )
        }

        progress.completedUnitCount = 50
        progressCallback(progress)

        // Verify Python is available
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw ConversationError.pythonNotFound
        }

        progress.completedUnitCount = 100
        progressCallback(progress)

        modelPrepared = true
        logger.info("PersonaPlex model preparation complete")
    }

    /// Check if the model is ready
    func isModelReady() -> Bool {
        return modelPrepared &&
               FileManager.default.fileExists(atPath: personaPlexPath.path) &&
               FileManager.default.fileExists(atPath: pythonPath)
    }

    /// Cleanup all resources
    func cleanup() async {
        logger.info("Cleaning up ConversationClient resources")
        await stopSession()
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

    /// Launch the PersonaPlex MLX subprocess
    private func launchPersonaPlex(config: ConversationConfig) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)

        var args = [
            "-m", "personaplex_mlx.local",
            "-q", String(config.quantization),
        ]

        // Add persona prompt if specified
        if let textPrompt = config.persona.textPrompt, !textPrompt.isEmpty {
            args += ["--persona", textPrompt]
        }

        // Add voice preset or embedding file
        if let voicePath = config.persona.voiceEmbeddingPath {
            args += ["--voice-file", voicePath.path]
        } else if let voicePreset = config.persona.voicePreset {
            args += ["--voice", voicePreset]
        }

        // Add audio device IDs if specified
        if let inputDevice = config.inputDeviceID {
            args += ["--input-device", inputDevice]
        }
        if let outputDevice = config.outputDeviceID {
            args += ["--output-device", outputDevice]
        }

        process.arguments = args
        process.currentDirectoryURL = personaPlexPath

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"  // Ensure unbuffered output

        // If using bundled venv, set PYTHONPATH and VIRTUAL_ENV
        if let venvPath = bundledVenvPath {
            env["VIRTUAL_ENV"] = venvPath.path
            let sitePackages = venvPath.appendingPathComponent("lib/python3.11/site-packages")
            env["PYTHONPATH"] = "\(personaPlexPath.path):\(sitePackages.path)"
            logger.debug("Using bundled venv at: \(venvPath.path)")
        }

        // If using bundled model cache, set HF_HOME to use it
        if let modelCachePath = bundledModelCachePath {
            env["HF_HOME"] = modelCachePath.path
            env["HF_HUB_CACHE"] = modelCachePath.appendingPathComponent("hub").path
            logger.debug("Using bundled model cache at: \(modelCachePath.path)")
        }

        process.environment = env

        // Set up pipes
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Set up termination handler
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { [weak self] in
                await self?.handleProcessTermination(
                    exitCode: terminatedProcess.terminationStatus
                )
            }
        }

        logger.debug("Launching PersonaPlex: \(self.pythonPath) \(args.joined(separator: " "))")

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch PersonaPlex: \(error.localizedDescription)")
            throw ConversationError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        // Start reading output streams
        outputReadTask = Task { [weak self] in
            await self?.readOutputStream()
        }

        errorReadTask = Task { [weak self] in
            await self?.readErrorStream()
        }

        // Wait briefly for process to initialize
        try await Task.sleep(for: .milliseconds(500))

        // Check if process is still running
        guard process.isRunning else {
            let exitCode = process.terminationStatus
            throw ConversationError.launchFailed(
                "Process exited immediately with code \(exitCode)"
            )
        }
    }

    /// Read and process output from PersonaPlex
    private func readOutputStream() async {
        guard let outputPipe = outputPipe else { return }

        let handle = outputPipe.fileHandleForReading

        do {
            for try await line in handle.bytes.lines {
                await processOutputLine(line)
            }
        } catch {
            logger.debug("Output stream ended: \(error.localizedDescription)")
        }
    }

    /// Read and log stderr from PersonaPlex
    private func readErrorStream() async {
        guard let errorPipe = errorPipe else { return }

        let handle = errorPipe.fileHandleForReading

        do {
            for try await line in handle.bytes.lines {
                logger.debug("[PersonaPlex stderr] \(line)")
            }
        } catch {
            logger.debug("Error stream ended: \(error.localizedDescription)")
        }
    }

    /// Process a line of output from PersonaPlex
    private func processOutputLine(_ line: String) async {
        // Parse PersonaPlex output format:
        // [info] message - informational message
        // TOKEN: text - spoken text token
        // LAG - output buffer underrun
        // === PersonaPlex MLX Ready === - startup complete

        if line.hasPrefix("TOKEN: ") {
            let text = String(line.dropFirst(7))
            emitTranscript(text)
            logger.debug("Transcript token: \(text)")
        } else if line.hasPrefix("[info]") {
            let message = String(line.dropFirst(7))
            logger.info("[PersonaPlex] \(message)")
        } else if line == "LAG" {
            logger.warning("PersonaPlex output buffer underrun")
        } else if line.contains("PersonaPlex MLX Ready") {
            logger.info("PersonaPlex MLX initialization complete")
            emitState(.ready)
            // Short delay then transition to active
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                await self.emitState(.active(speaking: false, listening: true))
            }
        } else if line.contains("Speaking:") {
            emitState(.active(speaking: true, listening: true))
        } else if line.contains("Listening:") {
            emitState(.active(speaking: false, listening: true))
        } else {
            logger.debug("[PersonaPlex] \(line)")
        }
    }

    /// Handle process termination
    private func handleProcessTermination(exitCode: Int32) async {
        logger.info("PersonaPlex process terminated with exit code: \(exitCode)")

        // Cancel read tasks
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        outputReadTask = nil
        errorReadTask = nil

        // Clean up pipes
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        process = nil

        // Update state if not already stopping
        if sessionState != .stopping {
            sessionState = .idle
            if exitCode != 0 {
                emitState(.error("Process exited with code \(exitCode)"))
            } else {
                emitState(.idle)
            }
        }
    }

    /// Terminate the subprocess
    private func terminateProcess() async {
        guard let process = process else { return }

        if process.isRunning {
            logger.debug("Sending SIGTERM to PersonaPlex process")
            process.terminate()

            // Wait briefly for graceful shutdown
            try? await Task.sleep(for: .milliseconds(500))

            // Force kill if still running
            if process.isRunning {
                logger.warning("PersonaPlex did not terminate gracefully, sending SIGKILL")
                process.interrupt()
            }
        }

        // Cancel read tasks
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        outputReadTask = nil
        errorReadTask = nil

        // Clean up
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        self.process = nil
    }
}

// MARK: - Errors

/// Errors that can occur in the ConversationClient
enum ConversationError: LocalizedError {
    case sessionAlreadyActive
    case noActiveSession
    case modelNotFound(String)
    case pythonNotFound
    case launchFailed(String)
    case communicationError(String)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "A conversation session is already active"
        case .noActiveSession:
            return "No conversation session is active"
        case .modelNotFound(let details):
            return "PersonaPlex model not found: \(details)"
        case .pythonNotFound:
            return "Python interpreter not found"
        case .launchFailed(let details):
            return "Failed to launch PersonaPlex: \(details)"
        case .communicationError(let details):
            return "Communication error: \(details)"
        }
    }
}
