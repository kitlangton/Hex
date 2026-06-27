//
//  KeyboardIPC.swift
//  HexCore
//
//  Domain types + channel names for keyboard <-> host-app communication.
//
//  Flow (see docs/ios-keyboard-v1-plan.md):
//    keyboard mic tap --(.captureStart/.captureStop Darwin signal)--> host app
//    host app records + transcribes, writes a DictationResult to the mailbox
//    --(.resultReady Darwin signal)--> keyboard reads mailbox, inserts text.
//

import Foundation

/// The App Group shared by the iOS host app and the keyboard extension. Must
/// match the `group.*` identifier configured (identically) on both targets in
/// Xcode (Signing & Capabilities ▸ App Groups).
public enum HexAppGroup {
    public static let identifier = "group.stonefrontier.hex"
}

/// A transcription result handed from the host app to the keyboard.
public struct DictationResult: Codable, Equatable, Sendable, Identifiable {
    /// Stable id so the keyboard can ignore a result it has already inserted.
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Shared "Flow Session" state, written by the host app and read by the keyboard
/// so the keyboard knows whether a re-bounce is needed.
public struct DictationSessionState: Codable, Equatable, Sendable {
    public var isActive: Bool
    /// When the continuous-mic session expires (nil when inactive).
    public var expiresAt: Date?
    /// Last time the host app confirmed the session is genuinely alive. The host
    /// refreshes this on a short interval while the engine runs; if the app dies
    /// or is suspended without ending the session cleanly, it goes stale and the
    /// keyboard stops trusting the (otherwise unexpired) state.
    public var heartbeat: Date

    /// A session whose heartbeat is older than this is considered dead, even if
    /// `expiresAt` is still in the future.
    public static let livenessWindow: TimeInterval = 6

    public init(isActive: Bool, expiresAt: Date?, heartbeat: Date = Date()) {
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.heartbeat = heartbeat
    }

    public static let inactive = DictationSessionState(isActive: false, expiresAt: nil, heartbeat: .distantPast)

    /// Whether the session is currently usable at `now`: active, not expired, and
    /// with a fresh heartbeat (proving the host app is actually running).
    public func isUsable(at now: Date) -> Bool {
        guard isActive else { return false }
        if let expiresAt, now >= expiresAt { return false }
        return now.timeIntervalSince(heartbeat) < Self.livenessWindow
    }
}

/// Cross-process Darwin notification names. Darwin notifications carry no
/// payload, so they only signal "look at the mailbox now".
public enum IPCSignal: String, Sendable, CaseIterable {
    /// keyboard -> host: begin capturing a dictation snippet.
    case captureStart = "co.stonefrontier.hex.ipc.captureStart"
    /// keyboard -> host: stop capturing and transcribe.
    case captureStop = "co.stonefrontier.hex.ipc.captureStop"
    /// host -> keyboard: a new DictationResult is in the mailbox.
    case resultReady = "co.stonefrontier.hex.ipc.resultReady"
    /// host -> keyboard: session state changed (started / ended / expired).
    case sessionChanged = "co.stonefrontier.hex.ipc.sessionChanged"
    /// Live Activity / any surface -> host: end the current session.
    case endSession = "co.stonefrontier.hex.ipc.endSession"
}

/// Standard filenames inside the App Group container.
public enum IPCFile {
    public static let result = "dictation-result.json"
    public static let session = "dictation-session.json"
}

/// Convenience bundle of the two mailboxes for a given App Group container.
public struct KeyboardIPC: Sendable {
    public let resultMailbox: AppGroupMailbox<DictationResult>
    public let sessionMailbox: AppGroupMailbox<DictationSessionState>

    public init?(appGroupIdentifier: String) {
        guard let dir = AppGroupMailbox<DictationResult>.appGroupDirectory(appGroupIdentifier) else {
            return nil
        }
        self.init(directory: dir)
    }

    public init(directory: URL) {
        self.resultMailbox = AppGroupMailbox(directory: directory, filename: IPCFile.result)
        self.sessionMailbox = AppGroupMailbox(directory: directory, filename: IPCFile.session)
    }
}
