import Dependencies
import Foundation
import Logging

public struct LLMExecutionClient: Sendable {
    public var run: @Sendable (
        _ config: LLMTransformationConfig,
        _ input: String,
        _ providers: [LLMProvider],
        _ toolServer: HexToolServerClient
    ) async throws -> String
}

extension LLMExecutionClient: DependencyKey {
    public static let liveValue = LLMExecutionClient(
        run: { config, input, providers, toolServer in
            try await runClaudeCode(
                config: config,
                input: input,
                providers: providers,
                toolServer: toolServer
            )
        }
    )
    
    public static let testValue = LLMExecutionClient(
        run: { _, _, _, _ in
            return "Test Output"
        }
    )
}

public extension DependencyValues {
    var llmExecution: LLMExecutionClient {
        get { self[LLMExecutionClient.self] }
        set { self[LLMExecutionClient.self] = newValue }
    }
}

// MARK: - Implementation

private let logger = HexLog.transcription

private func runClaudeCode(
  config: LLMTransformationConfig,
  input: String,
  providers: [LLMProvider],
  toolServer: HexToolServerClient
) async throws -> String {
  logger.info("runClaudeCode called with \(providers.count) providers, looking for: \(config.providerID)")

  guard let provider = providers.first(where: { $0.id == config.providerID }) else {
    logger.error("Provider not found: \(config.providerID)")
    throw LLMExecutionError.providerNotFound(config.providerID)
  }

  guard provider.type == .claudeCode else {
    throw LLMExecutionError.unsupportedProvider(provider.type.rawValue)
  }

  guard let binaryPath = provider.binaryPath else {
    throw LLMExecutionError.invalidConfiguration("Provider has no binary path")
  }

  let userPrompt = config.promptTemplate.replacingOccurrences(of: "{{input}}", with: input)
  let wrappedPrompt = """
\(userPrompt)

IMPORTANT: Output ONLY the final result. Do not include any preamble like "Here is the cleaned text:" or "I'll clean up this transcription". Just output the transformed text directly.
"""
  
  logger.info("Found provider: \(provider.id), binary: \(binaryPath)")
  logger.debug("Sending prompt to LLM (first 200 chars): \(String(wrappedPrompt.prefix(200)))")

  let process = Process()
  process.executableURL = URL(fileURLWithPath: binaryPath)
  var arguments = ["-p", "--output-format", "json"]
  if let model = provider.defaultModel {
    arguments.append(contentsOf: ["--model", model])
  }
  process.arguments = arguments

  if let workingDir = provider.workingDirectory {
    process.currentDirectoryURL = URL(fileURLWithPath: (workingDir as NSString).expandingTildeInPath)
  }

  let serverConfiguration = provider.tooling?.serverConfiguration()
  if let groups = serverConfiguration?.enabledToolGroups {
    logger.info("Configuring MCP server with tool groups: \(groups.map(\.rawValue))")
  } else {
    logger.info("Configuring MCP server with no additional tool groups")
  }
  let toolEndpoint = try await toolServer.ensureServer(serverConfiguration)
  logger.info("MCP server ready at \(toolEndpoint.baseURL)")
  let claudeEnvironment = try prepareClaudeEnvironment(serverEndpoint: toolEndpoint)
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
  
  if let groups = provider.tooling?.enabledToolGroups {
    let allowedTools = Set(groups.flatMap { $0.toolIdentifiers })
    if !allowedTools.isEmpty {
      let joined = allowedTools.sorted().joined(separator: ",")
      logger.info("Allowing Claude tools: \(joined)")
      process.arguments?.append(contentsOf: ["--allowed-tools", joined])
    }
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
    let errorMessage = message?.isEmpty == false ? message! : "Claude CLI exited with code \(process.terminationStatus) and no error output"
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

  let staticPaths = [
    "~/.claude/local/node_modules/.bin",
    "~/.local/bin",
    "~/.local/share/pnpm",
    "~/.config/yarn/global/node_modules/.bin",
    "~/.volta/bin",
    "~/.asdf/shims",
    "~/.asdf/bin",
    "~/.cargo/bin",
    "~/.deno/bin",
    "~/.pnpm-global/5/node_modules/.bin",
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin"
  ]

  candidates.append(contentsOf: staticPaths.map { ($0 as NSString).expandingTildeInPath })

  return candidates.filter { path in
    var isDirectory: ObjCBool = false
    return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }
}

private func nvmExecutableDirectories(homeDirectory: String) -> [String] {
  let fm = FileManager.default
  let nvmDir = (homeDirectory as NSString).appendingPathComponent(".nvm")
  let versionsDir = (nvmDir as NSString).appendingPathComponent("versions/node")
  var isDirectory: ObjCBool = false
  guard fm.fileExists(atPath: versionsDir, isDirectory: &isDirectory), isDirectory.boolValue else {
    return []
  }

  var directories: [String] = []

  let aliasPath = (nvmDir as NSString).appendingPathComponent("alias/default")
  if let aliasContents = try? String(contentsOfFile: aliasPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines),
     !aliasContents.isEmpty
  {
    let defaultDir = (versionsDir as NSString).appendingPathComponent("\(aliasContents)/bin")
    directories.append(defaultDir)
  }

  let currentDir = (versionsDir as NSString).appendingPathComponent("current/bin")
  directories.append(currentDir)

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

private func decodeClaudeOutput(from data: Data) throws -> String {
  let decoder = JSONDecoder()
  if let envelope = try? decoder.decode(ClaudeCLIEnvelope.self, from: data) {
    // New format: top-level "result" field
    if let result = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
      return result
    }
    // Old format: "message" or "content" with nested content array
    if let message = envelope.message ?? envelope.contentMessage {
      let text = message.content.compactMap { $0.text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return text
      }
    }
  } else {
    // CLI sometimes emits multiple JSON objects separated by newlines; try the last one.
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

public enum LLMExecutionError: Error, LocalizedError {
  case providerNotFound(String)
  case invalidConfiguration(String)
  case unsupportedProvider(String)
  case timeout
  case processFailed(String)
  case invalidOutput

  public var errorDescription: String? {
    switch self {
    case .providerNotFound(let id):
      return "LLM provider not found: \(id)"
    case .invalidConfiguration(let message):
      return "LLM provider configuration error: \(message)"
    case .unsupportedProvider(let type):
      return "LLM provider type \(type) is not supported yet"
    case .timeout:
      return "LLM execution timed out"
    case .processFailed(let message):
      return "LLM process failed: \(message)"
    case .invalidOutput:
      return "LLM returned invalid output"
    }
  }
}
