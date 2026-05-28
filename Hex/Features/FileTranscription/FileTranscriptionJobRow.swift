import SwiftUI

struct FileTranscriptionJobRow: View {
  let job: FileTranscriptionJob
  let copy: () -> Void
  let remove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content

      Divider()

      HStack {
        HStack(spacing: 6) {
          Image(systemName: job.status.systemImage)
            .foregroundStyle(job.status.tint)
          Text(job.fileName)
            .lineLimit(1)
          Text("•")
          Text(job.status.title)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)

        Spacer()

        HStack(spacing: 10) {
          if job.status == .completed {
            Button {
              copy()
              showCopyAnimation()
            } label: {
              HStack(spacing: 4) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc.fill")
                if showCopied {
                  Text("Copied").font(.caption)
                }
              }
            }
            .buttonStyle(.plain)
            .foregroundStyle(showCopied ? .green : .secondary)
            .help("Copy to clipboard")
          }

          Button(action: remove) {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Remove from this list")
        }
        .font(.subheadline)
      }
      .frame(height: 20)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(.windowBackgroundColor).opacity(0.5))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    )
    .onDisappear {
      copyTask?.cancel()
    }
  }

  @ViewBuilder
  private var content: some View {
    VStack(alignment: .leading, spacing: 8) {
      if job.status == .transcribing || job.status == .saving {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(job.status == .saving ? "Saving transcript..." : "Transcribing audio...")
            .foregroundStyle(.secondary)
        }
        .font(.callout)
      }

      if let error = job.errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let transcript = job.transcriptText {
        Text(transcript)
          .font(.body)
          .foregroundStyle(.primary)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, 40)
    .padding(12)
  }

  @State private var showCopied = false
  @State private var copyTask: Task<Void, Error>?

  private func showCopyAnimation() {
    copyTask?.cancel()

    copyTask = Task {
      withAnimation {
        showCopied = true
      }

      try await Task.sleep(for: .seconds(1.5))

      withAnimation {
        showCopied = false
      }
    }
  }
}
