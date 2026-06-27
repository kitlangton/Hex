//
//  FlowSessionActivity.swift
//  HexCore
//
//  Live Activity contract for the Flow Session, shared by the iOS app (which
//  starts/updates/ends the activity) and the widget extension (which renders it).
//  iOS-only — ActivityKit doesn't exist on macOS, so the whole file compiles out
//  there.
//

#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

public struct FlowSessionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// When the session auto-ends; nil for a "never" session (no countdown).
        public var endsAt: Date?
        /// Whether an utterance is being captured right now (mic hot).
        public var isCapturing: Bool

        public init(endsAt: Date?, isCapturing: Bool) {
            self.endsAt = endsAt
            self.isCapturing = isCapturing
        }
    }

    public init() {}
}

/// Interactive "End" button for the Flow Session Live Activity. Runs in the app
/// process and signals the (live) session controller to end the session.
public struct EndFlowSessionIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource { "End Dictation Session" }
    public init() {}

    public func perform() async throws -> some IntentResult {
        DarwinSignal.post(.endSession)
        return .result()
    }
}
#endif
