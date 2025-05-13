//
//  PasteboardClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Sauce
import SwiftUI

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

    // Stores the previous pasteboard owner change count
    private static var savedChangeCount: Int = 0
    // Stores the previous pasteboard contents name for tracking
    private static var savedPasteboardName: String?
    
    // More efficient approach that uses NSPasteboard's built-in functionality
    // Instead of copying all the data, we'll track the pasteboard state and create 
    // a temporary pasteboard to hold the original data
    func savePasteboardState(pasteboard: NSPasteboard) -> NSPasteboard? {
        // If pasteboard is empty, nothing to save
        if pasteboard.pasteboardItems?.isEmpty ?? true {
            return nil
        }
        
        // Generate a unique name for the backup pasteboard
        let tempName = "com.kitlangton.Hex.backup.\(UUID().uuidString)"
        let backupPasteboard = NSPasteboard(name: .init(tempName))
        
        // Clear the backup pasteboard and write all contents from original
        backupPasteboard.clearContents()
        
        // Copy all items to the backup pasteboard
        // This is more efficient than manually copying each data item
        if let items = pasteboard.pasteboardItems {
            backupPasteboard.writeObjects(items)
        }
        
        // Save the current change count and name for later reference
        PasteboardClientLive.savedChangeCount = pasteboard.changeCount
        PasteboardClientLive.savedPasteboardName = tempName
        
        return backupPasteboard
    }

    // Restore the pasteboard state from a backup pasteboard
    func restorePasteboardFromBackup(mainPasteboard: NSPasteboard, backupPasteboard: NSPasteboard?) {
        // If no backup pasteboard, nothing to restore
        guard let backupPasteboard = backupPasteboard else { return }
        
        // Clear the main pasteboard
        mainPasteboard.clearContents()
        
        // Copy all items from backup to main pasteboard
        if let items = backupPasteboard.pasteboardItems {
            mainPasteboard.writeObjects(items)
        }
        
        // Release the temporary pasteboard by clearing it
        backupPasteboard.clearContents()
    }
    
    // Legacy method to maintain compatibility - will be removed in future
    func restorePasteboardState(pasteboard: NSPasteboard, savedItems: [[String: Any]]) {
        // This is kept for compatibility but shouldn't be used anymore
        print("Warning: Using deprecated pasteboard restoration method")
    }

    /// Pastes current clipboard content to the frontmost application
    static func pasteToFrontmostApp() -> Bool {
        let script = """
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
                print("Error executing paste: \(error)")
                return false
            }
            return result.booleanValue
        }
        return false
    }

    func pasteWithClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        
        // Save the original pasteboard only if we need to restore it
        let backupPasteboard = hexSettings.copyToClipboard ? nil : savePasteboardState(pasteboard: pasteboard)
        
        // Set our text in the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        
        // First try the AppleScript approach - it's more reliable in most apps
        var pasteSucceeded = PasteboardClientLive.pasteToFrontmostApp()
        
        // If menu-based paste failed, try simulated keypresses
        if !pasteSucceeded {
            print("Failed to paste to frontmost app, falling back to simulated keypresses")
            
            // Add a small delay to allow system to process
            try? await Task.sleep(for: .milliseconds(100))

            // Use a thread-safe approach to prevent _dispatch_assert_queue_fail
            let vKeyCode: CGKeyCode
            if Thread.isMainThread {
                vKeyCode = Sauce.shared.keyCode(for: .v)
            } else {
                vKeyCode = DispatchQueue.main.sync { Sauce.shared.keyCode(for: .v) }
            }
            let cmdKeyCode: CGKeyCode = 55 // Command key

            // Create and post key events with small delays between
            autoreleasepool {
                // Command down
                let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true)
                cmdDown?.post(tap: .cghidEventTap)
                
                // V down with command flag
                let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
                vDown?.flags = .maskCommand
                vDown?.post(tap: .cghidEventTap)
                
                // V up with command flag
                let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
                vUp?.flags = .maskCommand
                vUp?.post(tap: .cghidEventTap)
                
                // Command up
                let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)
                cmdUp?.post(tap: .cghidEventTap)
            }
            
            // Assume keypress-based paste succeeded - text will remain in clipboard as fallback
            pasteSucceeded = true
        }
        
        // Only restore original pasteboard contents if:
        // 1. User doesn't want to keep text in clipboard AND
        // 2. The paste operation succeeded AND
        // 3. We have a backup pasteboard
        if !hexSettings.copyToClipboard && pasteSucceeded && backupPasteboard != nil {
            // Give paste operation time to complete
            try? await Task.sleep(for: .milliseconds(200))
            
            // Restore the original pasteboard state
            autoreleasepool {
                restorePasteboardFromBackup(mainPasteboard: pasteboard, backupPasteboard: backupPasteboard)
            }
        }
        
        // If we failed to paste AND user doesn't want clipboard retention,
        // log the issue but leave text in clipboard as fallback
        if !pasteSucceeded && !hexSettings.copyToClipboard {
            print("Paste operation failed. Text remains in clipboard as fallback.")
        }
    }
    
    func simulateTypingWithAppleScript(_ text: String) {
        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"System Events\" to keystroke \"\(escapedText)\"")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            print("Error executing AppleScript: \(error)")
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
