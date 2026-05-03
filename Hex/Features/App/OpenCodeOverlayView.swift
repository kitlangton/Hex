import AppKit
import ComposableArchitecture
import Inject
import SwiftUI

private struct OpenCodeTransientState: Equatable {
  let title: String
  let detail: String
  let color: Color
}

struct OpenCodeOverlayView: View {
  @Bindable var store: StoreOf<OpenCodeCommandFeature>
  @ObserveInjection var inject
  @State private var copiedActivityID: String?

  private var mergedActivities: [OpenCodeSessionActivity] {
    // Draft activities are pushed into runtimeStatus.activities directly
    // via the reducer so identity is stable across the full lifecycle
    store.runtimeStatus.activities
  }

  private var visibleActivities: [OpenCodeSessionActivity] {
    Array(mergedActivities.prefix(4).reversed())
  }

  private var transientPill: OpenCodeTransientState? {
    switch store.runtimeStatus.phase {
    case let .error(message):
      guard visibleActivities.isEmpty else { return nil }
      return .init(title: "OpenCode", detail: message, color: .red)
    case .idle, .ready, .startingServer:
      return nil
    }
  }

  private var showsOverlay: Bool {
    transientPill != nil || !visibleActivities.isEmpty || store.isDismissingOverlay
  }

  var body: some View {
    Group {
      if showsOverlay {
        VStack(alignment: .trailing, spacing: 8) {
          ForEach(Array(visibleActivities.enumerated()), id: \.element.id) { index, activity in
            OpenCodeActivityPill(
              activity: activity,
              expanded: index == visibleActivities.count - 1,
              isNewest: index == visibleActivities.count - 1,
              copied: copiedActivityID == activity.id,
              meter: store.meter,
              runtimePhase: store.runtimeStatus.phase,
              queuedCommands: store.runtimeStatus.queuedCommands,
              activeSessions: store.runtimeStatus.activeSessions
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture {
              copyActivity(activity)
            }
          }

          if let transientPill {
            OpenCodeTransientPill(
              pill: transientPill,
              meter: store.meter,
              queuedCommands: store.runtimeStatus.queuedCommands,
              activeSessions: store.runtimeStatus.activeSessions
            )
          }
        }
        .padding(.trailing, 24)
        .padding(.bottom, 24)
        .transition(.openCodePillStack)
      }
    }
    .animation(.spring(duration: 0.28), value: store.runtimeStatus)
    .animation(.spring(duration: 0.32), value: showsOverlay)
    .animation(.spring(duration: 0.32), value: mergedActivities)
    .animation(.spring(duration: 0.32), value: visibleActivities.map(\.id))
    .enableInjection()
  }

  private func copyActivity(_ activity: OpenCodeSessionActivity) {
    let text = activity.responseText.isEmpty ? activity.command : activity.responseText
    guard !text.isEmpty else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copiedActivityID = activity.id

    Task {
      try? await Task.sleep(for: .seconds(1.2))
      await MainActor.run {
        if copiedActivityID == activity.id {
          copiedActivityID = nil
        }
      }
    }
  }
}

private struct OpenCodeActivityPill: View {
  let activity: OpenCodeSessionActivity
  let expanded: Bool
  let isNewest: Bool
  let copied: Bool
  let meter: Meter
  let runtimePhase: OpenCodeRuntimePhase
  let queuedCommands: Int
  let activeSessions: Int

  private var color: Color {
    switch activity.status {
    case .listening:
      return .purple
    case .transcribing:
      return .indigo
    case .queued:
      return .orange
    case .running:
      return .teal
    case .completed:
      return .green
    case .error:
      return .red
    }
  }

  private var statusLabel: String {
    if copied {
      return "copied"
    }

    switch activity.status {
    case .listening:
      return "listening"
    case .transcribing:
      return "transcribing"
    case .queued:
      return "queued"
    case .running:
      return "running"
    case .completed:
      return "done"
    case .error:
      return "error"
    }
  }

  private var primaryText: String {
    let text = activity.command.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "Voice action" : text
  }

  private var secondaryText: String? {
    if isNewest,
       runtimePhase == .startingServer,
       (activity.status == .queued || activity.status == .running) {
      return "Starting local server"
    }

    if case let .error(message) = activity.status {
      return message
    }

    switch activity.status {
    case .listening, .transcribing:
      return activity.responseText
    case .queued, .running, .completed, .error:
      break
    }

    if let tool = activity.toolCalls.last {
      return "tool: \(tool.title)"
    }

    if !activity.responseText.isEmpty {
      return activity.responseText
    }

    return nil
  }

  private var showsLiveMeter: Bool {
    activity.status == .listening
  }

  var body: some View {
    VStack(alignment: .leading, spacing: expanded ? 8 : 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(primaryText)
          .font(.system(size: expanded ? 13 : 12, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(expanded ? 2 : 1)

        Spacer(minLength: 8)

        OpenCodeStatusChip(text: statusLabel, color: color)
      }

      if expanded {
        if let secondaryText, !secondaryText.isEmpty {
          Text(secondaryText)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.76))
            .lineLimit(8)
            .fixedSize(horizontal: false, vertical: true)
        }

        if !activity.toolCalls.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(activity.toolCalls.suffix(3)) { tool in
              HStack(spacing: 5) {
                Circle()
                  .fill(color.opacity(0.7))
                  .frame(width: 3.5, height: 3.5)
                Text(tool.title)
                  .font(.system(size: 11, weight: .medium, design: .monospaced))
                  .foregroundStyle(Color.white.opacity(0.6))
                  .lineLimit(1)
                Text(tool.status)
                  .font(.system(size: 10, weight: .medium))
                  .foregroundStyle(Color.white.opacity(0.4))
                  .lineLimit(1)
              }
            }
          }
        }

        HStack(spacing: 6) {
          if queuedCommands > 0, isNewest {
            OpenCodeMetaChip(text: "Queue \(queuedCommands)")
          }

          if activeSessions > 0, isNewest {
            OpenCodeMetaChip(text: "Active \(activeSessions)")
          }
        }
      } else if let secondaryText, !secondaryText.isEmpty {
        Text(secondaryText)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color.white.opacity(0.64))
          .lineLimit(2)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, expanded ? 12 : 10)
    .frame(width: expanded ? 360 : 272, alignment: .leading)
    .background(
      showsLiveMeter
        ? AnyView(OpenCodeLivePillBackground(color: color, meter: meter, isListening: true))
        : AnyView(OpenCodePillBackground(color: color, expanded: expanded))
    )
    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    .compositingGroup()
    .transition(.openCodePill)
  }
}

private struct OpenCodeTransientPill: View {
  let pill: OpenCodeTransientState
  let meter: Meter
  let queuedCommands: Int
  let activeSessions: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Circle()
          .fill(pill.color)
          .frame(width: 9, height: 9)

        Text(pill.title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)

        Spacer(minLength: 8)

        OpenCodeStatusChip(text: "live", color: pill.color)
      }

      Text(pill.detail)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.82))
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        if queuedCommands > 0 {
          OpenCodeMetaChip(text: "Queue \(queuedCommands)")
        }

        if activeSessions > 0 {
          OpenCodeMetaChip(text: "Active \(activeSessions)")
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(width: 360, alignment: .leading)
    .background(OpenCodeLivePillBackground(color: pill.color, meter: meter, isListening: false))
    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    .compositingGroup()
    .transition(.openCodePill)
  }
}

private struct OpenCodePillBackground: View {
  let color: Color
  let expanded: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: expanded ? 16 : 14)
      .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(expanded ? 0.96 : 0.90))
      .overlay(
        RoundedRectangle(cornerRadius: expanded ? 16 : 14)
          .stroke(color.opacity(expanded ? 0.35 : 0.18), lineWidth: 1)
      )
  }
}

private struct OpenCodeLivePillBackground: View {
  let color: Color
  let meter: Meter
  let isListening: Bool

  var body: some View {
    let peakPower = min(1, meter.peakPower * 3)

    RoundedRectangle(cornerRadius: 16)
      .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.96))
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .stroke(color.opacity(0.35), lineWidth: 1)
      )
      .overlay(alignment: .leading) {
        if isListening {
          GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 12)
              .fill(color.opacity(peakPower < 0.08 ? peakPower * 1.5 : 0.25))
              .frame(width: max(proxy.size.width * (peakPower + 0.15), 20))
              .blur(radius: 8)
              .blendMode(.screen)
              .padding(6)
              .animation(.interactiveSpring(), value: meter)
          }
        }
      }
  }
}

private struct OpenCodeStatusChip: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold, design: .rounded))
      .foregroundStyle(color)
      .contentTransition(.interpolate)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(color.opacity(0.12)))
      .lineLimit(1)
  }
}

private struct OpenCodeMetaChip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(.white.opacity(0.45))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(Color.white.opacity(0.06)))
      .contentTransition(.numericText())
  }
}

private struct OpenCodePillTransitionModifier: ViewModifier {
  let opacity: Double
  let blur: CGFloat
  let scaleY: CGFloat
  let offsetY: CGFloat

  func body(content: Content) -> some View {
    content
      .opacity(opacity)
      .blur(radius: blur)
      .scaleEffect(x: 0.98, y: scaleY, anchor: .bottomTrailing)
      .offset(y: offsetY)
  }
}

private extension AnyTransition {
  static var openCodePill: AnyTransition {
    .modifier(
      active: OpenCodePillTransitionModifier(opacity: 0, blur: 8, scaleY: 0.82, offsetY: 16),
      identity: OpenCodePillTransitionModifier(opacity: 1, blur: 0, scaleY: 1, offsetY: 0)
    )
    .combined(with: .opacity)
  }

  static var openCodePillStack: AnyTransition {
    .modifier(
      active: OpenCodePillTransitionModifier(opacity: 0, blur: 12, scaleY: 0.88, offsetY: 24),
      identity: OpenCodePillTransitionModifier(opacity: 1, blur: 0, scaleY: 1, offsetY: 0)
    )
    .combined(with: .opacity)
  }
}
