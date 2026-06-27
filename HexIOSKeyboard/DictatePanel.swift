//
//  DictatePanel.swift
//  HexIOSKeyboard
//
//  Panel 1 of the letter-free keyboard: the dictation surface. A large accent
//  mic button, an animated waveform while capturing, a tinted "mic hot · MM:SS
//  left" session pill, and a bottom row of globe / space / backspace / return.
//

import SwiftUI

struct DictatePanel: View {
    let state: KeyboardState
    let actions: KeyboardActions

    private var micBackground: Color {
        switch state.phase {
        case .noFullAccess: return Color(.systemGray3)
        case .recording: return .red
        default: return .accentColor
        }
    }

    private var micGlyph: String {
        state.isCapturing ? "stop.fill" : "mic.fill"
    }

    var body: some View {
        VStack(spacing: 10) {
            statusArea
                .frame(maxWidth: .infinity)

            Button(action: actions.onMic) {
                Image(systemName: micGlyph)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(micBackground, in: .circle)
                    .overlay {
                        if state.isCapturing {
                            Circle().stroke(Color.red.opacity(0.35), lineWidth: 6)
                                .scaleEffect(1.18)
                        }
                    }
            }
            .disabled(state.phase == .noFullAccess)
            .animation(.easeInOut(duration: 0.2), value: state.phase)

            Spacer(minLength: 0)

            bottomRow
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status area (one of the six states)

    @ViewBuilder
    private var statusArea: some View {
        switch state.phase {
        case .noFullAccess:
            statusLabel(
                "Enable **Full Access** in Settings ▸ General ▸ Keyboards to dictate.",
                systemImage: "lock.fill"
            )

        case .recording:
            VStack(spacing: 6) {
                WaveformView(isActive: true)
                sessionPill ?? AnyView(captionPill("Listening… tap to stop", tint: .red))
            }

        case .inserting:
            captionPill("Inserted", tint: .green, systemImage: "checkmark.circle.fill")

        case .needsBounce:
            captionPill("Session expired — tap mic to restart", tint: .orange, systemImage: "arrow.clockwise")

        case .error(let message):
            statusLabel(verbatim: message, systemImage: "exclamationmark.triangle.fill", tint: .orange)

        case .idle:
            if let pill = sessionPill {
                pill
            } else {
                captionPill(state.statusText, tint: .secondary)
            }
        }
    }

    /// The tinted "mic hot · MM:SS left" pill, present only when a live session
    /// has a countdown.
    private var sessionPill: AnyView? {
        guard state.sessionActive, let remaining = state.remainingText else { return nil }
        let view = HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("mic hot · \(remaining) left")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        return AnyView(view)
    }

    private func captionPill(_ text: String, tint: Color, systemImage: String? = nil) -> AnyView {
        let view = HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
        return AnyView(view)
    }

    private func statusLabel(_ markdown: LocalizedStringKey, systemImage: String, tint: Color = .secondary) -> some View {
        statusLabel(content: Text(markdown), systemImage: systemImage, tint: tint)
    }

    private func statusLabel(verbatim text: String, systemImage: String, tint: Color = .secondary) -> some View {
        statusLabel(content: Text(verbatim: text), systemImage: systemImage, tint: tint)
    }

    private func statusLabel(content: Text, systemImage: String, tint: Color) -> some View {
        Label {
            content
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }

    // MARK: - Bottom row

    private var bottomRow: some View {
        HStack(spacing: 8) {
            if state.needsNextKeyboard {
                KeyboardKey(systemImage: "globe", action: actions.onNextKeyboard)
            }
            KeyboardKey(systemImage: "delete.left", action: actions.onDelete)
            Button(action: actions.onSpace) {
                Text("space")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            KeyboardKey(systemImage: "return", action: actions.onReturn)
        }
        .padding(.horizontal, 6)
    }
}

/// A small monochrome key with an SF Symbol glyph.
struct KeyboardKey: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 52, height: 40)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
