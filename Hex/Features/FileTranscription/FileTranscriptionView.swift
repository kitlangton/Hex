import ComposableArchitecture
import Foundation
import Inject
import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
  private enum DroppedFileURLResult {
    case success(URL)
    case failure(String)
  }

  @ObserveInjection var inject
  @Bindable var store: StoreOf<FileTranscriptionFeature>
  @State private var isImporterPresented = false

  var body: some View {
    VStack(spacing: 16) {
      dropZone

      if let error = store.dropError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let notice = store.dropNotice {
        Label(notice, systemImage: "info.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !store.jobs.isEmpty {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(store.jobs) { job in
              FileTranscriptionJobRow(
                job: job,
                copy: { store.send(.copyTranscript(job.id)) },
                remove: { store.send(.removeJob(job.id)) }
              )
            }
          }
          .padding(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .toolbar {
      ToolbarItemGroup {
        if store.jobs.contains(where: { $0.status.isFinished }) {
          Button {
            store.send(.clearFinished)
          } label: {
            Label("Clear Finished", systemImage: "xmark.circle")
          }
        }

        Button {
          isImporterPresented = true
        } label: {
          Label("Choose Audio", systemImage: "plus")
        }
      }
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.audio, .movie],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case let .success(urls):
        store.send(.addFiles(urls))
      case let .failure(error):
        store.send(.importFailed(error.localizedDescription))
      }
    }
    .enableInjection()
  }

  private var dropZone: some View {
    VStack(spacing: 10) {
      Image(systemName: "waveform.badge.plus")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(store.isDropTargeted ? .blue : .secondary)

      Text("Drop audio files to transcribe")
        .font(.headline)

      Text("Uses the selected transcription model and saves results to History when history is enabled.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      Text("Supported: \(FileTranscriptionFeature.supportedFormatsDescription)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: store.jobs.isEmpty ? 320 : 150)
    .frame(maxHeight: store.jobs.isEmpty ? .infinity : nil)
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(store.isDropTargeted ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          store.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
          style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
        )
    )
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $store.isDropTargeted) { providers in
      loadDroppedFileURLs(from: providers)
      return true
    }
  }

  private func loadDroppedFileURLs(from providers: [NSItemProvider]) {
    Task { @MainActor in
      let result = await Self.droppedFileURLs(from: providers)
      if !result.urls.isEmpty {
        store.send(.addFiles(result.urls))
      } else if let firstError = result.firstError {
        store.send(.importFailed(firstError))
      }
    }
  }

  private static func droppedFileURLs(from providers: [NSItemProvider]) async -> (urls: [URL], firstError: String?) {
    var urls: [URL] = []
    var firstError: String?

    for provider in providers {
      switch await loadDroppedFileURL(from: provider) {
      case let .success(url):
        urls.append(url)
      case let .failure(message):
        if firstError == nil {
          firstError = message
        }
      }
    }

    return (urls, firstError)
  }

  private static func loadDroppedFileURL(from provider: NSItemProvider) async -> DroppedFileURLResult {
    await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
        if let error {
          continuation.resume(returning: .failure(error.localizedDescription))
          return
        }

        guard let url = fileURL(from: item) else {
          continuation.resume(returning: .failure("Could not read the dropped file URL."))
          return
        }

        continuation.resume(returning: .success(url))
      }
    }
  }

  private static func fileURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL {
      return url
    }
    if let url = item as? NSURL {
      return url as URL
    }
    if let data = item as? Data {
      return URL(dataRepresentation: data, relativeTo: nil)
    }
    if let string = item as? String {
      return URL(string: string)
    }
    return nil
  }
}

#Preview {
  FileTranscriptionView(
    store: Store(initialState: FileTranscriptionFeature.State()) {
      FileTranscriptionFeature()
    }
  )
}
