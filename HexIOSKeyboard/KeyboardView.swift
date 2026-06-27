//
//  KeyboardView.swift
//  HexIOSKeyboard
//
//  Mic-centric keyboard UI. No full QWERTY — the keyboard's job is to launch a
//  dictation and insert the result; users switch back to their normal keyboard
//  to type.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class KeyboardState {
    var statusText: String = "Tap to start a dictation session"
    var needsNextKeyboard: Bool = false
    var hasFullAccess: Bool = true
    /// A continuous Flow Session is active (dictate in place, no bounce).
    var sessionActive: Bool = false
    /// Currently capturing an utterance (mic is hot in the host app).
    var isCapturing: Bool = false
}

struct KeyboardView: View {
    let state: KeyboardState
    let onMic: () -> Void
    let onDelete: () -> Void
    let onNextKeyboard: () -> Void

    private var micBackground: Color {
        if !state.hasFullAccess { return .gray }
        return state.isCapturing ? .red : .accentColor
    }

    var body: some View {
        VStack(spacing: 12) {
            if !state.hasFullAccess {
                Text("Enable **Full Access** for Hex in Settings ▸ General ▸ Keyboards to dictate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(action: onMic) {
                Image(systemName: state.isCapturing ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(micBackground, in: .circle)
            }
            .disabled(!state.hasFullAccess)

            Text(state.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if state.sessionActive {
                Label("Session active", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 0)

            HStack {
                if state.needsNextKeyboard {
                    Button(action: onNextKeyboard) {
                        Image(systemName: "globe")
                            .font(.title3)
                            .frame(width: 44, height: 36)
                    }
                }
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "delete.left")
                        .font(.title3)
                        .frame(width: 44, height: 36)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
