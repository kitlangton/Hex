//
//  HotKeyProcessor.swift
//  Hex
//
//  Created by Kit Langton on 1/28/25.
//
import Dependencies
import Foundation
import SwiftUI

/// Implements two recording modes: "Hold-to-Record" and "Tap-to-Toggle".
///
/// Hold-to-Record Mode:
/// - Press and hold hotkey => .startRecording
/// - Release hotkey => .stopRecording
/// - Includes 1-second cancel threshold: changing chord within 1s cancels the recording
///
/// Tap-to-Toggle Mode:
/// - First tap of hotkey => .startRecording (immediate, no delay)
/// - Second tap of hotkey => .stopRecording
/// - No timing constraints or threshold detection
///
/// Common behavior:
/// - Pressing ESC => immediate .cancel
/// - "Dirty" logic prevents accidental re-triggers when holding extra modifiers

public struct HotKeyProcessor {
    @Dependency(\.date.now) var now

    public var hotkey: HotKey
    public var recordingMode: RecordingMode

    public private(set) var state: State = .idle
    private var isDirty: Bool = false

    public static let holdToRecordCancelThreshold: TimeInterval = 1.0

    public init(hotkey: HotKey, recordingMode: RecordingMode = .holdToRecord) {
        self.hotkey = hotkey
        self.recordingMode = recordingMode
    }

    public var isMatched: Bool {
        switch state {
        case .idle:
            return false
        case .recording:
            return true
        }
    }

    public mutating func process(keyEvent: KeyEvent) -> Output? {
        // 1) ESC => immediate cancel
        if keyEvent.key == .escape {
            print("ESCAPE HIT IN STATE: \(state)")
        }
        if keyEvent.key == .escape, state != .idle {
            resetToIdle()
            return .cancel
        }

        // 2) If dirty, ignore until full release (nil, [])
        if isDirty {
            if chordIsFullyReleased(keyEvent) {
                isDirty = false
            } else {
                return nil
            }
        }

        // 3) Matching chord => handle as "press"
        if chordMatchesHotkey(keyEvent) {
            return handleMatchingChord()
        } else {
            // Potentially become dirty if chord has extra mods or different key
            if chordIsDirty(keyEvent) {
                isDirty = true
            }
            return handleNonmatchingChord(keyEvent)
        }
    }
}

// MARK: - State & Output

public extension HotKeyProcessor {
    enum State: Equatable {
        case idle
        case recording(mode: RecordingMode, startTime: Date)
    }

    enum Output: Equatable {
        case startRecording
        case stopRecording
        case cancel
    }
}

// MARK: - Core Logic

extension HotKeyProcessor {
    /// Handle when the current chord matches the hotkey
    private mutating func handleMatchingChord() -> Output? {
        switch state {
        case .idle:
            // Start recording in the current mode
            state = .recording(mode: recordingMode, startTime: now)
            return .startRecording

        case let .recording(mode, _):
            // Already recording
            switch mode {
            case .holdToRecord:
                // In hold-to-record mode, continuing to hold the key does nothing
                return nil
            case .tapToToggle:
                // In tap-to-toggle mode, pressing again stops recording
                resetToIdle()
                return .stopRecording
            }
        }
    }

    /// Called when chord != hotkey. We check if user is "releasing" or "typing something else".
    private mutating func handleNonmatchingChord(_ e: KeyEvent) -> Output? {
        switch state {
        case .idle:
            // When idle, non-matching chords are ignored
            return nil

        case let .recording(mode, startTime):
            switch mode {
            case .holdToRecord:
                // In hold-to-record mode, releasing the hotkey stops recording
                if isReleaseForActiveHotkey(e) {
                    resetToIdle()
                    return .stopRecording
                } else {
                    // If within 1s, treat as cancel hold => stop => become dirty
                    let elapsed = now.timeIntervalSince(startTime)
                    if elapsed < Self.holdToRecordCancelThreshold {
                        isDirty = true
                        resetToIdle()
                        return .cancel
                    } else {
                        // After 1s => remain recording
                        return nil
                    }
                }
            case .tapToToggle:
                // In tap-to-toggle mode, ignore non-matching chords
                // User must tap the hotkey again to stop
                return nil
            }
        }
    }

    // MARK: - Helpers

    private func chordMatchesHotkey(_ e: KeyEvent) -> Bool {
        // For hotkeys that include a key, both the key and modifiers must match exactly
        if hotkey.key != nil {
            return e.key == hotkey.key && e.modifiers == hotkey.modifiers
        } else {
            // For modifier-only hotkeys, we need exact match of modifiers
            // If there's no key pressed, modifiers must match exactly
            if e.key == nil {
                return e.modifiers == hotkey.modifiers
            } else {
                // If a key is pressed, it's not a match for a modifier-only hotkey
                return false
            }
        }
    }

    /// "Dirty" if chord includes any extra modifiers or a different key.
    private func chordIsDirty(_ e: KeyEvent) -> Bool {
        let isSubset = e.modifiers.isSubset(of: hotkey.modifiers)
        let isWrongKey = (hotkey.key != nil && e.key != nil && e.key != hotkey.key)
        return !isSubset || isWrongKey
    }

    private func chordIsFullyReleased(_ e: KeyEvent) -> Bool {
        e.key == nil && e.modifiers.isEmpty
    }

    /// For a key+modifier hotkey, "release" => same modifiers, no key.
    /// For a modifier-only hotkey, "release" => no modifiers at all.
    private func isReleaseForActiveHotkey(_ e: KeyEvent) -> Bool {
        if hotkey.key != nil {
            // For key+modifier hotkeys, we need to check:
            // 1. Key is released (key == nil)
            // 2. Modifiers match exactly what was in the hotkey
            return e.key == nil && e.modifiers == hotkey.modifiers
        } else {
            // For modifier-only hotkeys, we check:
            // 1. Key is nil
            // 2. Required hotkey modifiers are no longer pressed
            // This detects when user has released the specific modifiers in the hotkey
            return e.key == nil && !hotkey.modifiers.isSubset(of: e.modifiers)
        }
    }

    /// Clear state but preserve `isDirty` if the caller has just set it.
    private mutating func resetToIdle() {
        state = .idle
    }
}
