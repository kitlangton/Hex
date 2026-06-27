//
//  QwertyKeyboardView.swift
//  HexIOSKeyboard
//
//  A standard QWERTY layout that clones Apple's system keyboard styling and drops
//  the Hex mic into the bottom-right corner (where Apple's dictation mic lives).
//  This is the only SwiftUI surface; all text/IPC wiring stays in
//  `KeyboardViewController`. There is intentionally NO prediction/autocorrect bar:
//  a third-party extension doesn't get Apple's language model (a later step).
//
//  While `state.isCapturing` is true we dim the letters and show a "Listening…"
//  waveform with Cancel + red-stop controls (the recording state). The remaining
//  KeyboardPhase cases (noFullAccess, inserting, needsBounce, error) render as a
//  slim status banner above the live keys.
//

import SwiftUI

// MARK: - Layout model

/// A single key in a row. Most keys are letters; a few are "special" (shift,
/// backspace, etc.) and carry their own glyph + width behavior.
private enum KeyKind: Equatable {
    case character(String)
    case shift
    case backspace
    case modeSwitch(String)   // "123" / "ABC" / "#+="
    case globe
    case space
    case `return`
}

// MARK: - Shift / letter case state

private enum ShiftState: Equatable {
    case lowercase
    case shifted     // one-shot: reverts to lowercase after the next letter
    case capsLock

    var isUppercase: Bool { self != .lowercase }
}

private enum KeyboardLayer: Equatable {
    case letters
    case numbers      // 123
    case symbols      // #+=
}

struct QwertyKeyboardView: View {
    let state: KeyboardState
    let actions: KeyboardActions

    @Environment(\.colorScheme) private var colorScheme

    @State private var shift: ShiftState = .lowercase
    @State private var layer: KeyboardLayer = .letters

    var body: some View {
        ZStack {
            keyboardBackground.ignoresSafeArea()

            VStack(spacing: 6) {
                statusBanner

                if state.isCapturing {
                    RecordingSurface(state: state, actions: actions)
                        .transition(.opacity)
                } else {
                    keysSurface
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 3)
            .padding(.top, 4)
            .padding(.bottom, 3)
        }
        .animation(.easeInOut(duration: 0.15), value: state.isCapturing)
        .animation(.easeInOut(duration: 0.12), value: layer)
    }

    // MARK: - Background

    private var keyboardBackground: Color {
        // Matches the system keyboard's recessed tray color closely enough for a
        // third-party extension (we can't read the true system material).
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.17)
            : Color(red: 0.82, green: 0.83, blue: 0.85)
    }

    // MARK: - Status banner (non-recording phases)

    @ViewBuilder
    private var statusBanner: some View {
        switch state.phase {
        case .noFullAccess:
            banner(text: "Enable Full Access in Settings ▸ Keyboards",
                   systemImage: "exclamationmark.lock.fill",
                   tint: .orange)
        case .inserting:
            banner(text: "Inserted",
                   systemImage: "checkmark.circle.fill",
                   tint: .green)
        case .needsBounce:
            banner(text: "Tap the mic to start a new session",
                   systemImage: "arrow.up.forward.app.fill",
                   tint: .accentColor)
        case .error(let message):
            banner(text: message,
                   systemImage: "exclamationmark.triangle.fill",
                   tint: .red)
        case .idle, .recording:
            EmptyView()
        }
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
        )
        .padding(.horizontal, 3)
    }

    // MARK: - Keys surface

    private var keysSurface: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                KeyRow(
                    keys: row,
                    shift: shift,
                    layer: layer,
                    colorScheme: colorScheme,
                    onCharacter: handleCharacter,
                    onShift: handleShift,
                    onBackspace: { actions.onDelete() },
                    onModeSwitch: handleModeSwitch,
                    onGlobe: { actions.onNextKeyboard() },
                    onSpace: { actions.onSpace() },
                    onReturn: { actions.onReturn() },
                    onMic: { actions.onMic() },
                    micEnabled: state.hasFullAccess
                )
            }
        }
        .opacity(bannerDisablesKeys ? 0.4 : 1)
        .allowsHitTesting(!bannerDisablesKeys)
    }

    /// Only `noFullAccess` truly blocks typing (the mic is useless and we want the
    /// user to fix Full Access). Other phases are transient/informational, so keys
    /// stay live.
    private var bannerDisablesKeys: Bool {
        if case .noFullAccess = state.phase { return true }
        return false
    }

    private let rowSpacing: CGFloat = 8

    // MARK: - Row definitions per layer

    private var rows: [[KeyKind]] {
        switch layer {
        case .letters:
            return [
                "qwertyuiop".map { .character(String($0)) },
                "asdfghjkl".map { .character(String($0)) },
                [.shift] + "zxcvbnm".map { .character(String($0)) } + [.backspace],
                bottomRow,
            ]
        case .numbers:
            return [
                "1234567890".map { .character(String($0)) },
                "-/:;()$&@\"".map { .character(String($0)) },
                [.modeSwitch("#+=")] + ".,?!'".map { .character(String($0)) } + [.backspace],
                bottomRow,
            ]
        case .symbols:
            return [
                "[]{}#%^*+=".map { .character(String($0)) },
                "_\\|~<>€£¥•".map { .character(String($0)) },
                [.modeSwitch("123")] + ".,?!'".map { .character(String($0)) } + [.backspace],
                bottomRow,
            ]
        }
    }

    /// The bottom row matches Apple's: mode-switch · globe · space · return. The
    /// Hex mic is appended by `KeyRow` in the corner (Apple's dictation spot).
    private var bottomRow: [KeyKind] {
        var keys: [KeyKind] = [.modeSwitch(layer == .letters ? "123" : "ABC")]
        if state.needsNextKeyboard {
            keys.append(.globe)
        }
        keys.append(.space)
        keys.append(.return)
        return keys
    }

    // MARK: - Handlers

    private func handleCharacter(_ raw: String) {
        let text: String
        if layer == .letters {
            text = shift.isUppercase ? raw.uppercased() : raw
        } else {
            text = raw
        }
        actions.onInsert(text)
        // One-shot shift reverts after a single letter (caps-lock persists).
        if shift == .shifted { shift = .lowercase }
    }

    private func handleShift() {
        switch shift {
        case .lowercase: shift = .shifted
        case .shifted: shift = .capsLock      // tap again → caps lock
        case .capsLock: shift = .lowercase
        }
    }

    private func handleModeSwitch(_ label: String) {
        switch label {
        case "123": layer = .numbers
        case "ABC": layer = .letters
        case "#+=": layer = .symbols
        default: break
        }
    }
}

// MARK: - Key row

private struct KeyRow: View {
    let keys: [KeyKind]
    let shift: ShiftState
    let layer: KeyboardLayer
    let colorScheme: ColorScheme

    let onCharacter: (String) -> Void
    let onShift: () -> Void
    let onBackspace: () -> Void
    let onModeSwitch: (String) -> Void
    let onGlobe: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onMic: () -> Void
    let micEnabled: Bool

    /// Does this row contain the space bar? If so it's the bottom row and gets the
    /// mic appended in the corner.
    private var isBottomRow: Bool {
        keys.contains { if case .space = $0 { return true }; return false }
    }

    var body: some View {
        HStack(spacing: keySpacing) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                keyButton(for: key)
                    .layoutPriority(layoutPriority(for: key))
            }
            if isBottomRow {
                MicKey(colorScheme: colorScheme, enabled: micEnabled, action: onMic)
            }
        }
    }

    private let keySpacing: CGFloat = 5.5

    /// Letters share width evenly; the wider special keys claim more via layout
    /// priority so they read like the system keyboard's proportions.
    private func layoutPriority(for key: KeyKind) -> Double {
        switch key {
        case .character: return 1
        case .shift, .backspace: return 1.5
        case .modeSwitch, .globe: return 1.4
        case .space: return 5
        case .return: return 2
        }
    }

    @ViewBuilder
    private func keyButton(for key: KeyKind) -> some View {
        switch key {
        case .character(let c):
            let display = (layer == .letters && shift.isUppercase) ? c.uppercased() : c
            LetterKey(label: display, colorScheme: colorScheme) {
                onCharacter(c)
            }
        case .shift:
            SpecialKey(colorScheme: colorScheme, emphasized: shift != .lowercase) {
                onShift()
            } content: {
                Image(systemName: shiftGlyph)
                    .font(.system(size: 17, weight: .regular))
            }
        case .backspace:
            SpecialKey(colorScheme: colorScheme) { onBackspace() } content: {
                Image(systemName: "delete.left")
                    .font(.system(size: 17, weight: .regular))
            }
        case .modeSwitch(let label):
            SpecialKey(colorScheme: colorScheme) { onModeSwitch(label) } content: {
                Text(label)
                    .font(.system(size: 15, weight: .regular))
            }
        case .globe:
            SpecialKey(colorScheme: colorScheme) { onGlobe() } content: {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .regular))
            }
        case .space:
            SpecialKey(colorScheme: colorScheme, light: true) { onSpace() } content: {
                Text("space")
                    .font(.system(size: 15, weight: .regular))
            }
        case .return:
            SpecialKey(colorScheme: colorScheme) { onReturn() } content: {
                Text("return")
                    .font(.system(size: 15, weight: .regular))
            }
        }
    }

    private var shiftGlyph: String {
        switch shift {
        case .lowercase: return "shift"
        case .shifted: return "shift.fill"
        case .capsLock: return "capslock.fill"
        }
    }
}

// MARK: - Individual key views

private let keyHeight: CGFloat = 44
private let keyCornerRadius: CGFloat = 5

private struct LetterKey: View {
    let label: String
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .background(
                RoundedRectangle(cornerRadius: keyCornerRadius, style: .continuous)
                    .fill(KeyStyle.letterFill(colorScheme))
                    .shadow(color: .black.opacity(0.28), radius: 0, x: 0, y: 1)
            )
            .overlay {
                // Press magnification bubble (nice-to-have).
                if isPressed {
                    MagnifyBubble(label: label, colorScheme: colorScheme)
                        .offset(y: -keyHeight)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.96 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isPressed { isPressed = true } }
                    .onEnded { _ in
                        isPressed = false
                        action()
                    }
            )
            .animation(.easeOut(duration: 0.05), value: isPressed)
    }
}

private struct MagnifyBubble: View {
    let label: String
    let colorScheme: ColorScheme

    var body: some View {
        Text(label)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .frame(width: 46, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(KeyStyle.letterFill(colorScheme))
                    .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
            )
    }
}

private struct SpecialKey<Content: View>: View {
    let colorScheme: ColorScheme
    var emphasized: Bool = false
    var light: Bool = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isPressed = false

    init(
        colorScheme: ColorScheme,
        emphasized: Bool = false,
        light: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.colorScheme = colorScheme
        self.emphasized = emphasized
        self.light = light
        self.action = action
        self.content = content
    }

    var body: some View {
        content()
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .background(
                RoundedRectangle(cornerRadius: keyCornerRadius, style: .continuous)
                    .fill(fill)
                    .shadow(color: .black.opacity(0.28), radius: 0, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.96 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isPressed { isPressed = true } }
                    .onEnded { _ in
                        isPressed = false
                        action()
                    }
            )
            .animation(.easeOut(duration: 0.05), value: isPressed)
    }

    private var fill: Color {
        if emphasized { return KeyStyle.emphasizedFill(colorScheme) }
        if light { return KeyStyle.letterFill(colorScheme) }
        return KeyStyle.specialFill(colorScheme)
    }
}

// MARK: - Mic key (bottom-right corner)

private struct MicKey: View {
    let colorScheme: ColorScheme
    let enabled: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: keyHeight)
                .background(
                    RoundedRectangle(cornerRadius: keyCornerRadius, style: .continuous)
                        .fill(enabled ? Color.accentColor : Color.gray)
                        .shadow(color: .black.opacity(0.28), radius: 0, x: 0, y: 1)
                )
                .scaleEffect(isPressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(.easeOut(duration: 0.05), value: isPressed)
        .accessibilityLabel("Dictate")
    }
}

// MARK: - Recording surface

private struct RecordingSurface: View {
    let state: KeyboardState
    let actions: KeyboardActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Text("Listening…")
                    .font(.headline)
                    .foregroundStyle(.primary)

                WaveformView(isActive: true)
                    .frame(height: 40)

                if let remaining = state.remainingText {
                    Text("\(remaining) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button(action: {
                    // TODO: discard — true discard isn't wired yet, so we stop
                    // capture (which transcribes what we have). Same as stop for now.
                    actions.onMic()
                }) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: keyHeight)
                        .background(
                            RoundedRectangle(cornerRadius: keyCornerRadius, style: .continuous)
                                .fill(KeyStyle.specialFill(colorScheme))
                        )
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Button(action: { actions.onMic() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: keyHeight)
                        .background(
                            RoundedRectangle(cornerRadius: keyCornerRadius, style: .continuous)
                                .fill(Color.red)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }
}

// MARK: - Shared key colors

private enum KeyStyle {
    static func letterFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.42, green: 0.42, blue: 0.44)
            : Color.white
    }

    static func specialFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.28, green: 0.28, blue: 0.30)
            : Color(red: 0.68, green: 0.70, blue: 0.73)
    }

    static func emphasizedFill(_ scheme: ColorScheme) -> Color {
        // Active shift / caps lock — lighter, like the system's highlighted shift.
        scheme == .dark
            ? Color(red: 0.55, green: 0.55, blue: 0.58)
            : Color.white
    }
}
