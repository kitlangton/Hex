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
}

extension PasteboardClient: DependencyKey {
    static var liveValue: Self {
        let live = PasteboardClientLive()
        return .init { text in
            await live.paste(text: text)
        }
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
        tell application "System Events"
            tell process (name of first application process whose frontmost is true)
                -- Open the "Edit" menu
                click menu item "Paste" of menu bar item "Edit" of menu bar 1
                
                -- Check if the "Paste" menu item exits
                if exists menu item "Paste" of menu item "Paste" of menu 1 of menu bar item "Edit" of menu bar 1 then
                    click menu item "Paste" of menu item "Paste" of menu 1 of menu bar item "Edit" of menu bar 1
                else
                    -- If not, click the "Paste" menu item directly
                    click menu item "Paste" of menu 1 of menu bar item "Edit" of menu bar 1
                end if
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("Error executing paste: \(error)")
                return false
            }
            return true
        }
        return false
    }

    func pasteWithClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let originalItems = savePasteboardState(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)

        if !PasteboardClientLive.pasteToFrontmostApp() {
            print("Failed to paste to frontmost app, falling back to simulated keypresses")
            let vKeyCode = Sauce.shared.keyCode(for: .v)
            let cmdKeyCode: CGKeyCode = 55 // Command key

            // Create cmd down event
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true)

            // Create v down event
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
            vDown?.flags = .maskCommand

            // Create v up event
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
            vUp?.flags = .maskCommand

            // Create cmd up event
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)

            // Post the events
            cmdDown?.post(tap: .cghidEventTap)
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
            cmdUp?.post(tap: .cghidEventTap)
        }

        // Restore original pasteboard contents
        try? await Task.sleep(for: .seconds(0.1))
        pasteboard.clearContents()
        restorePasteboardState(pasteboard: pasteboard, savedItems: originalItems)
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
