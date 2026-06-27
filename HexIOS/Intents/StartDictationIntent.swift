//
//  StartDictationIntent.swift
//  HexIOS
//
//  Hands-free entry (P3-2): start a Flow Session from Shortcuts / the Action
//  Button / Siri. Like the keyboard bounce, starting the mic session requires
//  the app to be foreground, so the intent opens the app (`openAppWhenRun`) and
//  records a pending request; the app starts the session when it becomes active
//  (see HexIOSApp), which avoids a cold-launch race.
//

import AppIntents
import Foundation
import HexCore

/// Shared key used to hand a "start a session" request from the intent (which
/// can't reach the app's model directly) to the app on next activation.
enum PendingAppAction {
    static let key = "hex.pendingStartSession"

    static func requestStartSession() {
        UserDefaults(suiteName: HexAppGroup.identifier)?.set(true, forKey: key)
    }

    /// Returns true (and clears the flag) if a session start was requested.
    static func consumeStartSession() -> Bool {
        let defaults = UserDefaults(suiteName: HexAppGroup.identifier)
        guard defaults?.bool(forKey: key) == true else { return false }
        defaults?.set(false, forKey: key)
        return true
    }
}

struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription("Start a hands-free Hex dictation session.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingAppAction.requestStartSession()
        return .result()
    }
}

struct HexAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation with \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}
