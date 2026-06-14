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
      inputCard
    }
    .frame(width: cardWidth)
    .padding(16) // breathing room so each card's shadow isn't clipped by the window
    .onAppear { DispatchQueue.main.async { replyFocused = true } }
    .onExitCommand { store.send(.dismiss) }
  }

  private var hasOutput: Bool {
    switch store.prompt {
    case let .message(text): return !text.isEmpty
    case .question, .permission: return true
    }
  }

  // MARK: Output card (message / question / permission)

  private var outputCard: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        cardHeader
        switch store.prompt {
        case let .message(text):
          markdown(text)
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

  /// Identifies which session this card belongs to — the project (cwd basename) — with a
  /// passive "n / N" position indicator when several sessions are queued.
  @ViewBuilder
  private var cardHeader: some View {
    let project = store.projectName
    if project != nil || store.queueCount > 1 {
      HStack(spacing: 6) {
        if let project {
          projectIcon
          Text(project)
            .font(.caption.weight(.semibold))
        }
        Spacer(minLength: 0)
        if store.queueCount > 1 {
          Text("\(store.queuePosition) / \(store.queueCount)")
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.1), in: Capsule())
        }
      }
      .lineLimit(1)
      .padding(.bottom, 2)
    }
  }

  /// The project's GitHub owner avatar when we resolved one, falling back to the folder
  /// glyph while it loads, when there's no GitHub remote, or if the fetch fails.
  @ViewBuilder
  private var projectIcon: some View {
    if let url = store.projectIconURL {
      AsyncImage(url: url) { phase in
        if case let .success(image) = phase {
          image.resizable().aspectRatio(contentMode: .fill)
        } else {
          folderGlyph
        }
      }
      .frame(width: 18, height: 18)
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    } else {
      folderGlyph
    }
  }

  private var folderGlyph: some View {
    Image(systemName: "folder.fill")
      .font(.caption2)
      .foregroundStyle(.tertiary)
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
      // Plain Return submits; multi-line replies are rare and still reachable via ⌥Return.
      .onSubmit { store.send(.send) }
      // Shift+Return would normally insert a newline — make it send too.
      .onKeyPress(.return, phases: .down) { press in
        guard press.modifiers.contains(.shift) else { return .ignored }
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

        Spacer()

        hint("Dismiss", key: "esc") { store.send(.dismiss) }
        hint("Send", key: "⏎") { store.send(.send) }
          .disabled(store.draftReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
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
