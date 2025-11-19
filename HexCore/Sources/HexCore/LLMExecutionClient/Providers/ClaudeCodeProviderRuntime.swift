import Foundation

struct ClaudeCodeProviderRuntime: LLMProviderRuntime {
    private let logger = HexLog.llm

    func run(
        config: LLMTransformationConfig,
        input: String,
        provider: LLMProvider,
        toolingPolicy: ToolingPolicy,
        toolServerEndpoint: HexToolServerEndpoint?,
        capabilities: LLMProviderCapabilities
    ) async throws -> String {
        guard let binaryPath = provider.binaryPath else {
            throw LLMExecutionError.invalidConfiguration("Provider has no binary path")
        }

        let wrappedPrompt = buildLLMUserPrompt(config: config, input: input)
        logger.info("Launching Claude CLI provider: \(provider.id)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: (binaryPath as NSString).expandingTildeInPath)
        var arguments = ["-p", "--output-format", "json"]
        if let model = provider.defaultModel {
            arguments.append(contentsOf: ["--model", model])
        }
        process.arguments = arguments

        if let workingDir = provider.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: (workingDir as NSString).expandingTildeInPath)
        }

        let claudeEnvironment = try prepareClaudeEnvironment(serverEndpoint: toolServerEndpoint)
        var preserveDebugArtifacts = false
        defer {
            if preserveDebugArtifacts {
                logger.error("Preserving Claude temp files for debugging at \(claudeEnvironment.rootDirectory.path)")
            } else {
                claudeEnvironment.cleanup()
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_SKIP_UPDATE_CHECK"] = "1"
        environment["PATH"] = buildExecutableSearchPath(existingPATH: environment["PATH"])
        environment["CLAUDE_CODE_DEBUG_LOGS_DIR"] = claudeEnvironment.debugLogFile.path
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        if let mcpConfigPath = claudeEnvironment.mcpConfigPath {
            process.arguments?.append(contentsOf: ["--mcp-config", mcpConfigPath.path])
        }

        if !toolingPolicy.allowedToolIdentifiers.isEmpty {
            let joined = toolingPolicy.allowedToolIdentifiers.sorted().joined(separator: ",")
            logger.info("Allowing Claude tools: \(joined)")
            process.arguments?.append(contentsOf: ["--allowed-tools", joined])
        }
        process.arguments?.append(contentsOf: ["--permission-mode", "bypassPermissions"])

        try process.run()

        if let data = wrappedPrompt.appending("\n").data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let timeout = TimeInterval(provider.timeoutSeconds ?? 20)
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        if process.isRunning {
            logger.error("Claude CLI timed out after \(timeout)s")
            process.terminate()
            throw LLMExecutionError.timeout
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            preserveDebugArtifacts = true
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorMessage = message?.isEmpty == false ? message! : "Claude CLI exited with code \(process.terminationStatus)"
            throw LLMExecutionError.processFailed(errorMessage)
        }

        guard !stdoutData.isEmpty else {
            throw LLMExecutionError.invalidOutput
        }

        if let parsed = try? decodeClaudeOutput(from: stdoutData) {
            logger.info("Claude returned \(parsed.count) chars (parsed JSON)")
            return parsed
        }

        guard let fallback = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty else {
            throw LLMExecutionError.invalidOutput
        }

        logger.info("Claude returned \(fallback.count) chars (raw text)")
        return fallback
    }
}

private struct ClaudeEnvironmentContext {
    let rootDirectory: URL
    let mcpConfigPath: URL?
    let debugLogFile: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

private func prepareClaudeEnvironment(serverEndpoint: HexToolServerEndpoint?) throws -> ClaudeEnvironmentContext {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("hex-claude-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)

    let debugDirectory = base.appendingPathComponent("debug", isDirectory: true)
    try fm.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
    let debugLogFile = debugDirectory.appendingPathComponent("claude.log")
    if !fm.fileExists(atPath: debugLogFile.path) {
        fm.createFile(atPath: debugLogFile.path, contents: Data())
    }

    var mcpConfigPath: URL?
    if let serverEndpoint {
        let configURL = base.appendingPathComponent(".mcp.json")
        let configuration = ClaudeMCPConfiguration(serverEndpoint: serverEndpoint)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: configURL, options: .atomic)
        mcpConfigPath = configURL
    }

    return ClaudeEnvironmentContext(
        rootDirectory: base,
        mcpConfigPath: mcpConfigPath,
        debugLogFile: debugLogFile
    )
}

private func buildExecutableSearchPath(existingPATH: String?) -> String {
    let existingEntries = existingPATH?
        .split(separator: ":")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        ?? []

    let fallbackEntries = defaultExecutableDirectories()
    let merged = dedupePaths(fallbackEntries + existingEntries)
    return merged.joined(separator: ":")
}

private func defaultExecutableDirectories() -> [String] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var candidates: [String] = []

    candidates.append(contentsOf: nvmExecutableDirectories(homeDirectory: home))

    let brewPrefixes = ["/usr/local/opt", "/opt/homebrew/opt"]
    for prefix in brewPrefixes {
        let path = "\(prefix)/claude/bin"
        if fm.fileExists(atPath: path) {
            candidates.append(path)
        }
    }

    candidates.append("/usr/local/bin")
    candidates.append("/opt/homebrew/bin")
    candidates.append("/usr/bin")
    candidates.append("/bin")

    return candidates
}

private func nvmExecutableDirectories(homeDirectory: String) -> [String] {
    let fm = FileManager.default
    var directories: [String] = []
    let nvmDir = "\(homeDirectory)/.nvm"
    let currentDir = "\(nvmDir)/versions/node/current/bin"
    let versionsDir = "\(nvmDir)/versions/node"

    if fm.fileExists(atPath: currentDir) {
        directories.append(currentDir)
    }

    if let versionFolders = try? fm.contentsOfDirectory(atPath: versionsDir) {
        for version in versionFolders.sorted(by: >) {
            guard !version.hasPrefix(".") else { continue }
            let versionDir = (versionsDir as NSString).appendingPathComponent("\(version)/bin")
            directories.append(versionDir)
        }
    }

    return directories
}

private func dedupePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for path in paths {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let normalized = (trimmed as NSString).standardizingPath
        if seen.insert(normalized).inserted {
            ordered.append(normalized)
        }
    }
    return ordered
}

private struct ClaudeMCPConfiguration: Encodable {
    struct Server: Encodable {
        let type: String
        let url: String
    }

    let mcpServers: [String: Server]

    init(serverEndpoint: HexToolServerEndpoint) {
        self.mcpServers = [
            serverEndpoint.serverName: Server(
                type: "http",
                url: serverEndpoint.baseURL.absoluteString
            )
        ]
    }
}

private struct ClaudeCLIEnvelope: Decodable {
    struct Message: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }
        let content: [Content]
    }

    let type: String?
    let result: String?
    let message: Message?
    let contentMessage: Message?

    enum CodingKeys: String, CodingKey {
        case type
        case result
        case message
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        message = try container.decodeIfPresent(Message.self, forKey: .message)
        contentMessage = try container.decodeIfPresent(Message.self, forKey: .content)
    }
}

private func decodeClaudeOutput(from data: Data) throws -> String {
    let decoder = JSONDecoder()
    if let envelope = try? decoder.decode(ClaudeCLIEnvelope.self, from: data) {
        if let result = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            return result
        }
        if let message = envelope.message ?? envelope.contentMessage {
            let text = message.content.compactMap { $0.text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
    } else {
        if let lastLine = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
           let lineData = lastLine.data(using: .utf8),
           let envelope = try? decoder.decode(ClaudeCLIEnvelope.self, from: lineData) {
            if let result = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                return result
            }
            if let message = envelope.message ?? envelope.contentMessage {
                let text = message.content.compactMap { $0.text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }
    }
    throw LLMExecutionError.invalidOutput
}
