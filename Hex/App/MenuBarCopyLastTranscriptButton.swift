import SwiftUI
import ComposableArchitecture
import Dependencies
import AppKit

struct MenuBarCopyLastTranscriptButton: View {
  @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  @Dependency(\.pasteboard) var pasteboard

  var body: some View {
    let lastText = transcriptionHistory.history.last?.text
    let preview: String = {
      guard let text = lastText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "" }
      let snippet = text.prefix(40)
      return "\(snippet)\(text.count > 40 ? "…" : "")"
    }()

    Button(action: {
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
  }
}

#Preview {
  MenuBarCopyLastTranscriptButton()
}
