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
  /// Parsed from a `hex://agent-update?…` deeplink, plus the terminal we should send
  /// the answer to (captured by the app delegate, which tracks the last foreground app).
  struct ShowPayload: Equatable {
    var event: String?
    var tool: String?
    var sessionID: String?
    var cwd: String?
    var transcriptPath: String?
    var payloadPath: String?
    var inlineMessage: String?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var sourceAppPID: pid_t?
  }

  /// One waiting Claude session. Each owns its own payload/session context plus its own
  /// draft reply and selection, so flipping between cards never loses what you typed.
  struct AgentRequest: Equatable, Identifiable {
    var event: String?
    var sessionID: String?
    var cwd: String?
    var transcriptPath: String?
    var payloadPath: String?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var sourceAppPID: pid_t?

    var prompt: AgentPrompt = .message("")
    var selectedOptions: Set<String> = []
    var draftReply: String = ""
    /// 0...1 while the auto-send countdown runs after a paste/dictation; nil otherwise.
    var autoSendProgress: Double?
    /// The voice to read this card in (nil = the user's chosen default). Assigned once, at
    /// enqueue, and kept for the card's lifetime — so a session that arrived alongside
    /// another keeps its distinct voice even after the other is answered and it's alone.
    var voice: String?

    /// A session blocks on a single hook at a time, so the session id is the natural
    /// identity; fall back to the payload path, then a singleton id for manually-summoned
    /// cards that have no hook at all.
    var id: String { sessionID ?? payloadPath ?? "manual" }

    init(from payload: ShowPayload) {
      event = payload.event
      sessionID = payload.sessionID
      cwd = payload.cwd
      transcriptPath = payload.transcriptPath
      payloadPath = payload.payloadPath
      sourceAppBundleID = payload.sourceAppBundleID
      sourceAppName = payload.sourceAppName
      sourceAppPID = payload.sourceAppPID
      prompt = .message(payload.inlineMessage ?? "")
    }

    /// A manually-summoned card (hotkey) with no hook — replies go to the captured app
    /// via the legacy typing path. `id` resolves to "manual".
    init(manualSourceApp app: NSRunningApplication?) {
      sourceAppBundleID = app?.bundleIdentifier
      sourceAppName = app?.localizedName
      sourceAppPID = app?.processIdentifier
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

    @Shared(.hexSettings) var hexSettings: HexSettings

    // MARK: Convenience accessors for the current card (keep the View unchanged).

    var current: AgentRequest? { currentID.flatMap { requests[id: $0] } }
    var prompt: AgentPrompt { current?.prompt ?? .message("") }
    var draftReply: String { current?.draftReply ?? "" }
    var selectedOptions: Set<String> { current?.selectedOptions ?? [] }
    var autoSendProgress: Double? { current?.autoSendProgress }

    // MARK: Header

    /// The project name shown in the card header — the basename of the session's cwd.
    var projectName: String? {
      guard let cwd = current?.cwd, !cwd.isEmpty else { return nil }
      return URL(fileURLWithPath: cwd).lastPathComponent
    }
    var sourceAppName: String? { current?.sourceAppName }
    var queueCount: Int { requests.count }
    /// 1-based position of the current card in the queue (0 when nothing is showing).
    var queuePosition: Int {
      guard let currentID, let idx = requests.index(id: currentID) else { return 0 }
      return idx + 1
    }
  }

  enum Action {
    case show(ShowPayload)
    case openManually
    case promptLoaded(AgentRequest.ID, AgentPrompt)
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
          state.requests[id: id] = request
        } else {
          // A newer request from a *different* session no longer releases the current
          // one — it joins the queue behind it.
          state.requests.append(request)
        }

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
        // Prefer the terminal actually hosting a claude session; fall back to whatever is
        // frontmost so the hotkey still does something useful.
        let hostApp = MainActor.assumeIsolated {
          ClaudeTerminalLocator.locate() ?? NSWorkspace.shared.frontmostApplication
        }
        let request = AgentRequest(manualSourceApp: hostApp)
        // A manual card has no blocked hook; jump it to the front so the summon shows now,
        // and let any queued hook cards resume when it's dismissed.
        state.requests[id: request.id] = nil
        state.requests.insert(request, at: 0)
        state.currentID = request.id
        state.isVisible = true
        state.pendingReveal = false
        return .cancel(id: CancelID.autoSend)

      case let .promptLoaded(id, prompt):
        state.requests[id: id]?.prompt = prompt
        // Only the front card speaks/reveals; a preloaded waiting card just caches.
        guard id == state.currentID else { return .none }
        return speakThenReveal(state)

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
        let pid = request.sourceAppPID
        let bundleID = request.sourceAppBundleID
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
    let payloadPath = request.payloadPath
    let transcriptPath = request.transcriptPath
    guard payloadPath != nil || transcriptPath != nil else { return speakThenReveal(state) }
    let fallback = request.prompt
    return .run { send in
      let prompt = (try? await agentTranscript.latestPrompt(payloadPath, transcriptPath)) ?? fallback
      await send(.promptLoaded(id, prompt))
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
