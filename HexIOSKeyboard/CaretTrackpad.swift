//
//  CaretTrackpad.swift
//  HexIOSKeyboard
//
//  A draggable area that moves the text cursor, mirroring the native
//  hold-and-drag-spacebar gesture. Horizontal drag distance maps to character
//  offsets via `textDocumentProxy.adjustTextPosition(byCharacterOffset:)`, with
//  a small dead-zone-free, slightly-accelerated mapping so it feels native.
//

import SwiftUI

struct CaretTrackpad: View {
    /// Called with a signed character delta (+ = right, − = left) each time the
    /// accumulated drag crosses a character boundary.
    let onCaretMove: (Int) -> Void

    /// Points of horizontal travel per single-character step at slow speed.
    private let pointsPerCharacter: CGFloat = 9

    @State private var lastTranslation: CGFloat = 0
    @State private var accumulated: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isDragging ? Color.accentColor.opacity(0.6) : Color(.separator), lineWidth: 1)
                }

            VStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right")
                    .font(.title3)
                    .foregroundStyle(isDragging ? Color.accentColor : .secondary)
                Text("Slide to move cursor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        lastTranslation = 0
                        accumulated = 0
                    }
                    let frameDelta = value.translation.width - lastTranslation
                    lastTranslation = value.translation.width

                    // Light acceleration: faster swipes move proportionally more.
                    let speedFactor = 1 + min(abs(frameDelta) / 8, 2)
                    accumulated += frameDelta * speedFactor

                    let steps = Int(accumulated / pointsPerCharacter)
                    if steps != 0 {
                        onCaretMove(steps)
                        accumulated -= CGFloat(steps) * pointsPerCharacter
                    }
                }
                .onEnded { _ in
                    isDragging = false
                    lastTranslation = 0
                    accumulated = 0
                }
        )
        .animation(.easeInOut(duration: 0.15), value: isDragging)
    }
}
