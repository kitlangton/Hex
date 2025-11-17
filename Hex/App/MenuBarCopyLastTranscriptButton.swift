import SwiftUI
import ComposableArchitecture
import Dependencies
import AppKit
import HexCore
import Sauce

struct MenuBarCopyLastTranscriptButton: View {
  @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  @Shared(.hexSettings) var hexSettings: HexSettings
  @Dependency(\.pasteboard) var pasteboard

  var body: some View {
    let lastText = transcriptionHistory.history.first?.text
    let preview: String = {
      guard let text = lastText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "" }
      let snippet = text.prefix(40)
      return "\(snippet)\(text.count > 40 ? "…" : "")"
    }()

    let button = Button(action: {
      if let text = lastText {
        Task { await pasteboard.paste(text) }
      }
    }) {
      HStack(spacing: 6) {
        Text("Paste Last Transcript")
        if !preview.isEmpty {
          Text("(\(preview))")
            .foregroundStyle(.secondary)
        }
      }
    }
    .disabled(lastText == nil)

    if let hotkey = hexSettings.pasteLastTranscriptHotkey,
       let key = hotkey.key,
       let keyEquivalent = toKeyEquivalent(key) {
      button.keyboardShortcut(keyEquivalent, modifiers: toEventModifiers(hotkey.modifiers))
    } else {
      button
    }
  }

  private func toKeyEquivalent(_ key: Key) -> KeyEquivalent? {
    switch key.rawValue {
    case "a": return "a"
    case "b": return "b"
    case "c": return "c"
    case "d": return "d"
    case "e": return "e"
    case "f": return "f"
    case "g": return "g"
    case "h": return "h"
    case "i": return "i"
    case "j": return "j"
    case "k": return "k"
    case "l": return "l"
    case "m": return "m"
    case "n": return "n"
    case "o": return "o"
    case "p": return "p"
    case "q": return "q"
    case "r": return "r"
    case "s": return "s"
    case "t": return "t"
    case "u": return "u"
    case "v": return "v"
    case "w": return "w"
    case "x": return "x"
    case "y": return "y"
    case "z": return "z"
    case "0": return "0"
    case "1": return "1"
    case "2": return "2"
    case "3": return "3"
    case "4": return "4"
    case "5": return "5"
    case "6": return "6"
    case "7": return "7"
    case "8": return "8"
    case "9": return "9"
    case ",": return ","
    case ".": return "."
    case "/": return "/"
    case "\\": return "\\"
    case "'": return "'"
    case ";": return ";"
    case "[": return "["
    case "]": return "]"
    case "-": return "-"
    case "=": return "="
    case "`": return "`"
    default: return nil
    }
  }

  private func toEventModifiers(_ modifiers: Modifiers) -> SwiftUI.EventModifiers {
    var result: SwiftUI.EventModifiers = []
    if modifiers.contains(kind: .command) { result.insert(.command) }
    if modifiers.contains(kind: .option) { result.insert(.option) }
    if modifiers.contains(kind: .shift) { result.insert(.shift) }
    if modifiers.contains(kind: .control) { result.insert(.control) }
    return result
  }
}

#Preview {
  MenuBarCopyLastTranscriptButton()
}
