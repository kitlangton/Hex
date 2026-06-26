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

    public init(isActive: Bool, expiresAt: Date?) {
        self.isActive = isActive
        self.expiresAt = expiresAt
    }

    public static let inactive = DictationSessionState(isActive: false, expiresAt: nil)

    /// Whether the session is currently usable at `now` (active and not expired).
    public func isUsable(at now: Date) -> Bool {
        guard isActive else { return false }
        guard let expiresAt else { return true }
        return now < expiresAt
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
