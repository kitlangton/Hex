import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import WhisperKit

private let fileTranscriptionLogger = HexLog.transcription

@Reducer
struct FileTranscriptionFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

    var jobs: [FileTranscriptionJob] = []
    var isDropTargeted = false
    var dropError: String?
    var dropNotice: String?
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case addFiles([URL])
    case importFailed(String)
    case jobStarted(UUID)
    case jobSaving(UUID, String)
    case jobCompleted(UUID, String, Transcript?)
    case jobFailed(UUID, String)
    case copyTranscript(UUID)
    case removeJob(UUID)
    case clearFinished
  }

  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.transcription) var transcription

  static let supportedFormatsDescription = "MP3, M4A/M4B, MP4/MOV/M4V with audio, WAV, FLAC, AAC, AIFF, and CAF"

  private static let supportedFileExtensions: Set<String> = [
    "aac",
    "aif",
    "aiff",
    "caf",
    "flac",
    "m4a",
    "m4b",
    "m4v",
    "mov",
    "mp3",
    "mp4",
    "wav",
  ]

  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce<State, Action> { state, action -> Effect<Action> in
      switch action {
      case .binding:
        return .none

      case let .addFiles(urls):
        let (audioURLs, skippedURLs) = partitionSupportedAudioURLs(urls)
        guard !audioURLs.isEmpty else {
          state.dropError = unsupportedFileMessage(for: skippedURLs)
          state.dropNotice = nil
          return .none
        }

        guard state.modelBootstrapState.isModelReady else {
          state.dropError = "Download a transcription model before importing audio files."
          state.dropNotice = nil
          return .none
        }

        state.dropError = nil
        state.dropNotice = skippedURLs.isEmpty ? nil : skippedUnsupportedFileMessage(for: skippedURLs)
        let jobs = audioURLs.map { FileTranscriptionJob(url: $0) }
        state.jobs.insert(contentsOf: jobs, at: 0)

        let model = state.hexSettings.selectedModel
        let language = state.hexSettings.outputLanguage
        let saveHistory = state.hexSettings.saveTranscriptionHistory

        let effects = jobs.map { job in
          transcribeFileEffect(
            id: job.id,
            url: job.url,
            model: model,
            language: language,
            saveHistory: saveHistory
          )
        }

        return effects.reduce(.none) { mergedEffect, effect in
          .merge(mergedEffect, effect)
        }

      case let .importFailed(message):
        state.dropError = message
        state.dropNotice = nil
        return .none

      case let .jobStarted(id):
        updateJob(id, in: &state) {
          $0.status = .transcribing
          $0.errorMessage = nil
        }
        return .none

      case let .jobSaving(id, text):
        updateJob(id, in: &state) {
          $0.status = .saving
          $0.transcriptText = text
        }
        return .none

      case let .jobCompleted(id, text, transcript):
        updateJob(id, in: &state) {
          $0.status = .completed
          $0.transcriptText = text
          $0.transcriptID = transcript?.id
          $0.errorMessage = nil
        }

        guard let transcript else { return .none }

        let maxEntries = state.hexSettings.maxHistoryEntries
        var removedTranscripts: [Transcript] = []
        state.$transcriptionHistory.withLock { history in
          history.history.insert(transcript, at: 0)
          if let maxEntries, maxEntries > 0 {
            while history.history.count > maxEntries {
              removedTranscripts.append(history.history.removeLast())
            }
          }
        }

        return deleteAudioEffect(for: removedTranscripts)

      case let .jobFailed(id, message):
        updateJob(id, in: &state) {
          $0.status = .failed
          $0.errorMessage = message
        }
        return .none

      case let .copyTranscript(id):
        guard let text = state.jobs.first(where: { $0.id == id })?.transcriptText else {
          return .none
        }
        return .run { [pasteboard] _ in
          await pasteboard.copy(text)
        }

      case let .removeJob(id):
        state.jobs.removeAll { $0.id == id }
        return .none

      case .clearFinished:
        state.jobs.removeAll { $0.status.isFinished }
        return .none
      }
    }
  }

  private func transcribeFileEffect(
    id: UUID,
    url: URL,
    model: String,
    language: String?,
    saveHistory: Bool
  ) -> Effect<Action> {
    .run { [transcription, transcriptPersistence] send in
      await send(.jobStarted(id))

      let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
      defer {
        if didAccessSecurityScope {
          url.stopAccessingSecurityScopedResource()
        }
      }

        do {
          fileTranscriptionLogger.notice("Transcribing imported audio file=\(url.lastPathComponent)")
        let duration = try await Self.audioDuration(for: url)
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil,
          chunkingStrategy: .vad
        )
        let result = try await transcription.transcribe(url, model, decodeOptions) { _ in }
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
          throw FileTranscriptionError.emptyTranscript
        }

        await send(.jobSaving(id, text))

        let transcript: Transcript?
        if saveHistory {
          let temporaryCopy = try Self.copyToTemporaryImportLocation(url)
          do {
            transcript = try await transcriptPersistence.save(
              text,
              temporaryCopy,
              duration,
              nil,
              url.lastPathComponent
            )
          } catch {
            try? FileManager.default.removeItem(at: temporaryCopy)
            throw error
          }
        } else {
          transcript = nil
        }

        await send(.jobCompleted(id, text, transcript))
      } catch {
        fileTranscriptionLogger.error("Imported audio transcription failed: \(error.localizedDescription)")
        await send(.jobFailed(id, error.localizedDescription))
      }
    }
  }

  private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
    .run { [transcriptPersistence] _ in
      for transcript in transcripts {
        try? await transcriptPersistence.deleteAudio(transcript)
      }
    }
  }

  private func updateJob(_ id: UUID, in state: inout State, update: (inout FileTranscriptionJob) -> Void) {
    guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { return }
    update(&state.jobs[index])
  }

  private func partitionSupportedAudioURLs(_ urls: [URL]) -> (supported: [URL], skipped: [URL]) {
    var seen: Set<URL> = []
    var supported: [URL] = []
    var skipped: [URL] = []

    for url in urls {
      let standardized = url.standardizedFileURL
      guard seen.insert(standardized).inserted else {
        continue
      }

      guard Self.isSupportedAudioURL(standardized) else {
        skipped.append(standardized)
        continue
      }

      supported.append(standardized)
    }

    return (supported, skipped)
  }

  private static func isSupportedAudioURL(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    return supportedFileExtensions.contains(url.pathExtension.lowercased())
  }

  private static func audioDuration(for url: URL) async throws -> TimeInterval {
    do {
      let audioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
      let seconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
      guard seconds.isFinite && seconds > 0 else {
        throw FileTranscriptionError.noReadableAudioTrack
      }
      return seconds
    } catch let error as FileTranscriptionError {
      throw error
    } catch {
      if !(await hasAudioTrack(url)) {
        throw FileTranscriptionError.noReadableAudioTrack
      }
      throw FileTranscriptionError.unreadableAudio
    }
  }

  private static func hasAudioTrack(_ url: URL) async -> Bool {
    let asset = AVURLAsset(url: url)
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else {
      return false
    }
    return !tracks.isEmpty
  }

  private func unsupportedFileMessage(for urls: [URL]) -> String {
    guard !urls.isEmpty else {
      return "Drop a supported audio or video file to transcribe. Supported: \(Self.supportedFormatsDescription)."
    }
    return "\(Self.fileList(urls)) not supported. Supported: \(Self.supportedFormatsDescription)."
  }

  private func skippedUnsupportedFileMessage(for urls: [URL]) -> String {
    "Skipped unsupported files: \(Self.fileList(urls)). Supported: \(Self.supportedFormatsDescription)."
  }

  private static func fileList(_ urls: [URL]) -> String {
    let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
    let remainingCount = urls.count - 3
    return remainingCount > 0 ? "\(names), and \(remainingCount) more" : names
  }

  private static func copyToTemporaryImportLocation(_ url: URL) throws -> URL {
    let fm = FileManager.default
    let importDirectory = fm.temporaryDirectory.appendingPathComponent("HexImportedAudio", isDirectory: true)
    try fm.createDirectory(at: importDirectory, withIntermediateDirectories: true)

    let destination = importDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(url.pathExtension.isEmpty ? "audio" : url.pathExtension)

    if fm.fileExists(atPath: destination.path) {
      try fm.removeItem(at: destination)
    }
    try fm.copyItem(at: url, to: destination)
    return destination
  }
}

private enum FileTranscriptionError: LocalizedError {
  case emptyTranscript
  case noReadableAudioTrack
  case unreadableAudio

  var errorDescription: String? {
    switch self {
    case .emptyTranscript:
      return "The selected file did not produce any transcript text."
    case .noReadableAudioTrack:
      return "The selected file does not contain a readable audio track."
    case .unreadableAudio:
      return "Hex could not decode this file's audio. Try MP3, M4A, WAV, or FLAC."
    }
  }
}
