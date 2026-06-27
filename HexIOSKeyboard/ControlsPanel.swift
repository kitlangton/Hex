//
//  ControlsPanel.swift
//  HexIOSKeyboard
//
//  Panel 2 of the letter-free keyboard (P2-5): an editing control surface built
//  entirely from gestures/affordances users already know. NO letters — the globe
//  always hands off to the native keyboard for genuine free typing.
//
//  Contents: caret trackpad, delete-word, undo/redo, and a punctuation/symbols
//  cluster. Replace-by-voice needs no UI here — `insertText` already overwrites a
//  host-app selection, so a hint is surfaced instead.
//

import SwiftUI

struct ControlsPanel: View {
    let state: KeyboardState
    let actions: KeyboardActions

    /// Common punctuation, inserted verbatim via `insertText`.
    private let punctuation: [String] = [".", ",", "?", "!", "'", "\"", ":", ";", "-", "(", ")", "/", "@", "#", "&", "%"]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        VStack(spacing: 8) {
            // Top row: caret trackpad (the highest-value control) + edit actions.
            HStack(spacing: 8) {
                CaretTrackpad(onCaretMove: actions.onCaretMove)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)

                VStack(spacing: 6) {
                    editKey("Undo", systemImage: "arrow.uturn.backward", action: actions.onUndo)
                    editKey("Redo", systemImage: "arrow.uturn.forward", action: actions.onRedo)
                }
                .frame(width: 78)

                VStack(spacing: 6) {
                    editKey("Del word", systemImage: "delete.backward.fill", action: actions.onDeleteWord)
                    editKey("Delete", systemImage: "delete.left", action: actions.onDelete)
                }
                .frame(width: 78)
            }
            .padding(.horizontal, 6)

            // Punctuation cluster (the familiar native "123/symbols" idea).
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(punctuation, id: \.self) { symbol in
                    Button {
                        actions.onInsert(symbol)
                    } label: {
                        Text(symbol)
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 6)

            Text("Select a word in your app, then dictate to replace it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            // Globe stays available here too, so users can hand off without
            // swiping back to the dictate panel.
            if state.needsNextKeyboard {
                HStack {
                    KeyboardKey(systemImage: "globe", action: actions.onNextKeyboard)
                    Spacer()
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(state.phase == .noFullAccess)
        .opacity(state.phase == .noFullAccess ? 0.4 : 1)
    }

    private func editKey(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.callout)
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 29)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
