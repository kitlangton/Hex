//
//  AgentFeature.swift
//  Hex
//
//  Drives the Agent Plugins voice window. Shows what Claude Code is presenting (a plain
//  message, a multiple-choice question, or a permission request), lets the user answer by
//  voice / typing / tapping an option, then answers the BLOCKED hook in-band: Hex writes
//  the complete hook-output JSON to `<payload>.response`, which the hook script relays to
//  Claude Code on stdout. No app focusing, no synthetic keystrokes — the answer can never
//  land in the wrong window. (Typing into the terminal remains only as a legacy fallback
//  when no payload file is available.)
//
//  Multiple Claude sessions can be blocked at once — each on its own hook — so the feature
//  holds a FIFO queue of `AgentRequest`s (one card per active project). The oldest is shown;
//  newcomers wait their turn; answering or dismissing advances to the next. Nothing is ever
//  silently abandoned: every teardown (answer, dismiss, supersede, even app quit) writes a
//  response so no session hangs on its 600s hook timeout.
//

import AppKit
import ComposableArchitecture
import Foundation
import HexCore
import SwiftUI

private let agentFeatureLogger = HexLog.app

@Reducer
struct AgentFeature {
  /// Parsed from a `hex://agent-update?…` deeplink — the raw wire format. The terminal we
  /// should reply to (`sourceApp*`) is filled in by the app delegate, which tracks the last
  /// foreground app before the deeplink activated Hex.
  struct ShowPayload: Equatable {
    var event: String?
    var tool: String?
    var sessionID: String?
    var cwd: String?
    var transcriptPath: String?
    var payloadPath: String?
    var inlineMessage: String?
    var sourceAppBundleID: String?
    var sourceAppPID: pid_t?
  }

  /// The identity + routing for one Claude session: where it lives and how to reach its
  /// terminal. Shared by the live card (`AgentRequest`) and the recent-session registry
  /// (`RecentSession`) so the same fields aren't hand-copied across structs.
  struct SessionContext: Equatable {
    var cwd: String? = nil
    var transcriptPath: String? = nil
    /// The hosting terminal app, captured from the foreground app at deeplink time. Used only
    /// by the legacy typing path (a compose reply, or a permission with no payload file).
    var sourceAppBundleID: String? = nil
    var sourceAppPID: pid_t? = nil
    /// The project's GitHub owner avatar, resolved once from the repo's `origin` remote. nil
    /// until resolved, or when the project has no GitHub remote (the header shows a folder).
    var projectIconURL: URL? = nil

    /// The project name shown in the header — the basename of the session's cwd.
    var projectName: String? {
      guard let cwd, !cwd.isEmpty else { return nil }
      return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Overlays non-nil fields from `other`, preserving anything already resolved — so a
    /// sparse re-show never erases a previously-resolved avatar or terminal.
    mutating func merge(_ other: SessionContext) {
      if let value = other.cwd, !value.isEmpty { cwd = value }
      if let value = other.transcriptPath { transcriptPath = value }
      if let value = other.sourceAppBundleID { sourceAppBundleID = value }
      if let value = other.sourceAppPID { sourceAppPID = value }
      if let value = other.projectIconURL { projectIconURL = value }
    }
  }

  /// One card in the window. Each owns its own draft reply and selection, so flipping between
  /// cards never loses what you typed.
  struct AgentRequest: Equatable, Identifiable {
    /// Why this card exists. `.hook` answers a Claude hook that's blocked polling for our
    /// response file (in-band delivery when a `payloadPath` is present); `.compose` is a
    /// user-initiated reply with no hook waiting (typed into the session's terminal).
    enum Kind: Equatable {
      case hook(payloadPath: String?)
      case compose
    }

    var kind: Kind
    var sessionID: String?
    var context: SessionContext

    var prompt: AgentPrompt = .message("")
    var selectedOptions: Set<String> = []
    var draftReply: String = ""
    /// 0...1 while the auto-send countdown runs after a paste/dictation; nil otherwise.
    var autoSendProgress: Double?
    /// The voice to read this card in (nil = the user's chosen default). Assigned once and
    /// kept for the card's lifetime — so a session keeps its distinct voice even after a
    /// sibling is answered and it's alone.
    var voice: String?

    /// The hook's payload file, when this is a blocked hook with an in-band channel.
    var payloadPath: String? {
      if case let .hook(path) = kind { return path }
      return nil
    }
    /// True while a Claude hook is blocked waiting on us (vs. a manual compose card).
    var isBlocked: Bool {
      if case .hook = kind { return true }
      return false
    }

    /// A session blocks on a single hook at a time, so the session id is the natural identity;
    /// fall back to the payload path for the rare hook that arrived without one.
    var id: String { sessionID ?? payloadPath ?? "manual" }

    init(from payload: ShowPayload) {
      kind = .hook(payloadPath: payload.payloadPath)
      sessionID = payload.sessionID
      context = SessionContext(
        cwd: payload.cwd,
        transcriptPath: payload.transcriptPath,
        sourceAppBundleID: payload.sourceAppBundleID,
        sourceAppPID: payload.sourceAppPID
      )
      prompt = .message(payload.inlineMessage ?? "")
    }

    /// A manually-composed card addressed to a known session picked from the selector. It
    /// carries the session's identity (so the selector highlights it and the header shows its
    /// avatar) but has no blocked hook — the reply is typed into that session's terminal.
    init(composeFor session: RecentSession) {
      kind = .compose
      sessionID = session.sessionID
      context = session.context
      voice = session.voice
    }
  }

  /// A Claude session Hex has seen block at least once this run, remembered so the user can
  /// summon the window and target it again — even after it has unblocked and is sitting idle.
  /// Stored most-recent-first; capped at `maxRecentSessions`.
  struct RecentSession: Equatable, Identifiable {
    var sessionID: String
    var context: SessionContext = .init()
    var voice: String?

    var id: String { sessionID }
  }

  @ObservableState
  struct State: Equatable {
    /// FIFO queue of blocked sessions. The front (`first`) is the visible card.
    var requests: IdentifiedArrayOf<AgentRequest> = []
    /// The card currently shown; kept in sync with `requests.first`.
    var currentID: AgentRequest.ID?
    /// Remembered voice per Claude session id, so a project keeps one consistent voice for
    /// the whole run (even across turns where it's the only active card). Assigned lazily;
    /// not persisted — a fresh launch is a fresh working session.
    var sessionVoices: [String: String] = [:]
    /// Sessions seen blocked at least once this run, most-recent-first. Powers the header's
    /// agent selector so a manual summon can target any of them — blocked or idle.
    var recentSessions: IdentifiedArrayOf<RecentSession> = []

    var isVisible: Bool = false
    /// True while the panel is intentionally hidden waiting for speech synthesis.
    var pendingReveal: Bool = false
    /// Shown when the window is summoned but there's nothing to target — no remembered
    /// session and no live `claude` terminal — so the card explains that instead of opening
    /// a compose box that would type into a random frontmost window.
    var noSessionsError: Bool = false

    @Shared(.hexSettings) var hexSettings: HexSettings

    // MARK: Convenience accessors for the current card (keep the View unchanged).

    var current: AgentRequest? { currentID.flatMap { requests[id: $0] } }
    var prompt: AgentPrompt { current?.prompt ?? .message("") }
    var draftReply: String { current?.draftReply ?? "" }
    var selectedOptions: Set<String> { current?.selectedOptions ?? [] }
    var autoSendProgress: Double? { current?.autoSendProgress }

    // MARK: Header

    /// The project name shown in the card header — the basename of the session's cwd.
    var projectName: String? { current?.context.projectName }
    var projectIconURL: URL? { current?.context.projectIconURL }

    /// One pickable agent in the header selector.
    struct SelectableAgent: Equatable, Identifiable {
      var id: String          // session id
      var projectName: String?
      var iconURL: URL?
      var isBlocked: Bool      // currently waiting on a hook (vs. idle)
      var isCurrent: Bool      // the visible card
    }

    /// The agents the selector offers, recency-ordered. Every remembered session, tagged with
    /// whether it's currently blocked on a hook (vs. a compose target) and whether it's the
    /// one on screen.
    var selectableAgents: [SelectableAgent] {
      let blocked = Set(requests.filter(\.isBlocked).compactMap(\.sessionID))
      let currentSessionID = current?.sessionID
      return recentSessions.map { session in
        SelectableAgent(
          id: session.sessionID,
          projectName: session.context.projectName,
          iconURL: session.context.projectIconURL,
          isBlocked: blocked.contains(session.sessionID),
          isCurrent: session.sessionID == currentSessionID
        )
      }
    }
  }

  enum Action {
    case show(ShowPayload)
    case openManually
    case selectAgent(String)              // switch the window to a remembered session
    case promptLoaded(AgentRequest.ID, AgentPrompt)
    case projectIconResolved(AgentRequest.ID, URL?)
    case revealPanel
    case dismiss
    case draftChanged(String)
    case selectOption(AgentOption)        // single-select: answers immediately
    case toggleOption(AgentOption)        // multi-select: toggles, Send submits
    case respondPermission(allow: Bool)   // permission allow/deny
    case toggleSpeakOutput
    case autoSendTicked(Double)
    case cancelAutoSend
    case send
    case sent
  }

  enum CancelID { case autoSend }

  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.agentTranscript) var agentTranscript
  @Dependency(\.speechSynthesizer) var speechSynthesizer

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .show(payload):
        let enabled = state.hexSettings.agentPluginsEnabled
        agentFeatureLogger.notice("Agent show requested (enabled=\(enabled), event=\(payload.event ?? "nil", privacy: .public), tool=\(payload.tool ?? "nil", privacy: .public))")
        guard enabled else { return .none }
        // A real prompt arrived — clear any "nothing to target" state from a prior summon.
        state.noSessionsError = false

        // The user answered in the terminal — the hook script already released this
        // session's blocked sibling. Drop its queued card and advance if it was showing.
        if payload.event == "UserPromptSubmit" {
          let key = payload.sessionID ?? payload.payloadPath ?? "manual"
          guard state.requests[id: key] != nil else { return .none }
          let wasCurrent = state.currentID == key
          state.requests.remove(id: key)
          return wasCurrent ? advance(&state) : .none
        }

        var request = AgentRequest(from: payload)
        let id = request.id
        // Assign (or recall) this session's voice so each project sounds consistent across
        // turns and concurrent projects are distinguishable by ear.
        request.voice = sessionVoice(&state, for: request.sessionID)
        // Reuse a previously-resolved avatar so a re-show of a known session renders its
        // icon instantly instead of refetching.
        if let sessionID = request.sessionID,
           let knownIcon = state.recentSessions[id: sessionID]?.context.projectIconURL {
          request.context.projectIconURL = knownIcon
        }

        if let existing = state.requests[id: id] {
          // Same session re-presenting: release its now-stale hook before replacing it.
          if let oldPath = existing.payloadPath, oldPath != request.payloadPath {
            AgentHookResponder.respond(payloadPath: oldPath, json: nil)
          }
          state.requests[id: id] = request
        } else {
          // A newer request from a *different* session no longer releases the current
          // one — it joins the queue behind it.
          state.requests.append(request)
        }
        // Remember this session so the selector can target it later, even once it unblocks.
        rememberSession(&state, from: request)

        // Become the visible card only when nothing is showing, or when the card being
        // updated IS the current one. Otherwise it waits its turn (FIFO) silently.
        if state.currentID == nil || state.currentID == id {
          return present(&state, id: id)
        }
        return .none

      case .openManually:
        guard state.hexSettings.agentPluginsEnabled else { return .none }
        // Second press toggles the panel away.
        if state.isVisible { return .send(.dismiss) }
        agentFeatureLogger.notice("Agent window summoned via hotkey")
        // A manual summon shows immediately — there's no incoming prompt to read aloud first.
        state.isVisible = true
        state.pendingReveal = false
        state.noSessionsError = false

        // Prefer a session already blocked and waiting for an answer.
        if let blocked = state.requests.first {
          return .merge(.cancel(id: CancelID.autoSend), present(&state, id: blocked.id))
        }
        // Else address the most-recently-seen session, so the summon lands on whatever you
        // were last working with and the selector lets you switch from there.
        if let recent = state.recentSessions.first {
          let request = AgentRequest(composeFor: recent)
          state.requests.insert(request, at: 0)
          return .merge(.cancel(id: CancelID.autoSend), present(&state, id: request.id))
        }
        // Nothing registered this run. Quick prompting needs a session that has actually
        // blocked at least once (so we have a real in-band/terminal target) — a bare
        // "locate any running claude" would just type into the frontmost window. Show the
        // empty state instead.
        state.noSessionsError = true
        return .cancel(id: CancelID.autoSend)

      case let .selectAgent(sessionID):
        // Already showing it — nothing to do.
        if state.current?.sessionID == sessionID { return .none }
        // A blocked session is already queued: just bring its live card to the front.
        if state.requests[id: sessionID] != nil {
          return .merge(.cancel(id: CancelID.autoSend), present(&state, id: sessionID))
        }
        // An idle remembered session: compose a fresh card addressed to its terminal.
        guard let info = state.recentSessions[id: sessionID] else { return .none }
        let request = AgentRequest(composeFor: info)
        state.requests.insert(request, at: 0)
        return .merge(.cancel(id: CancelID.autoSend), present(&state, id: request.id))

      case let .promptLoaded(id, prompt):
        state.requests[id: id]?.prompt = prompt
        // Only the front card speaks/reveals; a preloaded waiting card just caches.
        guard id == state.currentID else { return .none }
        return speakThenReveal(state)

      case let .projectIconResolved(id, url):
        state.requests[id: id]?.context.projectIconURL = url
        // Cache it on the registry too, so the selector and future re-shows reuse it.
        if let sessionID = state.requests[id: id]?.sessionID {
          state.recentSessions[id: sessionID]?.context.projectIconURL = url
        }
        return .none

      case .revealPanel:
        // Ignore a reveal that arrives after the prompt was answered or dismissed.
        guard state.pendingReveal else { return .none }
        state.pendingReveal = false
        state.isVisible = true
        return .none

      case .dismiss:
        guard let id = state.currentID, let request = state.requests[id: id] else {
          state.isVisible = false
          state.pendingReveal = false
          state.noSessionsError = false
          return .merge(
            .cancel(id: CancelID.autoSend),
            .run { _ in await speechSynthesizer.stop() }
          )
        }
        // Release this card's blocked hook with an empty response (yield to the TUI).
        if let payloadPath = request.payloadPath {
          AgentHookResponder.respond(payloadPath: payloadPath, json: nil)
        }
        state.requests.remove(id: id)
        return .merge(
          .cancel(id: CancelID.autoSend),
          .run { _ in await speechSynthesizer.stop() },
          advance(&state)
        )

      case .toggleSpeakOutput:
        let nowEnabled = !state.hexSettings.agentSpeakOutput
        state.$hexSettings.withLock { $0.agentSpeakOutput = nowEnabled }
        if nowEnabled {
          return speakIfEnabled(state)
        }
        return .run { _ in await speechSynthesizer.stop() }

      case let .draftChanged(text):
        guard let id = state.currentID, let current = state.requests[id: id] else { return .none }
        // Multi-character growth means a paste or a dictated transcript landed in the
        // field; start a short countdown that sends it unless the user intervenes.
        let isBulkInsert = text.count > current.draftReply.count + 1
          && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        state.requests[id: id]?.draftReply = text
        if isBulkInsert {
          state.requests[id: id]?.autoSendProgress = 0
          return .run { send in
            let steps = 60
            let totalMillis = Self.autoSendDelay.components.seconds * 1000
              + Self.autoSendDelay.components.attoseconds / 1_000_000_000_000_000
            for step in 1 ... steps {
              try await Task.sleep(for: .milliseconds(Int(totalMillis) / steps))
              await send(.autoSendTicked(Double(step) / Double(steps)))
            }
            await send(.send)
          }
          .cancellable(id: CancelID.autoSend, cancelInFlight: true)
        }
        // Manual typing takes over: stop any pending auto-send.
        if current.autoSendProgress != nil {
          state.requests[id: id]?.autoSendProgress = nil
          return .cancel(id: CancelID.autoSend)
        }
        return .none

      case let .autoSendTicked(progress):
        if let id = state.currentID {
          state.requests[id: id]?.autoSendProgress = progress
        }
        return .none

      case .cancelAutoSend:
        if let id = state.currentID {
          state.requests[id: id]?.autoSendProgress = nil
        }
        return .cancel(id: CancelID.autoSend)

      case let .selectOption(option):
        guard let id = state.currentID else { return .none }
        state.requests[id: id]?.draftReply = option.label
        return .send(.send)

      case let .toggleOption(option):
        guard let id = state.currentID, var selected = state.requests[id: id]?.selectedOptions else {
          return .none
        }
        if selected.contains(option.label) {
          selected.remove(option.label)
        } else {
          selected.insert(option.label)
        }
        state.requests[id: id]?.selectedOptions = selected
        state.requests[id: id]?.draftReply = selected.sorted().joined(separator: ", ")
        return .none

      case let .respondPermission(allow):
        guard let id = state.currentID, let request = state.requests[id: id] else { return .none }
        if let payloadPath = request.payloadPath {
          state.requests.remove(id: id)
          return .merge(
            .cancel(id: CancelID.autoSend),
            .run { _ in await speechSynthesizer.stop() },
            advance(&state),
            .run { send in
              AgentHookResponder.respondPermission(payloadPath: payloadPath, allow: allow)
              await send(.sent)
            }
          )
        }
        // Legacy fallback (no payload file): the terminal permission prompt is a
        // numbered menu, 1 = allow, 2 = deny.
        state.requests[id: id]?.draftReply = allow ? "1" : "2"
        return .send(.send)

      case .send:
        guard let id = state.currentID, let request = state.requests[id: id] else { return .none }
        let text = request.draftReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }

        let payloadPath = request.payloadPath
        let prompt = request.prompt
        let pid = request.context.sourceAppPID
        let bundleID = request.context.sourceAppBundleID
        let autoSubmit = state.hexSettings.agentAutoSubmit
        state.requests.remove(id: id)

        let teardown: Effect<Action> = .merge(
          .cancel(id: CancelID.autoSend),
          .run { _ in await speechSynthesizer.stop() },
          advance(&state)
        )

        // In-band path: answer the blocked hook directly. The hook script relays this
        // JSON to Claude Code on stdout, so the right session gets it without focus.
        if let payloadPath {
          return .merge(teardown, .run { send in
            AgentHookResponder.respondAnswer(payloadPath: payloadPath, prompt: prompt, answer: text)
            await send(.sent)
          })
        }

        // Legacy fallback: re-focus the captured terminal and type the answer.
        return .merge(teardown, .run { send in
          let activated = await Self.activateTargetApp(pid: pid, bundleID: bundleID)
          if !activated {
            agentFeatureLogger.error("Could not bring target app to front; typing anyway")
          }
          // Let the frontmost-app handoff settle before posting keystrokes.
          try? await Task.sleep(for: .milliseconds(160))
          // Type (not paste) so Claude Code's terminal prompt receives it.
          await pasteboard.type(text)
          if autoSubmit {
            try? await Task.sleep(for: .milliseconds(90))
            await pasteboard.sendKeyboardCommand(.enter)
          }
          await send(.sent)
        })

      case .sent:
        soundEffect.play(.pasteTranscript)
        return .none
      }
    }
  }

  // MARK: Recent-session registry

  /// How many recently-blocked sessions the selector remembers.
  static let maxRecentSessions = 8

  /// Records (or refreshes) a session in the recency-ordered registry so the selector can
  /// target it later, even after its hook releases. Only carries non-nil fields forward, so
  /// a sparse re-show never erases a previously-resolved avatar or terminal.
  private func rememberSession(_ state: inout State, from request: AgentRequest) {
    guard let sessionID = request.sessionID, !sessionID.isEmpty else { return }
    var info = state.recentSessions[id: sessionID] ?? RecentSession(sessionID: sessionID)
    info.context.merge(request.context)
    if let voice = request.voice { info.voice = voice }
    // Move-to-front so the array stays most-recent-first.
    state.recentSessions.remove(id: sessionID)
    state.recentSessions.insert(info, at: 0)
    if state.recentSessions.count > Self.maxRecentSessions {
      state.recentSessions.removeLast(state.recentSessions.count - Self.maxRecentSessions)
    }
  }

  // MARK: Queue navigation

  /// Sets `id` as the visible card, loading its prompt then speaking/revealing. When the
  /// panel is already up (advancing between cards) it stays visible and just speaks the
  /// new card; coming up fresh it honors the hidden-until-spoken behavior.
  private func present(_ state: inout State, id: AgentRequest.ID) -> Effect<Action> {
    state.currentID = id
    guard let request = state.requests[id: id] else {
      state.isVisible = false
      state.pendingReveal = false
      return .none
    }
    if !state.isVisible {
      // With read-aloud on, keep the panel hidden until the audio is ready so the window
      // appears the moment it starts talking (capped — see speakThenReveal).
      state.isVisible = !state.hexSettings.agentSpeakOutput
      state.pendingReveal = !state.isVisible
    }
    let iconEffect = resolveProjectIcon(request)
    let payloadPath = request.payloadPath
    let transcriptPath = request.context.transcriptPath
    guard payloadPath != nil || transcriptPath != nil else {
      return .merge(iconEffect, speakThenReveal(state))
    }
    let fallback = request.prompt
    return .merge(iconEffect, .run { send in
      let prompt = (try? await agentTranscript.latestPrompt(payloadPath, transcriptPath)) ?? fallback
      await send(.promptLoaded(id, prompt))
    })
  }

  /// Resolves the project's GitHub owner avatar from its git remote (once per card), so the
  /// header can show the project's real identity instead of a generic folder icon.
  private func resolveProjectIcon(_ request: AgentRequest) -> Effect<Action> {
    guard request.context.projectIconURL == nil, let cwd = request.context.cwd, !cwd.isEmpty else { return .none }
    let id = request.id
    return .run { send in
      await send(.projectIconResolved(id, await Self.gitHubAvatarURL(forRepoAt: cwd)))
    }
  }

  /// Moves to the next queued card (FIFO), or tears the panel down when the queue empties.
  private func advance(_ state: inout State) -> Effect<Action> {
    guard let next = state.requests.first?.id else {
      state.currentID = nil
      state.isVisible = false
      state.pendingReveal = false
      return .none
    }
    return present(&state, id: next)
  }

  /// How long we'll sit on a hidden panel waiting for synthesis (Kokoro can be slow
  /// on first use while its model downloads) before showing it anyway.
  static let revealCap: Duration = .seconds(60)

  /// Grace period before a pasted/dictated reply is sent automatically.
  static let autoSendDelay: Duration = .milliseconds(1500)

  /// Brings the captured terminal to the front and confirms it actually became
  /// frontmost. macOS 14 activation is cooperative — a plain `activate()` from a
  /// background app (Hex's panel is non-activating) is often silently declined, so
  /// retry and escalate to relaunching the app bundle, which reliably activates.
  @MainActor
  private static func activateTargetApp(pid: pid_t?, bundleID: String?) async -> Bool {
    guard let app = pid.flatMap({ NSRunningApplication(processIdentifier: $0) })
      ?? bundleID.flatMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first })
    else { return false }

    func isFrontmost() -> Bool {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }
    if isFrontmost() { return true }

    for attempt in 0 ..< 8 {
      if #available(macOS 14.0, *) {
        NSApp.yieldActivation(to: app)
        app.activate()
      } else {
        app.activate(options: [.activateIgnoringOtherApps])
      }
      // Halfway through, escalate: openApplication on a running app just activates
      // it, and is honored even when cooperative activation is declined.
      if attempt == 3, let url = app.bundleURL {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
      }
      try? await Task.sleep(for: .milliseconds(120))
      if isFrontmost() { return true }
    }
    return isFrontmost()
  }

  // MARK: Project icon

  /// The GitHub owner avatar for a repo, derived from its `origin` remote. nil when the
  /// directory isn't a git repo, has no origin, or the remote isn't a GitHub URL.
  static func gitHubAvatarURL(forRepoAt cwd: String) async -> URL? {
    guard let remote = await gitOriginURL(cwd: cwd),
          let owner = gitHubOwner(fromRemote: remote)
    else { return nil }
    return URL(string: "https://github.com/\(owner).png?size=128")
  }

  /// Reads `remote.origin.url` via git (handles subdirectories and worktrees). Returns nil
  /// when git is unavailable or the directory has no origin remote.
  private static func gitOriginURL(cwd: String) async -> String? {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", cwd, "config", "--get", "remote.origin.url"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe() // swallow "not a git repository" noise
      process.terminationHandler = { _ in
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let url = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.resume(returning: (url?.isEmpty == false) ? url : nil)
      }
      do {
        try process.run()
      } catch {
        continuation.resume(returning: nil)
      }
    }
  }

  /// Extracts the owner/org from a GitHub remote, tolerating every common form:
  /// `git@github.com:Org/Repo.git`, `ssh://git@github.com/Org/Repo.git`,
  /// `https://github.com/Org/Repo(.git)`.
  static func gitHubOwner(fromRemote remote: String) -> String? {
    guard let hostRange = remote.range(of: "github.com") else { return nil }
    // Drop the host/path separator (":" for SCP-style, "/" for URL-style), then take the
    // first path component as the owner.
    let path = remote[hostRange.upperBound...].drop(while: { $0 == ":" || $0 == "/" })
    let owner = path.prefix(while: { $0 != "/" })
    return owner.isEmpty ? nil : String(owner)
  }

  // MARK: Speech

  /// The voice for the current card: its assigned voice if it has one, otherwise the user's
  /// chosen default.
  private func voiceIdentifier(for state: State) -> String? {
    state.current?.voice ?? state.hexSettings.agentVoiceIdentifier
  }

  /// Resolves the voice for a session, assigning and remembering one on first sight when the
  /// "distinct session voices" setting is on. Returns nil — meaning "use the default" — when
  /// the setting is off or there's no session id (e.g. a manually-summoned card).
  private func sessionVoice(_ state: inout State, for sessionID: String?) -> String? {
    guard state.hexSettings.agentDistinctSessionVoices, let sessionID else { return nil }
    if let remembered = state.sessionVoices[sessionID] { return remembered }
    // Voices already claimed by any remembered session (keep new ones globally distinct),
    // and the subset still on screen / queued (never collide with a concurrent card).
    let used = Set(state.sessionVoices.values)
    let active = Set(state.requests.compactMap { $0.sessionID.flatMap { state.sessionVoices[$0] } })
    let voice = Self.pickSessionVoice(
      for: sessionID,
      default: state.hexSettings.agentVoiceIdentifier,
      used: used,
      active: active
    )
    state.sessionVoices[sessionID] = voice
    return voice
  }

  /// Picks a stable, distinct voice for a new session. The first session keeps the user's
  /// chosen default; later sessions get a voice no other session has taken (falling back to
  /// any non-default voice once the pool is exhausted), seeded by the session id so the
  /// choice is deterministic, and never colliding with a currently-active session.
  static func pickSessionVoice(for sessionID: String, default userDefault: String?, used: Set<String>, active: Set<String>) -> String {
    let resolvedDefault = KokoroVoice.voiceName(fromIdentifier: userDefault)
    let pool = KokoroVoice.voices
    guard !pool.isEmpty else { return resolvedDefault }
    // First/primary session keeps the user's chosen default voice.
    if !used.contains(resolvedDefault) { return resolvedDefault }
    let others = pool.filter { $0 != resolvedDefault }
    guard !others.isEmpty else { return resolvedDefault }
    let unclaimed = others.filter { !used.contains($0) }
    let candidates = unclaimed.isEmpty ? others : unclaimed
    let start = stableHash(sessionID) % candidates.count
    for offset in 0 ..< candidates.count {
      let candidate = candidates[(start + offset) % candidates.count]
      if !active.contains(candidate) { return candidate }
    }
    return candidates[start]
  }

  /// FNV-1a — a stable, launch-independent hash so a session always maps to the same voice.
  static func stableHash(_ string: String) -> Int {
    var hash: UInt64 = 14695981039346656037
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1099511628211
    }
    return Int(hash % UInt64(Int.max))
  }

  /// Reads the current prompt aloud when the user has speech output enabled.
  private func speakIfEnabled(_ state: State) -> Effect<Action> {
    guard state.hexSettings.agentSpeakOutput else { return .none }
    let text = Self.spokenText(for: state.prompt)
    guard !text.isEmpty else { return .none }
    let voice = voiceIdentifier(for: state)
    return .run { _ in await speechSynthesizer.speak(text, voice) }
  }

  /// Starts reading the prompt, then reveals the panel once audio playback has begun
  /// (speak returns when sound starts) — or after `revealCap`, whichever comes first.
  /// If the panel is already visible (or there is nothing to say), it just speaks.
  private func speakThenReveal(_ state: State) -> Effect<Action> {
    guard !state.isVisible else { return speakIfEnabled(state) }
    let text = Self.spokenText(for: state.prompt)
    guard state.hexSettings.agentSpeakOutput, !text.isEmpty else { return .send(.revealPanel) }
    let voice = voiceIdentifier(for: state)
    return .run { send in
      // Unstructured so the cap firing doesn't cancel synthesis — audio still plays
      // whenever it's ready; we just stop holding the panel for it.
      let speakTask = Task { await speechSynthesizer.speak(text, voice) }
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await speakTask.value }
        group.addTask { try? await Task.sleep(for: Self.revealCap) }
        await group.next()
        group.cancelAll()
      }
      await send(.revealPanel)
    }
  }

  static func spokenText(for prompt: AgentPrompt) -> String {
    switch prompt {
    case let .message(text):
      return SpokenText.spoken(from: text)
    case let .question(question):
      let options = question.options.map(\.label).joined(separator: ". ")
      let q = SpokenText.spoken(from: question.question)
      return q + (options.isEmpty ? "" : " Options: \(options)")
    case let .permission(permission):
      return "Claude wants to use \(permission.tool)"
    }
  }
}
