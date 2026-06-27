//
//  KeyboardView.swift
//  HexIOSKeyboard
//
//  The keyboard's SwiftUI entry point. It clones Apple's standard QWERTY layout
//  (see `QwertyKeyboardView`) and drops the Hex dictation mic into the bottom-right
//  corner, where Apple's dictation mic normally lives. There is no prediction/
//  autocorrect bar — a third-party extension doesn't get Apple's language model.
//
//  This file owns the shared state machine the controller drives:
//    • `KeyboardPhase`   — the six deliberate states (idle / recording / …).
//    • `KeyboardState`   — observable model derived into `phase`.
//    • `KeyboardActions` — callbacks back into `KeyboardViewController`'s text/IPC
//      wiring (insert / delete / space / return / globe / mic / …).
//

import Observation
import SwiftUI

/// The six keyboard states from design §5. The view derives its appearance from
/// this rather than from scattered booleans, so every state renders deliberately.
enum KeyboardPhase: Equatable {
    case noFullAccess
    case idle
    case recording
    case inserting
    case needsBounce
    case error(String)
}

@MainActor
@Observable
final class KeyboardState {
    var statusText: String = "Tap to dictate"
    var needsNextKeyboard: Bool = false
    var hasFullAccess: Bool = true
    /// A continuous Flow Session is active (dictate in place, no bounce).
    var sessionActive: Bool = false
    /// Currently capturing an utterance (mic is hot in the host app).
    var isCapturing: Bool = false
    /// When the active Flow Session expires (drives the "MM:SS left" countdown).
    var sessionExpiresAt: Date? = nil
    /// Brief confirmation flag after a successful insert (the "inserting" state).
    var justInserted: Bool = false
    /// Set when the host app/model is unreachable; surfaces the error state.
    var errorMessage: String? = nil

    /// Ticks once per second so the countdown pill re-renders; the view binds to
    /// this so SwiftUI recomputes `remaining` without us threading a Timer in.
    var clock: Date = Date()

    /// The single source of truth for which of the six states we're in.
    var phase: KeyboardPhase {
        if !hasFullAccess { return .noFullAccess }
        if let errorMessage { return .error(errorMessage) }
        if isCapturing { return .recording }
        if justInserted { return .inserting }
        // A session that was active but is no longer usable needs a re-bounce.
        if sessionActive, let expiresAt = sessionExpiresAt, clock >= expiresAt {
            return .needsBounce
        }
        return .idle
    }

    /// Seconds remaining in the active session, or nil when there is no live
    /// countdown to show.
    var remaining: TimeInterval? {
        guard sessionActive, let expiresAt = sessionExpiresAt else { return nil }
        let secs = expiresAt.timeIntervalSince(clock)
        return secs > 0 ? secs : nil
    }

    /// "MM:SS" formatting for the session pill.
    var remainingText: String? {
        guard let remaining else { return nil }
        let total = Int(remaining.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Actions the SwiftUI surface hands back to `KeyboardViewController`, which owns
/// all the `textDocumentProxy` / IPC wiring.
struct KeyboardActions {
    var onMic: () -> Void
    var onDelete: () -> Void
    var onNextKeyboard: () -> Void
    var onSpace: () -> Void
    var onReturn: () -> Void
    var onDeleteWord: () -> Void
    var onCaretMove: (Int) -> Void
    var onInsert: (String) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
}

/// The hosted SwiftUI surface. `KeyboardViewController` constructs this with the
/// shared `state` + `actions`; the entry signature `KeyboardView(state:actions:)`
/// is part of the controller contract and must stay stable.
struct KeyboardView: View {
    let state: KeyboardState
    let actions: KeyboardActions

    var body: some View {
        QwertyKeyboardView(state: state, actions: actions)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
