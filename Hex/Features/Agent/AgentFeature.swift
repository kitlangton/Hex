//
//  AgentFeature.swift
//  Hex
//
//  Drives the Agent Plugins voice window. Shows what Claude Code is presenting (a plain
//  message, a multiple-choice question, or a permission request) and lets the user answer by
//  voice / typing / tapping an option, then answers the BLOCKED hook in-band: Hex writes the
//  complete hook-output JSON to `<payload>.response`, which the hook script relays to Claude
//  Code on stdout. No app focusing, no synthetic keystrokes — the answer can never land in the
//  wrong window, and the window only ever *responds* to a session that is blocked on a hook.
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
  /// Parsed from a `hex://agent-update?…` deeplink — the raw wire format.
  struct ShowPayload: Equatable {
    var event: String?
    var tool: String?
    var sessionID: String?
    var cwd: String?
    var transcriptPath: String?
    var payloadPath: String?
    var inlineMessage: String?
  }

  /// The identity of one Claude session: where it lives and the project it belongs to.
  struct SessionContext: Equatable {
    var cwd: String? = nil
    var transcriptPath: String? = nil
    /// The project's GitHub owner avatar, resolved once from the repo's `origin` remote. nil
    /// until resolved, or when the project has no GitHub remote (the header shows a folder).
    var projectIconURL: URL? = nil

    /// The project name shown in the header — the basename of the session's cwd.
    var projectName: String? {
      guard let cwd, !cwd.isEmpty else { return nil }
      return URL(fileURLWithPath: cwd).lastPathComponent
    }
  }

  /// One card in the window — a Claude hook blocked polling for our response file. Each owns
  /// its own draft reply and selection, so flipping between cards never loses what you typed.
  struct AgentRequest: Equatable, Identifiable {
    /// The hook's payload file; the in-band channel we answer through. (Optional only to guard
    /// the degenerate case of a hook that arrived without one — it simply can't be answered.)
    var payloadPath: String?
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

    /// A session blocks on a single hook at a time, so the session id is the natural identity;
    /// fall back to the payload path for the rare hook that arrived without one.
    var id: String { sessionID ?? payloadPath ?? "manual" }

    init(from payload: ShowPayload) {
      payloadPath = payload.payloadPath
      sessionID = payload.sessionID
      context = SessionContext(cwd: payload.cwd, transcriptPath: payload.transcriptPath)
      prompt = .message(payload.inlineMessage ?? "")
    }
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

    var isVisible: Bool = false
    /// True while the panel is intentionally hidden waiting for speech synthesis.
    var pendingReveal: Bool = false
    /// Shown when the window is summoned but no session is blocked and waiting — so the card
    /// explains that instead of opening an empty reply box that has nothing to answer.
    var noSessionsError: Bool = false
    /// Whether the panel should hold keyboard focus. False when a hook auto-presents, so the
    /// card appears passively and never steals keystrokes from the editor you're typing in;
    /// true once you summon or "engage" it (agent hotkey / tapping the selector), which is
    /// when we make it key so typing and dictation land in the reply field.
    var wantsFocus: Bool = false

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
      var isCurrent: Bool      // the visible card
    }

    /// The agents the selector offers — every session currently blocked and waiting, in queue
    /// order. Tapping one switches the visible card to it. (Idle sessions aren't targetable:
    /// the only way to reach a session is to answer the hook it's blocked on.)
    var selectableAgents: [SelectableAgent] {
      let currentSessionID = current?.sessionID
      return requests.compactMap { request in
        guard let sessionID = request.sessionID else { return nil }
        return SelectableAgent(
          id: sessionID,
          projectName: request.context.projectName,
          iconURL: request.context.projectIconURL,
          isCurrent: sessionID == currentSessionID
        )
      }
    }
  }

  enum Action {
    case show(ShowPayload)
    case openManually
    case selectAgent(String)              // switch the window to another blocked session
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

        if let existing = state.requests[id: id] {
          // Same session re-presenting: release its now-stale hook before replacing it.
          if let oldPath = existing.payloadPath, oldPath != request.payloadPath {
            AgentHookResponder.respond(payloadPath: oldPath, json: nil)
          }
          // Preserve a previously-resolved avatar so the re-show doesn't flicker / refetch.
          if request.context.projectIconURL == nil {
            request.context.projectIconURL = existing.context.projectIconURL
          }
          state.requests[id: id] = request
        } else {
          // A newer request from a *different* session no longer releases the current
          // one — it joins the queue behind it.
          state.requests.append(request)
        }

        // Become the visible card only when nothing is showing, or when the card being
        // updated IS the current one. Otherwise it waits its turn (FIFO) silently.
        if state.currentID == nil || state.currentID == id {
          // A hook bringing the panel up from hidden appears passively — never grabbing focus
          // from the editor. (Advancing an already-engaged queue keeps its focus.)
          if !state.isVisible { state.wantsFocus = false }
          return present(&state, id: id)
        }
        return .none

      case .openManually:
        guard state.hexSettings.agentPluginsEnabled else { return .none }
        // A passive card on screen (a hook appeared while you were working): the first press
        // "engages" it — grab focus so you can type or dictate a reply. Once it's focused, a
        // second press toggles it away.
        if state.isVisible {
          if state.wantsFocus { return .send(.dismiss) }
          state.wantsFocus = true
          return .cancel(id: CancelID.autoSend)
        }
        agentFeatureLogger.notice("Agent window summoned via hotkey")
        state.isVisible = true
        state.pendingReveal = false
        state.noSessionsError = false
        state.wantsFocus = true

        // Summoning only does something when a session is blocked and waiting. There's no
        // proactive "talk to an idle session" anymore — that needs a live hook to answer.
        if let blocked = state.requests.first {
          return .merge(.cancel(id: CancelID.autoSend), present(&state, id: blocked.id))
        }
        state.noSessionsError = true
        return .cancel(id: CancelID.autoSend)

      case let .selectAgent(sessionID):
        // Already showing it — nothing to do.
        if state.current?.sessionID == sessionID { return .none }
        // Tapping the selector is active engagement — focus the card you switched to.
        state.wantsFocus = true
        guard state.requests[id: sessionID] != nil else { return .none }
        return .merge(.cancel(id: CancelID.autoSend), present(&state, id: sessionID))

      case let .promptLoaded(id, prompt):
        state.requests[id: id]?.prompt = prompt
        // Only the front card speaks/reveals; a preloaded waiting card just caches.
        guard id == state.currentID else { return .none }
        return speakThenReveal(state)

      case let .projectIconResolved(id, url):
        state.requests[id: id]?.context.projectIconURL = url
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
        guard let id = state.currentID,
              let payloadPath = state.requests[id: id]?.payloadPath else { return .none }
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

      case .send:
        guard let id = state.currentID, let request = state.requests[id: id] else { return .none }
        let text = request.draftReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }

        let prompt = request.prompt
        // Without a payload file there's no in-band channel to answer through; just tear the
        // card down. (In practice every presented hook carries one.)
        guard let payloadPath = request.payloadPath else {
          state.requests.remove(id: id)
          return .merge(
            .cancel(id: CancelID.autoSend),
            .run { _ in await speechSynthesizer.stop() },
            advance(&state)
          )
        }
        state.requests.remove(id: id)
        return .merge(
          .cancel(id: CancelID.autoSend),
          .run { _ in await speechSynthesizer.stop() },
          advance(&state),
          .run { send in
            AgentHookResponder.respondAnswer(payloadPath: payloadPath, prompt: prompt, answer: text)
            await send(.sent)
          }
        )

      case .sent:
        soundEffect.play(.pasteTranscript)
        return .none
      }
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
  /// the setting is off or there's no session id.
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
