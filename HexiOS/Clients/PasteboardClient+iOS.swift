import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import UIKit

private let pasteboardLogger = HexLog.pasteboard

@DependencyClient
struct PasteboardClient {
  var paste: @Sendable (String) async -> Void
  var copy: @Sendable (String) async -> Void
  var sendKeyboardCommand: @Sendable (KeyboardCommand) async -> Void
}

extension PasteboardClient: DependencyKey {
  static var liveValue: Self {
    .init(
      paste: { text in
        await MainActor.run {
          UIPasteboard.general.string = text
        }
        pasteboardLogger.debug("Copied text to pasteboard (paste is copy on iOS)")
      },
      copy: { text in
        await MainActor.run {
          UIPasteboard.general.string = text
        }
        pasteboardLogger.debug("Copied text to pasteboard")
      },
      sendKeyboardCommand: { _ in
        // No-op on iOS — keyboard command simulation is not possible
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
