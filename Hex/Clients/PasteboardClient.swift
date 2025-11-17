//
//  PasteboardClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Sauce
import SwiftUI

private let pasteboardLogger = HexLog.pasteboard

@DependencyClient
struct PasteboardClient {
    var paste: @Sendable (String) async -> Void
    var copy: @Sendable (String) async -> Void
}

extension PasteboardClient: DependencyKey {
    static var liveValue: Self {
        let live = PasteboardClientLive()
        return .init(
            paste: { text in
                await live.paste(text: text)
            },
            copy: { text in
                await live.copy(text: text)
            }
        )
    }
}

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

struct PasteboardClientLive {
    @Shared(.hexSettings) var hexSettings: HexSettings

    @MainActor
    func paste(text: String) async {
        if hexSettings.useClipboardPaste {
            await pasteWithClipboard(text)
        } else {
            simulateTypingWithAppleScript(text)
        }
    }
    
    @MainActor
    func copy(text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Function to save the current state of the NSPasteboard
    func savePasteboardState(pasteboard: NSPasteboard) -> [[String: Any]] {
        var savedItems: [[String: Any]] = []
        
        for item in pasteboard.pasteboardItems ?? [] {
            var itemDict: [String: Any] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemDict[type.rawValue] = data
                }
            }
            savedItems.append(itemDict)
        }
        
        return savedItems
    }

    // Function to restore the saved state of the NSPasteboard
    func restorePasteboardState(pasteboard: NSPasteboard, savedItems: [[String: Any]]) {
        pasteboard.clearContents()
        
        for itemDict in savedItems {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                if let data = data as? Data {
                    item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                }
            }
            pasteboard.writeObjects([item])
        }
    }

    /// Pastes current clipboard content to the frontmost application
    static func pasteToFrontmostApp() -> Bool {
        let script = """
        if application "System Events" is not running then
            tell application "System Events" to launch
            delay 0.1
        end if
        tell application "System Events"
            tell process (name of first application process whose frontmost is true)
                tell (menu item "Paste" of menu of menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        log (get properties of it)
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    end if
                end tell
                tell (menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    else
                        return false
                    end if
                end tell
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            if let error = error {
                pasteboardLogger.error("AppleScript paste failed: \(error, privacy: .public)")
                return false
            }
            return result.booleanValue
        }
        return false
    }

    @MainActor
    func pasteWithClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let originalItems = savePasteboardState(pasteboard: pasteboard)
        let targetChangeCount = writeAndTrackChangeCount(pasteboard: pasteboard, text: text)
        _ = await waitForPasteboardCommit(targetChangeCount: targetChangeCount)
        let pasteSucceeded = await tryPaste(text)
        
        // Only restore original pasteboard contents if:
        // 1. Copying to clipboard is disabled AND
        // 2. The paste operation succeeded
        if !hexSettings.copyToClipboard && pasteSucceeded {
            let savedItems = originalItems
            Task { @MainActor in
                // Give slower apps (e.g., Claude, Warp) a short window to read the plain-text entry
                // before we repopulate the clipboard with the user's previous rich data.
                try? await Task.sleep(for: .milliseconds(500))
                pasteboard.clearContents()
                restorePasteboardState(pasteboard: pasteboard, savedItems: savedItems)
            }
        }
        
        // If we failed to paste AND user doesn't want clipboard retention,
        // show a notification that text is available in clipboard
        if !pasteSucceeded && !hexSettings.copyToClipboard {
            // Keep the transcribed text in clipboard regardless of setting
            pasteboardLogger.notice("Paste operation failed; text remains in clipboard as fallback.")
            
            // TODO: Could add a notification here to inform user
            // that text is available in clipboard
        }
    }

    @MainActor
    private func writeAndTrackChangeCount(pasteboard: NSPasteboard, text: String) -> Int {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let after = pasteboard.changeCount
        if after == before {
            // Ensure we always advance by at least one to avoid infinite waits if the system
            // coalesces writes (seen on Sonoma betas with zero-length strings).
            return after + 1
        }
        return after
    }

    @MainActor
    private func waitForPasteboardCommit(
        targetChangeCount: Int,
        timeout: Duration = .milliseconds(150),
        pollInterval: Duration = .milliseconds(5)
    ) async -> Bool {
        guard targetChangeCount > NSPasteboard.general.changeCount else { return true }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if NSPasteboard.general.changeCount >= targetChangeCount {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    // MARK: - Paste Orchestration

    @MainActor
    private func tryPaste(_ text: String) async -> Bool {
        // 1) Fast path: send Cmd+V (no delay)
        if await postCmdV(delayMs: 0) { return true }
        // 2) Menu fallback (quiet failure)
        if PasteboardClientLive.pasteToFrontmostApp() { return true }
        // 3) AX insert fallback
        if (try? Self.insertTextAtCursor(text)) != nil { return true }
        return false
    }

    // MARK: - Helpers

    @MainActor
    private func postCmdV(delayMs: Int) async -> Bool {
        // Optional tiny wait before keystrokes
        try? await wait(milliseconds: delayMs)
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = vKeyCode()
        let cmdKey: CGKeyCode = 55
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    private func vKeyCode() -> CGKeyCode {
        if Thread.isMainThread { return Sauce.shared.keyCode(for: .v) }
        return DispatchQueue.main.sync { Sauce.shared.keyCode(for: .v) }
    }

    @MainActor
    private func wait(milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
    
    func simulateTypingWithAppleScript(_ text: String) {
        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"System Events\" to keystroke \"\(escapedText)\"")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            pasteboardLogger.error("Error executing AppleScript typing fallback: \(error, privacy: .public)")
        }
    }

    enum PasteError: Error {
        case systemWideElementCreationFailed
        case focusedElementNotFound
        case elementDoesNotSupportTextEditing
        case failedToInsertText
    }
    
    static func insertTextAtCursor(_ text: String) throws {
        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()
        
        // Get the focused element
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        
        guard axError == .success, let focusedElementRef = focusedElementRef else {
            throw PasteError.focusedElementNotFound
        }
        
        let focusedElement = focusedElementRef as! AXUIElement
        
        // Verify if the focused element supports text insertion
        var value: CFTypeRef?
        let supportsText = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &value) == .success
        let supportsSelectedText = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &value) == .success
        
        if !supportsText && !supportsSelectedText {
            throw PasteError.elementDoesNotSupportTextEditing
        }
        
        // // Get any selected text
        // var selectedText: String = ""
        // if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &value) == .success,
        //    let selectedValue = value as? String {
        //     selectedText = selectedValue
        // }
        
        // print("selected text: \(selectedText)")
        
        // Insert text at cursor position by replacing selected text (or empty selection)
        let insertResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        
        if insertResult != .success {
            throw PasteError.failedToInsertText
        }
    }
}
