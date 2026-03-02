import ComposableArchitecture
import SwiftUI

struct TranscriptionResultView: View {
  let store: StoreOf<IOSTranscriptionFeature>
  @State private var showCopied = false
  @State private var editableText: String = ""

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Transcription")
          .font(.headline)
        Spacer()
        Button { store.send(.clearResult) } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .font(.title3)
        }
      }
      .padding()

      Divider()

      // Content
      if let error = store.transcriptionError {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundStyle(.orange)
          Text(error)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding()
      } else {
        TextEditor(text: $editableText)
          .font(.body)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(minHeight: 100)
          .onAppear {
            editableText = store.lastTranscriptionResult ?? ""
          }
          .onChange(of: store.lastTranscriptionResult) { _, newValue in
            editableText = newValue ?? ""
          }
      }

      Divider()

      // Actions
      HStack(spacing: 16) {
        Button {
          store.send(.copyResult)
          withAnimation { showCopied = true }
          Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showCopied = false }
          }
        } label: {
          Label(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
        }
        .tint(showCopied ? .green : .accentColor)

        if let text = store.lastTranscriptionResult, !text.isEmpty {
          ShareLink(item: text) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
        }

        Spacer()
      }
      .buttonStyle(.bordered)
      .padding()
    }
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .shadow(radius: 20, y: 10)
    .padding()
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
}
