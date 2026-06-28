//
//  AgentFeature.swift
//  Hex
//
//  Drives the Agent Plugins voice window. Shows what the agent is presenting (a plain
//  message, a multiple-choice question, or a permission request) and lets the user answer by
//  voice / typing / tapping an option, then answers the BLOCKED hook in-band: Hex writes the
//  complete hook-output JSON to `<payload>.response`, which the integration relays back to
//  the agent. No app focusing, no synthetic keystrokes — the answer can never land in the
//  wrong window, and the window only ever *responds* to a session that is blocked on a hook.
//
//  Multiple agent sessions can be blocked at once — each on its own hook — so the feature
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
    /// The project's GitHub owner, resolved by the hook from the repo's `origin` remote. The
    /// hook runs unsandboxed and can read the repo; the sandboxed app can't spawn `git`, so it
    /// just builds the avatar URL from this.
    var githubOwner: String?
    /// The current git branch, also resolved by the hook (sandboxed Hex can't run `git`).
    var branch: String?
  }

  /// The identity of one agent session: where it lives and the project it belongs to.
  struct SessionContext: Equatable {
    var cwd: String? = nil
    var transcriptPath: String? = nil
    /// The project's GitHub owner avatar, resolved once from the repo's `origin` remote. nil
    /// until resolved, or when the project has no GitHub remote (the header shows a folder).
    var projectIconURL: URL? = nil
    /// The current git branch (resolved by the hook); nil outside a repo or on a detached HEAD.
    var branch: String? = nil

    /// The project name shown in the header — the basename of the session's cwd.
    var projectName: String? {
      guard let cwd, !cwd.isEmpty else { return nil }
      return URL(fileURLWithPath: cwd).lastPathComponent
    }
  }

  /// One card in the window — an agent hook blocked polling for our response file. Each owns
  /// its own draft reply and selection, so flipping between cards never loses what you typed.
  struct AgentRequest: Equatable, Identifiable {
    /// The hook's payload file; the in-band channel we answer through. (Optional only to guard
    /// the degenerate case of a hook that arrived without one — it simply can't be answered.)
    var payloadPath: String?
    var sessionID: String?
    var context: SessionContext

    var prompt: AgentPrompt = .message("", condensed: nil)
    /// Per-card read-aloud mode: when true this card speaks the agent's condensed summary
    /// instead of the full reply. Each card keeps its own choice; not persisted.
    var useCondensed: Bool = false
    var selectedOptions: Set<String> = []
    var draftReply: String = ""
    /// 0...1 while the auto-send countdown runs after a paste/dictation; nil otherwise.
    var autoSendProgress: Double?
    /// The voice to read this card in (nil = the user's chosen default). Assigned once and
    /// kept for the card's lifetime — so a session keeps its distinct voice even after a
    /// sibling is answered and it's alone.
    var voice: String?
    /// True once this card's hook has timed out — the script deletes its payload file when it
    /// gives up polling (~570s), so the in-band answer channel is gone. We drop the reply field
    /// rather than let a reply land in the void; only Dismiss remains.
    var isExpired: Bool = false

    /// A session blocks on a single hook at a time, so the session id is the natural identity;
    /// fall back to the payload path for the rare hook that arrived without one.
    var id: String { sessionID ?? payloadPath ?? "manual" }

    init(from payload: ShowPayload) {
      payloadPath = payload.payloadPath
      sessionID = payload.sessionID
      context = SessionContext(
        cwd: payload.cwd,
        transcriptPath: payload.transcriptPath,
        projectIconURL: payload.githubOwner.flatMap { Self.avatarURL(owner: $0) },
        branch: payload.branch
      )
      prompt = .message(payload.inlineMessage ?? "", condensed: nil)
    }

    /// The GitHub owner avatar URL for the owner the hook resolved. nil when there's no owner.
    static func avatarURL(owner: String) -> URL? {
      let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return URL(string: "https://github.com/\(trimmed).png?size=128")
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
    /// Whether the panel should hold keyboard focus. False when a hook auto-presents, so the
    /// card appears passively and never steals keystrokes from the editor you're typing in;
    /// true once you engage it (tapping the selector / clicking the reply field), which is
    /// when we make it key so typing and dictation land in the reply field.
    var wantsFocus: Bool = false

    @Shared(.hexSettings) var hexSettings: HexSettings

    // MARK: Convenience accessors for the current card (keep the View unchanged).

    var current: AgentRequest? { currentID.flatMap { requests[id: $0] } }
    var prompt: AgentPrompt { current?.prompt ?? .message("", condensed: nil) }
    var draftReply: String { current?.draftReply ?? "" }

    /// Whether the visible card is set to read its condensed summary aloud.
    var useCondensed: Bool { current?.useCondensed ?? false }
    var selectedOptions: Set<String> { current?.selectedOptions ?? [] }
    var autoSendProgress: Double? { current?.autoSendProgress }
    /// The visible card's hook has timed out and can no longer be answered.
    var isExpired: Bool { current?.isExpired ?? false }

    // MARK: Header

    /// The project name shown in the card header — the basename of the session's cwd.
    var projectName: String? { current?.context.projectName }
    var projectIconURL: URL? { current?.context.projectIconURL }
    /// The current git branch for the visible card, when the hook resolved one.
    var branchName: String? { current?.context.branch }

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
    case selectAgent(String)              // switch the window to another blocked session
    case promptLoaded(AgentRequest.ID, AgentPrompt)
    case hookExpired(AgentRequest.ID)     // the card's hook timed out; can no longer be answered
    case revealPanel
    case dismiss
    case draftChanged(String)
    case selectOption(AgentOption)        // single-select: answers immediately
    case toggleOption(AgentOption)        // multi-select: toggles, Send submits
    case respondPermission(allow: Bool)   // permission allow/deny
    case toggleSpeakOutput
    case toggleSpeakCondensed             // read the condensed summary vs the full reply
    case autoSendTicked(Double)
    case cancelAutoSend
    case send
    case sent
  }

  enum CancelID { case autoSend, liveness }

  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.agentTranscript) var agentTranscript
  @Dependency(\.speechSynthesizer) var speechSynthesizer
  @Dependency(\.agentIntegrations) var agentIntegrations

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .show(payload):
        let enabled = state.hexSettings.agentPluginsEnabled
        agentFeatureLogger.notice("Agent show requested (enabled=\(enabled), event=\(payload.event ?? "nil", privacy: .public), tool=\(payload.tool ?? "nil", privacy: .public))")
        guard enabled else { return .none }

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
        // Default each card to the global condensed setting; the per-card toggle can still flip
        // it to the full reply for a single card.
        request.useCondensed = state.hexSettings.agentSpeakCondensed

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

      case let .hookExpired(id):
        guard state.requests[id: id] != nil, state.requests[id: id]?.isExpired == false else {
          return .none
        }
        state.requests[id: id]?.isExpired = true
        // Any pending auto-send would now write into a dead hook — drop it.
        state.requests[id: id]?.autoSendProgress = nil
        return .cancel(id: CancelID.autoSend)

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
        // Re-sync the on-disk read-aloud sentinel so the hook starts (or stops) generating a
        // spoken summary for the condensed read-aloud on its next turn.
        let resync: Effect<Action> = .run { _ in _ = await agentIntegrations.prepareAll() }
        if nowEnabled {
          return .merge(resync, speakIfEnabled(state))
        }
        return .merge(resync, .run { _ in await speechSynthesizer.stop() })

      case .toggleSpeakCondensed:
        guard let id = state.currentID else { return .none }
        // A live, per-card switch between the already-generated summary and the full reply.
        // Whether summaries are generated at all is the global setting's job, so this is free.
        state.requests[id: id]?.useCondensed.toggle()
        // Re-read the visible card in the newly chosen mode (no-op when read-aloud is off).
        return speakIfEnabled(state)

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
        guard FileManager.default.fileExists(atPath: payloadPath) else {
          return .send(.hookExpired(id))
        }
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
        // The hook may have timed out while the card sat idle (its payload file is gone the
        // moment the script gives up). Surface the dead state instead of writing into the void.
        guard FileManager.default.fileExists(atPath: payloadPath) else {
          return .send(.hookExpired(id))
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
      return .cancel(id: CancelID.liveness)
    }
    if !state.isVisible {
      // With read-aloud on, keep the panel hidden until the audio is ready so the window
      // appears the moment it starts talking (capped — see speakThenReveal).
      state.isVisible = !state.hexSettings.agentSpeakOutput
      state.pendingReveal = !state.isVisible
    }
    let payloadPath = request.payloadPath
    let transcriptPath = request.context.transcriptPath
    // Watch the now-visible card's hook for the rest of its life; expired cards drop their reply field.
    let liveness = monitorLiveness(id, payloadPath: payloadPath)
    guard payloadPath != nil || transcriptPath != nil else {
      return .merge(liveness, speakThenReveal(state))
    }
    let fallback = request.prompt
    return .merge(liveness, .run { send in
      let prompt = (try? await agentTranscript.latestPrompt(payloadPath, transcriptPath)) ?? fallback
      await send(.promptLoaded(id, prompt))
    })
  }

  /// Polls the visible card's payload file — the hook's liveness beacon. The script writes it
  /// before opening the deeplink and deletes it the instant it stops polling (answered, or
  /// timed out ~570s). When it vanishes the hook is gone, so we mark the card expired. Probing
  /// the file (not a wall clock) is what makes this correct across system sleep: the hook's
  /// poll loop is suspended while the Mac sleeps, so the file outlives a naive timer.
  private func monitorLiveness(_ id: AgentRequest.ID, payloadPath: String?) -> Effect<Action> {
    guard let payloadPath else { return .cancel(id: CancelID.liveness) }
    return .run { send in
      while !Task.isCancelled {
        try await Task.sleep(for: .seconds(2))
        if !FileManager.default.fileExists(atPath: payloadPath) {
          await send(.hookExpired(id))
          return
        }
      }
    }
    .cancellable(id: CancelID.liveness, cancelInFlight: true)
  }

  /// Moves to the next queued card (FIFO), or tears the panel down when the queue empties.
  private func advance(_ state: inout State) -> Effect<Action> {
    guard let next = state.requests.first?.id else {
      state.currentID = nil
      state.isVisible = false
      state.pendingReveal = false
      return .cancel(id: CancelID.liveness)
    }
    return present(&state, id: next)
  }

  /// How long we'll sit on a hidden panel waiting for synthesis (Kokoro can be slow
  /// on first use while its model downloads) before showing it anyway.
  static let revealCap: Duration = .seconds(60)

  /// Grace period before a pasted/dictated reply is sent automatically.
  static let autoSendDelay: Duration = .milliseconds(1500)

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
    let text = Self.spokenText(for: state.prompt, condensed: state.useCondensed)
    guard !text.isEmpty else { return .none }
    let voice = voiceIdentifier(for: state)
    return .run { _ in await speechSynthesizer.speak(text, voice) }
  }

  /// Starts reading the prompt, then reveals the panel once audio playback has begun
  /// (speak returns when sound starts) — or after `revealCap`, whichever comes first.
  /// If the panel is already visible (or there is nothing to say), it just speaks.
  private func speakThenReveal(_ state: State) -> Effect<Action> {
    guard !state.isVisible else { return speakIfEnabled(state) }
    let text = Self.spokenText(for: state.prompt, condensed: state.useCondensed)
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

  static func spokenText(for prompt: AgentPrompt, condensed: Bool) -> String {
    switch prompt {
    case let .message(text, summary):
      // Speak the short condensed summary when condensed mode is on and one exists; otherwise
      // fall back to the full reply.
      if condensed, let summary, !summary.isEmpty {
        return SpokenText.spoken(from: summary)
      }
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
