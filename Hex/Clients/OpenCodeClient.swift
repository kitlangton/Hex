import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let openCodeLogger = HexLog.opencode

enum OpenCodeRuntimePhase: Equatable, Sendable {
  case idle
  case startingServer
  case ready
  case error(String)
}

struct OpenCodeModelOption: Equatable, Sendable, Identifiable {
  var id: String { value }
  let value: String
  let title: String
}

struct OpenCodeToolCall: Equatable, Sendable, Identifiable {
  let id: String
  let title: String
  let status: String
}

struct OpenCodeSessionActivity: Equatable, Sendable, Identifiable {
  enum Status: Equatable, Sendable {
    case listening
    case transcribing
    case queued
    case running
    case completed
    case error(String)
  }

  let id: String
  var sessionID: String?
  var command: String
  var status: Status
  var toolCalls: [OpenCodeToolCall]
  var responseText: String
}

struct OpenCodeRuntimeStatus: Equatable, Sendable {
  var phase: OpenCodeRuntimePhase
  var queuedCommands: Int
  var activeSessions: Int
  var activities: [OpenCodeSessionActivity]

  static let idle = Self(phase: .idle, queuedCommands: 0, activeSessions: 0, activities: [])
}

@DependencyClient
struct OpenCodeClient {
  var enqueueVoiceCommand: @Sendable (String, String, OpenCodeExperimentalSettings) async throws -> Void = { _, _, _ in }
  var observeStatus: @Sendable () async -> AsyncStream<OpenCodeRuntimeStatus> = { .finished }
  var isInstalled: @Sendable (OpenCodeExperimentalSettings) async -> Bool = { _ in false }
  var loadModels: @Sendable (OpenCodeExperimentalSettings) async throws -> [OpenCodeModelOption] = { _ in [] }
  var shutdownManagedServer: @Sendable () async -> Void = {}
}

extension OpenCodeClient: DependencyKey {
  static var liveValue: Self {
    let live = OpenCodeClientLive()
    return Self(
      enqueueVoiceCommand: { id, text, settings in
        try await live.enqueueVoiceCommand(id: id, text: text, settings: settings)
      },
      observeStatus: {
        await live.observeStatus()
      },
      isInstalled: { settings in
        await live.isInstalled(settings: settings)
      },
      loadModels: { settings in
        try await live.loadModels(settings: settings)
      },
      shutdownManagedServer: {
        await live.shutdownManagedServer()
      }
    )
  }
}

extension DependencyValues {
  var openCode: OpenCodeClient {
    get { self[OpenCodeClient.self] }
    set { self[OpenCodeClient.self] = newValue }
  }
}

private actor OpenCodeClientLive {
  private struct QueuedCommand {
    let id: String
    let text: String
    let configuration: ResolvedConfiguration
  }

  private struct ProvidersResponse: Decodable {
    let providers: [ProviderInfo]
  }

  private struct ProviderInfo: Decodable {
    let id: String
    let models: [String: ProviderModel]
  }

  private struct ProviderModel: Decodable {
    let id: String
    let name: String
    let status: String?
  }

  private struct SessionInfo: Decodable {
    let id: String
  }

  private struct RemoteSessionStatus: Decodable {
    let type: String
  }

  private struct RemoteMessageListItem: Decodable {
    let info: RemoteMessageInfo
    let parts: [RemotePart]
  }

  private struct RemoteMessageInfo: Decodable {
    let id: String
    let role: String
    let error: RemoteMessageError?
  }

  private struct RemoteMessageError: Decodable {
    let message: String?
  }

  private struct RemotePart: Decodable {
    let id: String
    let type: String
    let text: String?
    let tool: String?
    let state: RemoteToolState?
  }

  private struct RemoteToolState: Decodable {
    let status: String
    let title: String?
    let error: String?
  }

  private struct PermissionRule: Encodable {
    let permission: String
    let pattern: String
    let action: String
  }

  private struct CreateSessionRequest: Encodable {
    let title: String
    let permission: [PermissionRule]
  }

  private struct PromptModel: Encodable {
    let providerID: String
    let modelID: String
  }

  private struct PromptPart: Encodable {
    let type: String
    let text: String
  }

  private struct PromptAsyncRequest: Encodable {
    let agent: String
    let model: PromptModel?
    let system: String
    let parts: [PromptPart]
  }

  private struct ResolvedConfiguration {
    let serverURL: URL
    let launchPath: String
    let directory: String
    let workspaceDidChange: Bool
    let model: PromptModel?
    let systemPrompt: String
    let permissionRules: [PermissionRule]
  }

  private var queue: [QueuedCommand] = []
  private var isProcessingQueue = false
  private var activeSessions: Set<String> = []
  private var monitoringTasks: [String: Task<Void, Never>] = [:]
  private var observers: [UUID: AsyncStream<OpenCodeRuntimeStatus>.Continuation] = [:]
  private var runtimeStatus: OpenCodeRuntimeStatus = .idle
  private var managedProcess: Process?
  private var managedOutputPipe: Pipe?
  private var managedServerURL: URL?
  private var expectedManagedExitProcessID: Int32?
  private var eventListenerTask: Task<Void, Never>?
  private var eventListenerServerURL: URL?
  private var terminalEvents: [String: OpenCodeSessionActivity.Status] = [:]
  private var managedWorkspaceDidChange = false
  private var isRestartingManagedServer = false
  private var recentLogOutput = ""
  private var activities: [OpenCodeSessionActivity] = []

  func enqueueVoiceCommand(id: String, text: String, settings: OpenCodeExperimentalSettings) async throws {
    let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return }

    let configuration = try resolve(settings: settings)
    queue.append(.init(id: id, text: command, configuration: configuration))
    upsertActivity(.init(id: id, sessionID: nil, command: command, status: .queued, toolCalls: [], responseText: ""))
    publish(phase: currentPhaseAfterEnqueue())

    if !isProcessingQueue {
      isProcessingQueue = true
      Task { await self.processQueue() }
    }
  }

  func observeStatus() -> AsyncStream<OpenCodeRuntimeStatus> {
    let id = UUID()
    return AsyncStream { continuation in
      continuation.yield(runtimeStatus)
      observers[id] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeObserver(id) }
      }
    }
  }

  func isInstalled(settings: OpenCodeExperimentalSettings) async -> Bool {
    _ = try? URL.hexOpenCodeWorkspaceDirectory

    // Skip filesystem checks for the install path here. The sandbox can make those
    // misleading, and we validate the launch path when starting the managed server.
    let launchPath = settings.launchPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return !launchPath.isEmpty
  }

  func loadModels(settings: OpenCodeExperimentalSettings) async throws -> [OpenCodeModelOption] {
    let configuration = try resolve(settings: settings)
    try await ensureServerAvailable(for: configuration)

    guard var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false) else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }
    components.path = "/config/providers"
    components.queryItems = [URLQueryItem(name: "directory", value: configuration.directory)]
    guard let url = components.url else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data, expectedStatusCodes: [200])
    let decoded = try JSONDecoder().decode(ProvidersResponse.self, from: data)

    return decoded.providers
      .flatMap { provider in
        provider.models.values.map { model in
          OpenCodeModelOption(
            value: "\(provider.id)/\(model.id)",
            title: "\(model.name) (\(provider.id)/\(model.id))"
          )
        }
      }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  func shutdownManagedServer() async {
    guard let managedProcess else { return }
    expectedManagedExitProcessID = managedProcess.processIdentifier
    managedOutputPipe?.fileHandleForReading.readabilityHandler = nil
    if managedProcess.isRunning {
      managedProcess.terminate()
      for _ in 0..<20 {
        if !managedProcess.isRunning { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      if managedProcess.isRunning {
        managedProcess.interrupt()
        for _ in 0..<10 {
          if !managedProcess.isRunning { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    }
    self.managedProcess = nil
    self.managedOutputPipe = nil
    self.managedServerURL = nil
    eventListenerTask?.cancel()
    eventListenerTask = nil
    eventListenerServerURL = nil
    terminalEvents.removeAll()
    for task in monitoringTasks.values { task.cancel() }
    monitoringTasks.removeAll()
    activeSessions.removeAll()
    publish(phase: .idle)
  }

  private func processQueue() async {
    while !queue.isEmpty {
      let item = queue.removeFirst()

      do {
        setActivityStatus(id: item.id, status: .running)
        try await ensureServerAvailable(for: item.configuration)
        let sessionID = try await createSession(item.configuration)
        setActivitySessionID(id: item.id, sessionID: sessionID)
        try await promptAsync(sessionID: sessionID, command: item.text, configuration: item.configuration)

        activeSessions.insert(sessionID)
        publish(phase: .ready)
        monitoringTasks[sessionID] = Task { await self.monitorSession(activityID: item.id, sessionID: sessionID, configuration: item.configuration) }
        openCodeLogger.notice("Queued OpenCode voice command for session \(sessionID, privacy: .public) directory=\(item.configuration.directory, privacy: .public)")
      } catch {
        setActivityStatus(id: item.id, status: .error(error.localizedDescription))
        publish(phase: .error(error.localizedDescription))
        openCodeLogger.error("OpenCode queue submission failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    isProcessingQueue = false
    publish(phase: activeSessions.isEmpty ? .idle : .ready)
  }

  private func monitorSession(activityID: String, sessionID: String, configuration: ResolvedConfiguration) async {
    defer {
      activeSessions.remove(sessionID)
      monitoringTasks[sessionID] = nil
      terminalEvents[sessionID] = nil
      // Ensure activity is marked completed if it wasn't already
      if let index = activities.firstIndex(where: { $0.id == activityID }),
         activities[index].status == .running || activities[index].status == .queued {
        activities[index].status = .completed
      }
      publish(phase: queue.isEmpty && activeSessions.isEmpty ? .idle : .ready)
    }

    for _ in 0..<900 {
      guard !Task.isCancelled else { return }

      ensureEventListener(for: configuration.serverURL)

      if let terminal = terminalEvents.removeValue(forKey: sessionID) {
        setActivityStatus(id: activityID, status: terminal)
        return
      }

      let messages: [RemoteMessageListItem]
      do {
        messages = try await fetchSessionMessages(sessionID: sessionID, configuration: configuration)
      } catch {
        openCodeLogger.error("OpenCode message poll failed for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        try? await Task.sleep(for: .seconds(1))
        continue
      }

      updateActivityContent(id: activityID, messages: messages)

      // Detect completion by checking for step-finish part or error in the assistant message
      if let assistant = messages.last(where: { $0.info.role == "assistant" }) {
        let hasStepFinish = assistant.parts.contains { $0.type == "step-finish" }
        let errorMessage = assistant.info.error?.message
        let hasError = errorMessage != nil && !(errorMessage?.isEmpty ?? true)

        if hasStepFinish || hasError {
          setActivityStatus(id: activityID, status: hasError ? .error(errorMessage!) : .completed)
          return
        }
      }

      try? await Task.sleep(for: .seconds(1))
    }

    setActivityStatus(id: activityID, status: .error("Timed out waiting for OpenCode to respond."))
  }

  private func ensureEventListener(for serverURL: URL) {
    if eventListenerServerURL == serverURL,
       let eventListenerTask,
       !eventListenerTask.isCancelled
    {
      return
    }

    eventListenerTask?.cancel()
    eventListenerServerURL = serverURL
    eventListenerTask = Task { await self.runEventListener(serverURL: serverURL) }
  }

  private func runEventListener(serverURL: URL) async {
    defer {
      if eventListenerServerURL == serverURL {
        eventListenerTask = nil
        eventListenerServerURL = nil
      }
    }

    do {
      guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
        return
      }
      components.path = "/event"
      guard let url = components.url else { return }

      var request = URLRequest(url: url)
      request.timeoutInterval = 0
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        openCodeLogger.error("OpenCode event stream returned a non-HTTP response")
        return
      }
      guard httpResponse.statusCode == 200 else {
        openCodeLogger.error("OpenCode event stream returned status \(httpResponse.statusCode)")
        return
      }

      openCodeLogger.notice("Connected to OpenCode event stream at \(serverURL.absoluteString, privacy: .public)")

      for try await line in bytes.lines {
        guard !Task.isCancelled else { return }
        guard line.hasPrefix("data: ") else { continue }
        handleEventLine(String(line.dropFirst(6)))
      }
    } catch is CancellationError {
      return
    } catch {
      openCodeLogger.error("OpenCode event stream failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func handleEventLine(_ line: String) {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String,
          let properties = json["properties"] as? [String: Any]
    else {
      return
    }

    switch type {
    case "server.connected", "server.heartbeat":
      openCodeLogger.notice("OpenCode event: \(type, privacy: .public)")

    case "session.status":
      guard let sessionID = properties["sessionID"] as? String,
            let status = properties["status"] as? [String: Any],
            let statusType = status["type"] as? String
      else {
        return
      }
      openCodeLogger.notice("OpenCode event: session.status session=\(sessionID, privacy: .public) status=\(statusType, privacy: .public)")
      if statusType == "idle" {
        terminalEvents[sessionID] = .completed
      }

    case "session.error":
      guard let sessionID = properties["sessionID"] as? String else {
        let message = ((properties["error"] as? [String: Any])?["data"] as? [String: Any])?["message"] as? String
          ?? ((properties["error"] as? [String: Any])?["name"] as? String)
          ?? "OpenCode session failed."
        openCodeLogger.error("OpenCode event: session.error without sessionID: \(message, privacy: .public)")
        publish(phase: .error(message))
        return
      }
      let message = ((properties["error"] as? [String: Any])?["data"] as? [String: Any])?["message"] as? String
        ?? ((properties["error"] as? [String: Any])?["name"] as? String)
        ?? "OpenCode session failed."
      openCodeLogger.error("OpenCode event: session.error session=\(sessionID, privacy: .public) message=\(message, privacy: .public)")
      terminalEvents[sessionID] = .error(message)

    default:
      if let sessionID = properties["sessionID"] as? String {
        openCodeLogger.notice("OpenCode event: \(type, privacy: .public) session=\(sessionID, privacy: .public)")
      } else {
        openCodeLogger.notice("OpenCode event: \(type, privacy: .public)")
      }
      break
    }
  }

  private func fetchSessionMessages(sessionID: String, configuration: ResolvedConfiguration) async throws -> [RemoteMessageListItem] {
    guard var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false) else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    components.path = "/session/\(sessionID)/message"
    components.queryItems = [URLQueryItem(name: "directory", value: configuration.directory)]

    guard let url = components.url else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data, expectedStatusCodes: [200])
    return try JSONDecoder().decode([RemoteMessageListItem].self, from: data)
  }

  private func fetchSessionStatuses(configuration: ResolvedConfiguration) async throws -> [String: RemoteSessionStatus] {
    guard var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false) else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    components.path = "/session/status"
    components.queryItems = [URLQueryItem(name: "directory", value: configuration.directory)]

    guard let url = components.url else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data, expectedStatusCodes: [200])
    return try JSONDecoder().decode([String: RemoteSessionStatus].self, from: data)
  }

  private func ensureServerAvailable(for configuration: ResolvedConfiguration) async throws {
    if await isServerReachable(configuration.serverURL) {
      var shouldRestartManagedServer = false
      if shouldManageServer(for: configuration.serverURL) {
        shouldRestartManagedServer = configuration.workspaceDidChange
        if !shouldRestartManagedServer {
          shouldRestartManagedServer = await managedServerNeedsReload(for: configuration)
        }
      }
      if shouldRestartManagedServer {
        try await startManagedServer(for: configuration)
      }
      ensureEventListener(for: configuration.serverURL)
      publish(phase: .ready)
      return
    }

    guard shouldManageServer(for: configuration.serverURL) else {
      throw OpenCodeClientError.serverUnavailable(configuration.serverURL.absoluteString)
    }

    publish(phase: .startingServer)

    if let managedServerURL, managedServerURL == configuration.serverURL,
       let managedProcess, managedProcess.isRunning {
      if configuration.workspaceDidChange {
        try await startManagedServer(for: configuration)
      }
      try await waitForServer(configuration.serverURL)
      ensureEventListener(for: configuration.serverURL)
      publish(phase: .ready)
      return
    }

    try await startManagedServer(for: configuration)
    try await waitForServer(configuration.serverURL)
    ensureEventListener(for: configuration.serverURL)
    publish(phase: .ready)
  }

  private func managedServerNeedsReload(for configuration: ResolvedConfiguration) async -> Bool {
    guard shouldManageServer(for: configuration.serverURL) else { return false }

    let macToolFile = URL(fileURLWithPath: configuration.directory, isDirectory: true)
      .appendingPathComponent(".opencode/tool/macos.ts")

    guard let existingToolSource = try? String(contentsOf: macToolFile),
          existingToolSource.contains("export const paste_text")
    else {
      return false
    }

    guard let toolIDs = try? await fetchToolIDs(configuration: configuration) else {
      return false
    }

    return !toolIDs.contains("macos_paste_text")
  }

  private func fetchToolIDs(configuration: ResolvedConfiguration) async throws -> [String] {
    guard var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false) else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    components.path = "/experimental/tool/ids"
    components.queryItems = [URLQueryItem(name: "directory", value: configuration.directory)]

    guard let url = components.url else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data, expectedStatusCodes: [200])
    return try JSONDecoder().decode([String].self, from: data)
  }

  private func startManagedServer(for configuration: ResolvedConfiguration) async throws {
    isRestartingManagedServer = true
    defer { isRestartingManagedServer = false }

    await shutdownManagedServer()
    recentLogOutput = ""

    let bunURL = try resolveBunURL()
    let launchURL = URL(fileURLWithPath: configuration.launchPath, isDirectory: true)
    guard FileManager.default.fileExists(atPath: launchURL.path) else {
      throw OpenCodeClientError.invalidLaunchPath(configuration.launchPath)
    }

    let host = configuration.serverURL.host() ?? "127.0.0.1"
    let port = configuration.serverURL.port() ?? 4096

    let process = Process()
    process.executableURL = bunURL
    process.currentDirectoryURL = launchURL
    process.arguments = [
      "run",
      "--cwd",
      "packages/opencode",
      "src/index.ts",
      "serve",
      "--hostname",
      host,
      "--port",
      String(port)
    ]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      let text = String(decoding: data, as: UTF8.self)
      Task { await self?.appendLog(text) }
    }

    process.terminationHandler = { [weak self] terminated in
      Task {
        await self?.handleManagedProcessExit(processID: terminated.processIdentifier, code: terminated.terminationStatus)
      }
    }

    try process.run()
    managedProcess = process
    managedOutputPipe = outputPipe
    managedServerURL = configuration.serverURL
    openCodeLogger.notice("Started managed OpenCode server at \(configuration.serverURL.absoluteString, privacy: .public)")
  }

  private func handleManagedProcessExit(processID: Int32, code: Int32) async {
    if expectedManagedExitProcessID == processID {
      expectedManagedExitProcessID = nil
      if managedProcess?.processIdentifier == processID {
        managedProcess = nil
        managedOutputPipe = nil
        managedServerURL = nil
      }
      return
    }

    if isRestartingManagedServer {
      return
    }

    if let managedProcess, managedProcess.processIdentifier != processID, managedProcess.isRunning {
      return
    }

    let serverURL = managedServerURL

    if managedProcess?.processIdentifier == processID {
      managedProcess = nil
      managedOutputPipe = nil
      managedServerURL = nil
    }

    if let serverURL {
      for _ in 0..<10 {
        if await isServerReachable(serverURL) {
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }

      if let message = sanitizedManagedServerExitMessage(code: code) {
        openCodeLogger.error("Managed OpenCode server exited: \(message, privacy: .public)")
      }
      return
    }

    if let message = sanitizedManagedServerExitMessage(code: code) {
      openCodeLogger.error("Managed OpenCode server exited: \(message, privacy: .public)")
    }
  }

  private func sanitizedManagedServerExitMessage(code: Int32) -> String? {
    let filteredLines = recentLogOutput
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { !$0.contains("OPENCODE_SERVER_PASSWORD is not set; server is unsecured.") }

    let detail = filteredLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if detail.isEmpty, code == 1 {
      return nil
    }

    if detail.isEmpty {
      return "Managed OpenCode server exited with code \(code)."
    }

    return "Managed OpenCode server exited with code \(code). \(detail)"
  }

  private func appendLog(_ text: String) {
    openCodeLogger.notice("server: \(text.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
    recentLogOutput += text
    if recentLogOutput.count > 4000 {
      recentLogOutput = String(recentLogOutput.suffix(4000))
    }
  }

  private func waitForServer(_ serverURL: URL) async throws {
    for _ in 0..<60 {
      if await isServerReachable(serverURL) {
        return
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
    throw OpenCodeClientError.serverStartTimedOut(serverURL.absoluteString)
  }

  private func isServerReachable(_ serverURL: URL) async -> Bool {
    guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
      return false
    }

    components.path = "/path"
    guard let url = components.url else { return false }

    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else { return false }
      return httpResponse.statusCode == 200
    } catch {
      return false
    }
  }

  private func resolve(settings: OpenCodeExperimentalSettings) throws -> ResolvedConfiguration {
    let trimmedServer = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let serverURL = URL(string: trimmedServer), serverURL.scheme != nil else {
      throw OpenCodeClientError.invalidServerURL(trimmedServer)
    }

    let trimmedLaunchPath = settings.launchPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDirectory = settings.directory.trimmingCharacters(in: .whitespacesAndNewlines)
    let directory = try resolvedWorkspaceDirectory(trimmedDirectory: trimmedDirectory)

    let trimmedInstructions = settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines)

    return ResolvedConfiguration(
      serverURL: serverURL,
      launchPath: trimmedLaunchPath,
      directory: directory,
      workspaceDidChange: managedWorkspaceDidChange,
      model: parseModel(settings.model),
      systemPrompt: systemPrompt(additionalInstructions: trimmedInstructions),
      permissionRules: permissionRules(from: settings.allowedTools)
    )
  }

  private func shouldManageServer(for serverURL: URL) -> Bool {
    guard serverURL.scheme?.lowercased() == "http" else { return false }
    guard let host = serverURL.host()?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "localhost"
  }

  private func resolveBunURL() throws -> URL {
    let pwHome = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) }
    let envHome = ProcessInfo.processInfo.environment["HOME"]
    let userHome = pwHome ?? envHome ?? "/Users/\(NSUserName())"

    let rawCandidates: [(String, String?)] = [
      ("BUN_PATH", ProcessInfo.processInfo.environment["BUN_PATH"]),
      ("OPENCODE_BUN_PATH", ProcessInfo.processInfo.environment["OPENCODE_BUN_PATH"]),
      ("/opt/homebrew/bin/bun", "/opt/homebrew/bin/bun"),
      ("/usr/local/bin/bun", "/usr/local/bin/bun"),
      ("~/.bun/bin/bun", userHome + "/.bun/bin/bun"),
    ]

    let candidates = rawCandidates
      .compactMap(\.1)
      .map { URL(fileURLWithPath: $0) }

    if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
      return match
    }
    if let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
      return match
    }
    guard let match = candidates.first else {
      throw OpenCodeClientError.bunNotFound
    }
    return match
  }

  private func resolvedWorkspaceDirectory(trimmedDirectory: String) throws -> String {
    if !trimmedDirectory.isEmpty {
      try FileManager.default.createDirectory(at: URL(fileURLWithPath: trimmedDirectory, isDirectory: true), withIntermediateDirectories: true)
      managedWorkspaceDidChange = false
      return trimmedDirectory
    }

    let workspace = try URL.hexOpenCodeWorkspaceDirectory
    managedWorkspaceDidChange = setupWorkspaceFiles(at: workspace)
    return workspace.path
  }

  private func setupWorkspaceFiles(at workspace: URL) -> Bool {
    let fm = FileManager.default
    var changed = false

    let pasteToolSource = ##"""

    export const paste_text = tool({
      description: "Paste text into the current macOS application by copying it to the clipboard and pressing Command-V.",
      args: {
        text: tool.schema.string().describe("The exact text to paste into the frontmost app"),
      },
      async execute(args) {
        const copy = Bun.spawn(["/bin/sh", "-lc", `printf %s ${JSON.stringify(args.text)} | pbcopy`])
        await copy.exited
        if (copy.exitCode !== 0) {
          return `Failed to copy text for pasting (exit ${copy.exitCode})`
        }

        const paste = Bun.spawn([
          "osascript",
          "-e",
          'tell application "System Events" to keystroke "v" using command down',
        ])
        const stderr = await new Response(paste.stderr).text()
        await paste.exited
        if (paste.exitCode !== 0) {
          return `Failed to paste text: ${stderr.trim()}`
        }

        return "Pasted text into the current application"
      },
    })
    """##

    let agentsMD = workspace.appendingPathComponent("AGENTS.md")
    if !fm.fileExists(atPath: agentsMD.path) {
      let content = """
      # Hex Voice Assistant

      You are a voice-controlled macOS assistant powered by Hex.
      The user speaks commands, which Hex transcribes and sends to you.

      ## Your Role

      - Execute spoken commands on this Mac quickly and directly
      - Prefer taking action over explaining what you would do
      - Use shell commands: `open`, `open -a`, `mdfind`, `osascript`, `ls`, `pbcopy`, `pbpaste`
      - Keep responses brief — the user sees them in a small overlay

      ## Capabilities

      You have shell access. Common patterns:

      - **Open apps:** `open -a "Safari"`, `open -a "Slack"`
      - **Open URLs:** `open "https://example.com"`
      - **Find files:** `mdfind "kind:pdf budget"`, `mdfind -name "report.xlsx"`
      - **Find apps:** `mdfind "kind:application" -name "Zoom"`
      - **AppleScript:** `osascript -e 'tell application "Finder" to ...'`
      - **Clipboard:** `pbcopy`, `pbpaste`
      - **System info:** `sw_vers`, `system_profiler SPHardwareDataType`

      ## Memories

      You can save and retrieve persistent notes in the `memories/` directory.
      Use this to remember user preferences, frequently used apps, or anything
      the user asks you to remember for later.

      - To save: write a markdown file to `memories/`
      - To recall: read files from `memories/`
      - Organize by topic: `memories/preferences.md`, `memories/projects.md`, etc.

      ## Guidelines

      - Never ask for confirmation — act on the command directly
      - If a command is ambiguous, make your best guess and act
      - For destructive actions (delete files, kill processes), confirm first
      - When the user says "open X", try the most common interpretation
      - Keep file edits within this workspace unless explicitly asked otherwise
      """
      try? content.write(to: agentsMD, atomically: true, encoding: .utf8)
      changed = true
    }

    let memoriesDir = workspace.appendingPathComponent("memories")
    try? fm.createDirectory(at: memoriesDir, withIntermediateDirectories: true)

    let configFile = workspace.appendingPathComponent(".opencode/opencode.jsonc")
    if !fm.fileExists(atPath: configFile.path) {
      let config = """
      {
        "$schema": "https://opencode.ai/config.json",
        "provider": {
          "opencode": {
            "options": {}
          }
        },
        "permission": {
          "edit": {
            "*": "allow"
          }
        },
        "mcp": {},
        "tools": {}
      }
      """
      try? config.write(to: configFile, atomically: true, encoding: .utf8)
      changed = true
    }

    let macToolFile = workspace.appendingPathComponent(".opencode/tool/macos.ts")
    if !fm.fileExists(atPath: macToolFile.path) {
      let toolSource = ##"""
      import { tool } from "@opencode-ai/plugin"

      export const open_application = tool({
        description: "Open a macOS application by name",
        args: {
          name: tool.schema.string().describe("Application name, e.g. 'Safari', 'Slack', 'Visual Studio Code'"),
        },
        async execute(args) {
          const proc = Bun.spawn(["open", "-a", args.name])
          await proc.exited
          return proc.exitCode === 0
            ? `Opened ${args.name}`
            : `Failed to open ${args.name} (exit ${proc.exitCode})`
        },
      })

      export const open_url = tool({
        description: "Open a URL in the default browser",
        args: {
          url: tool.schema.string().describe("Full URL to open, e.g. 'https://github.com'"),
        },
        async execute(args) {
          const proc = Bun.spawn(["open", args.url])
          await proc.exited
          return proc.exitCode === 0 ? `Opened ${args.url}` : `Failed to open URL`
        },
      })

      export const find_files = tool({
        description: "Search for files on this Mac using Spotlight (mdfind)",
        args: {
          query: tool.schema.string().describe("Spotlight search query, e.g. 'kind:pdf budget 2024' or 'kind:application Zoom'"),
          limit: tool.schema.number().describe("Max results to return").default(10),
        },
        async execute(args) {
          const proc = Bun.spawn(["mdfind", args.query])
          const text = await new Response(proc.stdout).text()
          await proc.exited
          const results = text.trim().split("\n").filter(Boolean).slice(0, args.limit)
          return results.length > 0
            ? results.join("\n")
            : "No files found"
        },
      })

      export const run_applescript = tool({
        description: "Run an AppleScript command for macOS automation (window management, app control, system dialogs)",
        args: {
          script: tool.schema.string().describe("AppleScript source code to execute"),
        },
        async execute(args) {
          const proc = Bun.spawn(["osascript", "-e", args.script])
          const stdout = await new Response(proc.stdout).text()
          const stderr = await new Response(proc.stderr).text()
          await proc.exited
          if (proc.exitCode !== 0) {
            return `Error: ${stderr.trim()}`
          }
          return stdout.trim() || "OK"
        },
      })

      export const paste_text = tool({
        description: "Paste text into the current macOS application by copying it to the clipboard and pressing Command-V.",
        args: {
          text: tool.schema.string().describe("The exact text to paste into the frontmost app"),
        },
        async execute(args) {
          const copy = Bun.spawn(["/bin/sh", "-lc", `printf %s ${JSON.stringify(args.text)} | pbcopy`])
          await copy.exited
          if (copy.exitCode !== 0) {
            return `Failed to copy text for pasting (exit ${copy.exitCode})`
          }

          const paste = Bun.spawn([
            "osascript",
            "-e",
            'tell application "System Events" to keystroke "v" using command down',
          ])
          const stderr = await new Response(paste.stderr).text()
          await paste.exited
          if (paste.exitCode !== 0) {
            return `Failed to paste text: ${stderr.trim()}`
          }

          return "Pasted text into the current application"
        },
      })

      export const manage_memory = tool({
        description: "Save or retrieve persistent memories. Use 'save' to store info the user wants remembered, 'list' to see all memories, 'read' to recall a specific memory file.",
        args: {
          action: tool.schema.enum(["save", "read", "list"]).describe("Action to perform"),
          filename: tool.schema.string().describe("Memory filename (without path), e.g. 'preferences.md'").optional(),
          content: tool.schema.string().describe("Content to save (for 'save' action)").optional(),
        },
        async execute(args, context) {
          const memoriesDir = `${context.directory}/memories`
          await Bun.spawn(["mkdir", "-p", memoriesDir]).exited

          switch (args.action) {
            case "list": {
              const proc = Bun.spawn(["ls", "-1", memoriesDir])
              const text = await new Response(proc.stdout).text()
              await proc.exited
              const files = text.trim()
              return files || "No memories saved yet"
            }
            case "read": {
              if (!args.filename) return "Error: filename required for read"
              const path = `${memoriesDir}/${args.filename}`
              try {
                return await Bun.file(path).text()
              } catch {
                return `Memory file not found: ${args.filename}`
              }
            }
            case "save": {
              if (!args.filename) return "Error: filename required for save"
              if (!args.content) return "Error: content required for save"
              const path = `${memoriesDir}/${args.filename}`
              await Bun.write(path, args.content)
              return `Saved to ${args.filename}`
            }
          }
        },
      })
      """##
      try? toolSource.write(to: macToolFile, atomically: true, encoding: .utf8)
      changed = true
    } else if let existingToolSource = try? String(contentsOf: macToolFile),
              !existingToolSource.contains("export const paste_text") {
      try? (existingToolSource + pasteToolSource).write(to: macToolFile, atomically: true, encoding: .utf8)
      changed = true
    }

    return changed
  }

  private func createSession(_ configuration: ResolvedConfiguration) async throws -> String {
    let requestBody = CreateSessionRequest(
      title: "Hex Voice Action",
      permission: configuration.permissionRules
    )
    let request = try makeRequest(
      configuration: configuration,
      path: "/session",
      method: "POST",
      body: requestBody
    )

    openCodeLogger.notice("Creating OpenCode session for directory \(configuration.directory, privacy: .public)")

    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data, expectedStatusCodes: [200])
    return try JSONDecoder().decode(SessionInfo.self, from: data).id
  }

  private func promptAsync(
    sessionID: String,
    command: String,
    configuration: ResolvedConfiguration
  ) async throws {
    let requestBody = PromptAsyncRequest(
      agent: "build",
      model: configuration.model,
      system: configuration.systemPrompt,
      parts: [
        PromptPart(
          type: "text",
          text: "Act on this spoken macOS command. Prefer taking action over replying.\n\n\(command)"
        )
      ]
    )
    let request = try makeRequest(
      configuration: configuration,
      path: "/session/\(sessionID)/prompt_async",
      method: "POST",
      body: requestBody
    )

    let modelLabel = configuration.model.map { "\($0.providerID)/\($0.modelID)" } ?? "default"
    openCodeLogger.notice("Sending OpenCode prompt_async session=\(sessionID, privacy: .public) agent=build model=\(modelLabel, privacy: .public)")

    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data, expectedStatusCodes: [204])
  }

  private func makeRequest<Body: Encodable>(
    configuration: ResolvedConfiguration,
    path: String,
    method: String,
    body: Body
  ) throws -> URLRequest {
    guard var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false) else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    components.path = path
    components.queryItems = [
      URLQueryItem(name: "directory", value: configuration.directory)
    ]

    guard let url = components.url else {
      throw OpenCodeClientError.invalidServerURL(configuration.serverURL.absoluteString)
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    request.timeoutInterval = 10
    return request
  }

  private func validate(
    response: URLResponse,
    data: Data,
    expectedStatusCodes: [Int]
  ) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw OpenCodeClientError.invalidResponse
    }

    guard expectedStatusCodes.contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw OpenCodeClientError.serverError(statusCode: httpResponse.statusCode, body: body)
    }
  }

  private func parseModel(_ rawModel: String) -> PromptModel? {
    let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
      openCodeLogger.error("Ignoring invalid OpenCode model string \(trimmed, privacy: .private)")
      return nil
    }

    return PromptModel(providerID: parts[0], modelID: parts[1])
  }

  private func permissionRules(from rawTools: String) -> [PermissionRule] {
    let normalizedTools = rawTools
      .split(whereSeparator: { $0 == "," || $0 == "\n" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var rules: [PermissionRule] = [
      PermissionRule(permission: "question", pattern: "*", action: "deny"),
      PermissionRule(permission: "plan_enter", pattern: "*", action: "deny"),
      PermissionRule(permission: "plan_exit", pattern: "*", action: "deny")
    ]

    guard !normalizedTools.isEmpty else {
      return rules
    }

    rules.append(PermissionRule(permission: "*", pattern: "*", action: "deny"))
    let expandedPermissions = normalizedTools.flatMap(expandPermissionIDs)
    rules.append(contentsOf: expandedPermissions.map {
      PermissionRule(permission: $0, pattern: "*", action: "allow")
    })
    return rules
  }

  private func expandPermissionIDs(_ toolID: String) -> [String] {
    let normalized = normalizePermissionID(toolID)
    let macOSTools = Set([
      "open_application",
      "open_url",
      "find_files",
      "run_applescript",
      "manage_memory",
      "paste_text",
    ])

    if macOSTools.contains(normalized) {
      return [normalized, "macos_\(normalized)"]
    }

    return [normalized]
  }

  private func normalizePermissionID(_ toolID: String) -> String {
    switch toolID {
    case "edit", "write", "apply_patch", "multiedit":
      return "edit"
    default:
      return toolID
    }
  }

  private func systemPrompt(additionalInstructions: String) -> String {
    let base = """
    You are being driven by Hex in an experimental voice-action mode on macOS.
    Treat the user's text as an action request for this computer.
    Prefer taking the requested action over explaining it.
    Use the available tools to operate the machine directly.
    When useful on macOS, prefer shell commands like open, open -a, mdfind, ls, and osascript.
    Avoid editing files unless the spoken command explicitly asks for file changes.
    """

    guard !additionalInstructions.isEmpty else {
      return base
    }

    return base + "\nAdditional instructions:\n" + additionalInstructions
  }

  private func currentPhaseAfterEnqueue() -> OpenCodeRuntimePhase {
    runtimeStatus.phase == .startingServer ? .startingServer : .ready
  }

  private func publish(phase: OpenCodeRuntimePhase) {
    let next = OpenCodeRuntimeStatus(
      phase: phase,
      queuedCommands: queue.count,
      activeSessions: activeSessions.count,
      activities: activities
    )
    guard next != runtimeStatus else { return }
    runtimeStatus = next
    for continuation in observers.values {
      continuation.yield(runtimeStatus)
    }
  }

  private func upsertActivity(_ activity: OpenCodeSessionActivity) {
    if let index = activities.firstIndex(where: { $0.id == activity.id }) {
      activities[index] = activity
    } else {
      activities.insert(activity, at: 0)
      activities = Array(activities.prefix(5))
    }
    publish(phase: runtimeStatus.phase)
  }

  private func setActivityStatus(id: String, status: OpenCodeSessionActivity.Status) {
    guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
    activities[index].status = status
    publish(phase: runtimeStatus.phase)
  }

  private func setActivitySessionID(id: String, sessionID: String) {
    guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
    activities[index].sessionID = sessionID
    publish(phase: runtimeStatus.phase)
  }

  private func updateActivityContent(id: String, messages: [RemoteMessageListItem]) {
    guard let index = activities.firstIndex(where: { $0.id == id }) else { return }

    guard let assistant = messages.last(where: { $0.info.role == "assistant" }) else {
      return
    }

    activities[index].toolCalls = assistant.parts.compactMap { part in
      guard part.type == "tool", let tool = part.tool, let state = part.state else { return nil }
      return OpenCodeToolCall(
        id: part.id,
        title: state.title ?? tool,
        status: state.status
      )
    }

    let text = assistant.parts
      .filter { $0.type == "text" }
      .compactMap(\.text)
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      activities[index].responseText = text
    }

    if let errorMessage = assistant.info.error?.message, !errorMessage.isEmpty {
      activities[index].status = .error(errorMessage)
    }
    publish(phase: runtimeStatus.phase)
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }
}

private enum OpenCodeClientError: LocalizedError {
  case invalidServerURL(String)
  case invalidLaunchPath(String)
  case bunNotFound
  case invalidResponse
  case serverUnavailable(String)
  case serverStartTimedOut(String)
  case serverError(statusCode: Int, body: String)

  var errorDescription: String? {
    switch self {
    case let .invalidServerURL(url):
      return "Invalid OpenCode server URL: \(url)"
    case let .invalidLaunchPath(path):
      return "OpenCode launch path does not exist: \(path)"
    case .bunNotFound:
      return "Could not find Bun. Set BUN_PATH or install Bun in ~/.bun/bin/bun."
    case .invalidResponse:
      return "OpenCode returned an invalid response."
    case let .serverUnavailable(url):
      return "OpenCode is not reachable at \(url), and Hex can only auto-start localhost servers."
    case let .serverStartTimedOut(url):
      return "Timed out while starting the managed OpenCode server at \(url)."
    case let .serverError(statusCode, body):
      if body.isEmpty {
        return "OpenCode request failed with status \(statusCode)."
      }
      return "OpenCode request failed with status \(statusCode): \(body)"
    }
  }
}

private extension URL {
  func host() -> String? {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?.host
  }

  func port() -> Int? {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?.port
  }
}
