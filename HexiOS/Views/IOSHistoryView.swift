import ComposableArchitecture
import HexCore
import SwiftUI

struct IOSHistoryView: View {
  let store: StoreOf<HistoryFeature>
  @State private var showingDeleteConfirmation = false
  @Shared(.hexSettings) var hexSettings: HexSettings

  var body: some View {
    NavigationStack {
      Group {
        if !hexSettings.saveTranscriptionHistory {
          ContentUnavailableView {
            Label("History Disabled", systemImage: "clock.arrow.circlepath")
          } description: {
            Text("Transcription history is currently disabled. Enable it in Settings.")
          }
        } else if store.transcriptionHistory.history.isEmpty {
          ContentUnavailableView {
            Label("No Transcriptions", systemImage: "text.bubble")
          } description: {
            Text("Your transcription history will appear here.")
          }
        } else {
          List {
            ForEach(store.transcriptionHistory.history) { transcript in
              IOSTranscriptRow(
                transcript: transcript,
                isPlaying: store.playingTranscriptID == transcript.id,
                onPlay: { store.send(.playTranscript(transcript.id)) },
                onCopy: { store.send(.copyToClipboard(transcript.text)) }
              )
              .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                  store.send(.deleteTranscript(transcript.id))
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("History")
      .toolbar {
        if !store.transcriptionHistory.history.isEmpty {
          Button(role: .destructive) {
            showingDeleteConfirmation = true
          } label: {
            Label("Delete All", systemImage: "trash")
          }
        }
      }
      .alert("Delete All Transcripts", isPresented: $showingDeleteConfirmation) {
        Button("Delete All", role: .destructive) {
          store.send(.confirmDeleteAll)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Are you sure you want to delete all transcripts? This action cannot be undone.")
      }
    }
  }
}

struct IOSTranscriptRow: View {
  let transcript: Transcript
  let isPlaying: Bool
  let onPlay: () -> Void
  let onCopy: () -> Void
  @State private var showCopied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(transcript.text)
        .font(.body)
        .lineLimit(4)

      HStack(spacing: 6) {
        Image(systemName: "clock")
        Text(transcript.timestamp.relativeFormatted())
        Text("·")
        Text(transcript.timestamp.formatted(date: .omitted, time: .shortened))
        Text("·")
        Text(String(format: "%.1fs", transcript.duration))
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        Button(action: {
          onCopy()
          withAnimation { showCopied = true }
          Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showCopied = false }
          }
        }) {
          Label(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(showCopied ? .green : .accentColor)

        Button(action: onPlay) {
          Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isPlaying ? .blue : .secondary)
      }
    }
    .padding(.vertical, 4)
  }
}
