//
//  AgentView.swift
//  Hex
//
//  The floating voice window shown when Claude Code pings Hex. Mirrors superwhisper:
//  two separate floating cards — a markdown output card on top, a gap, then a detached
//  input card below for dictating/typing the reply.
//

import ComposableArchitecture
import HexCore
import MarkdownUI
import SwiftUI

struct AgentView: View {
  @Bindable var store: StoreOf<AgentFeature>
  @FocusState private var replyFocused: Bool

  private let cardWidth: CGFloat = 480

  var body: some View {
    VStack(spacing: 10) {
      if hasOutput {
        outputCard
      }
      // Once the hook has timed out the reply can't be delivered, so the input field is
      // replaced by a brief notice — only dismissing the stale card remains.
      if store.isExpired {
        expiredCard
      } else {
        inputCard
      }
    }
    // Focus the reply field only when you've engaged the card (tapping the selector / clicking
    // the field) — never on a passive hook appearance, so it can't steal keystrokes.
    .onAppear { if store.wantsFocus { focusReply() } }
    .onChange(of: store.wantsFocus) { _, wants in
      if wants { focusReply() } else { replyFocused = false }
    }
    .frame(width: cardWidth)
    .padding(16) // breathing room so each card's shadow isn't clipped by the window
    .onExitCommand { store.send(.dismiss) }
  }

  /// Async hop so the field is in the hierarchy before we make it first responder.
  private func focusReply() {
    DispatchQueue.main.async { replyFocused = true }
  }

  private var hasOutput: Bool {
    switch store.prompt {
    case let .message(text, _): return !text.isEmpty
    case .question, .permission: return true
    }
  }

  // MARK: Output card (message / question / permission)

  private var outputCard: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        cardHeader
        switch store.prompt {
        case let .message(text, condensed):
          // In condensed mode show the summary that's being read aloud, so the card matches
          // the speech; fall back to the full reply when there's no summary.
          markdown(store.useCondensed ? (condensed ?? text) : text)
        case let .question(question):
          questionView(question)
        case let .permission(permission):
          permissionView(permission)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 420)
    .fixedSize(horizontal: false, vertical: true)
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(FloatingCard())
  }

  /// Identifies which session this card belongs to. With several remembered sessions it
  /// becomes a selector — a row of project avatars you can tap to retarget the window;
  /// otherwise it's the single project's avatar and name.
  @ViewBuilder
  private var cardHeader: some View {
    let agents = store.selectableAgents
    if agents.count > 1 {
      HStack(spacing: 8) {
        agentSelector(agents)
        Spacer(minLength: 0)
        if let project = store.projectName {
          projectLabel(project)
        }
      }
      .padding(.bottom, 2)
    } else if let project = store.projectName {
      HStack(spacing: 6) {
        avatar(store.projectIconURL)
          .frame(width: 18, height: 18)
          .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        projectLabel(project)
        Spacer(minLength: 0)
      }
      .padding(.bottom, 2)
    }
  }

  /// `project • branch` for the header, with the branch ellipsized past a sane length so a
  /// long branch can't blow out the one-line header.
  @ViewBuilder
  private func projectLabel(_ project: String) -> some View {
    HStack(spacing: 5) {
      Text(project)
        .font(.caption.weight(.semibold))
      if let branch = store.branchName, !branch.isEmpty {
        Text("•")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(Self.truncatedBranch(branch))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
  }

  /// Truncates a long branch name with an ellipsis so the header stays one tidy line.
  private static func truncatedBranch(_ branch: String, max: Int = 28) -> String {
    branch.count > max ? String(branch.prefix(max - 1)) + "…" : branch
  }

  /// A tappable avatar per blocked session. The current one is ringed and larger; tapping a
  /// sibling switches the visible card to it.
  private func agentSelector(_ agents: [AgentFeature.State.SelectableAgent]) -> some View {
    HStack(spacing: 7) {
      ForEach(agents) { agent in
        Button { store.send(.selectAgent(agent.id)) } label: {
          let side: CGFloat = agent.isCurrent ? 24 : 20
          avatar(agent.iconURL)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(agent.isCurrent ? Color.accentColor : .clear, lineWidth: 2)
            )
            .opacity(agent.isCurrent ? 1 : 0.7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(agent.projectName ?? "Session")
      }
    }
  }

  /// The project's GitHub owner avatar when we resolved one, falling back to the folder
  /// glyph while it loads, when there's no GitHub remote, or if the fetch fails.
  @ViewBuilder
  private func avatar(_ url: URL?) -> some View {
    if let url {
      AsyncImage(url: url) { phase in
        if case let .success(image) = phase {
          image.resizable().aspectRatio(contentMode: .fill)
        } else {
          folderGlyph
        }
      }
    } else {
      folderGlyph
    }
  }

  private var folderGlyph: some View {
    ZStack {
      Color.white.opacity(0.06)
      Image(systemName: "folder.fill")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private func markdown(_ text: String) -> some View {
    Markdown(text)
      .markdownTextStyle { FontSize(13) }
      .textSelection(.enabled)
  }

  private func tag(_ text: String) -> some View {
    Text(text)
      .font(.caption2.weight(.bold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.white.opacity(0.1), in: Capsule())
  }

  // MARK: Question

  @ViewBuilder
  private func questionView(_ q: AgentQuestion) -> some View {
    if !q.header.isEmpty { tag(q.header.uppercased()) }
    markdown(q.question)
    VStack(spacing: 6) {
      ForEach(q.options) { option in
        optionRow(option, multiSelect: q.multiSelect)
      }
    }
    .disabled(store.isExpired)
    if q.multiSelect {
      Text("Select one or more, then Send.")
        .font(.caption).foregroundStyle(.tertiary)
    }
  }

  private func optionRow(_ option: AgentOption, multiSelect: Bool) -> some View {
    let selected = store.selectedOptions.contains(option.label)
    return Button {
      store.send(multiSelect ? .toggleOption(option) : .selectOption(option))
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: multiSelect
          ? (selected ? "checkmark.square.fill" : "square")
          : "circle")
          .foregroundStyle(selected ? Color.accentColor : .secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(option.label).font(.body.weight(.medium))
          if !option.detail.isEmpty {
            Text(option.detail).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.05))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .white.opacity(0.08))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: Permission

  @ViewBuilder
  private func permissionView(_ p: AgentPermission) -> some View {
    tag("PERMISSION")
    Text("Claude wants to use \(p.tool)")
      .font(.body.weight(.medium))
    if !p.summary.isEmpty {
      Text(p.summary)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.18)))
    }
    HStack(spacing: 8) {
      Button("Allow") { store.send(.respondPermission(allow: true)) }
        .buttonStyle(.borderedProminent)
      Button("Deny", role: .destructive) { store.send(.respondPermission(allow: false)) }
        .buttonStyle(.bordered)
    }
    .disabled(store.isExpired)
  }

  // MARK: Input card (separate, below)

  private var inputCard: some View {
    VStack(spacing: 8) {
      // A vertical-axis TextField grows with its content (one line by default, up to a
      // few before it scrolls) instead of reserving a tall fixed box.
      TextField(
        "Type or hold your hotkey to dictate a reply.",
        text: Binding(
          get: { store.draftReply },
          set: { store.send(.draftChanged($0)) }
        ),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .focused($replyFocused)
      .font(.body)
      .lineLimit(1 ... 6)
      // Any Return — plain or with any modifier (⇧⌘⌥⌃) — sends. We never insert a newline
      // from the keyboard; every Enter completes the reply.
      .onSubmit { store.send(.send) }
      .onKeyPress(.return, phases: .down) { _ in
        store.send(.send)
        return .handled
      }
      // The focused field editor swallows Escape before it can reach the VStack's
      // `.onExitCommand`, so dismiss (and stop any read-aloud) from here directly.
      .onKeyPress(.escape) {
        store.send(.dismiss)
        return .handled
      }

      if let progress = store.autoSendProgress {
        autoSendBar(progress)
      }

      HStack(spacing: 10) {
        speakToggle
        // Condensed on/off — only meaningful (and only costs tokens) while reading aloud.
        if store.hexSettings.agentSpeakOutput {
          condensedToggle
        }

        Spacer()

        hint("Dismiss", key: "esc") { store.send(.dismiss) }
        hint("Send", key: "⏎") { store.send(.send) }
          .disabled(store.draftReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(12)
    .modifier(FloatingCard())
  }

  // MARK: Expired card (replaces the input card once the hook has timed out)

  private var expiredCard: some View {
    HStack(spacing: 10) {
      Image(systemName: "clock.badge.xmark")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("Session timed out")
          .font(.callout.weight(.medium))
        Text("Claude is no longer waiting — reply in the terminal instead.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      hint("Dismiss", key: "esc") { store.send(.dismiss) }
    }
    .padding(12)
    .modifier(FloatingCard())
  }

  /// Thin countdown shown after a paste/dictation lands in the field; the reply sends
  /// itself when the bar fills. Clicking (or typing) cancels.
  private func autoSendBar(_ progress: Double) -> some View {
    Button {
      store.send(.cancelAutoSend)
    } label: {
      HStack(spacing: 8) {
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.12))
            Capsule()
              .fill(Color.accentColor)
              .frame(width: geo.size.width * progress)
              .animation(.linear(duration: 0.06), value: progress)
          }
        }
        .frame(height: 3)
        Text("Sending — click to cancel")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var speakToggle: some View {
    let enabled = store.hexSettings.agentSpeakOutput
    return Button {
      store.send(.toggleSpeakOutput)
    } label: {
      // A solid backing circle so the glyph reads clearly over the translucent card —
      // the `.circle.fill` symbol's cutout would otherwise show the terminal through it.
      Image(systemName: enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(
          Circle().fill(enabled ? Color.accentColor : Color.secondary.opacity(0.7))
        )
    }
    .buttonStyle(.plain)
    .help(enabled ? "Stop reading output aloud" : "Read output aloud")
  }

  /// Switches read-aloud between the condensed summary and the full reply. Shown only when
  /// reading aloud and the current card actually has a summary.
  private var condensedToggle: some View {
    let condensed = store.useCondensed
    return Button {
      store.send(.toggleSpeakCondensed)
    } label: {
      Image(systemName: condensed ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(
          Circle().fill(condensed ? Color.accentColor : Color.secondary.opacity(0.7))
        )
    }
    .buttonStyle(.plain)
    .help(condensed
      ? "Reading a condensed summary (uses an extra model call) — tap to read the full reply instead"
      : "Reading the full reply — tap to read a condensed summary (uses an extra model call)")
  }

  private func hint(_ title: String, key: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title).font(.callout)
        Text(key)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
      .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
  }
}

/// Shared look for the two floating cards: translucent material, rounded, soft shadow.
private struct FloatingCard: ViewModifier {
  func body(content: Content) -> some View {
    content
      // Translucent frosted glass: the blur keeps text legible while the terminal
      // shows through behind it (vs. the near-opaque .ultraThickMaterial).
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(.white.opacity(0.08))
      )
      // Flatten so the shadow follows the rounded shape instead of a hard rectangle.
      .compositingGroup()
      .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 4)
  }
}
