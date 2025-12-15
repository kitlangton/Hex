import Foundation

struct OllamaProviderRuntime: LLMProviderRuntime {
    private let logger = HexLog.llm

    func run(
        config: LLMTransformationConfig,
        input: String,
        provider: LLMProvider,
        toolingPolicy: ToolingPolicy,
        toolServerEndpoint _: HexToolServerEndpoint?,
        capabilities: LLMProviderCapabilities,
        mode _: TransformationMode?
    ) async throws -> String {
        guard let model = provider.defaultModel, !model.isEmpty else {
            throw LLMExecutionError.invalidConfiguration("Ollama provider missing defaultModel")
        }

        if capabilities.supportsToolCalling {
            logger.notice("Ollama provider marked as tool-capable but runtime currently text-only")
        }

        guard let executableURL = LLMExecutableLocator.resolveBinaryURL(for: provider) else {
            throw LLMExecutionError.invalidConfiguration(
                "Ollama binary not found. Install Ollama or set binaryPath."
            )
        }

        let prompt = buildLLMUserPrompt(config: config, input: input)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["run", model]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        var environment = ProcessInfo.processInfo.environment
        if environment["PATH"] == nil {
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        }
        process.environment = environment

        try process.run()
        
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        if let promptData = prompt.appending("\n").data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(promptData)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let timeout = TimeInterval(provider.timeoutSeconds ?? 60)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        if process.isRunning {
            logger.error("Ollama prompt timed out after \(timeout)s")
            process.terminate()
            throw LLMExecutionError.timeout
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errorText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = errorText?.isEmpty == false ? errorText! : "Ollama exited with code \(process.terminationStatus)"
            throw LLMExecutionError.processFailed(message)
        }

        guard let output = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            throw LLMExecutionError.invalidOutput
        }

        return output
    }
}
