import AVFoundation
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

private let historyLogger = HexLog.history

// MARK: - Date Extensions

extension Date {
  func relativeFormatted() -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(self) {
      return "Today"
    } else if calendar.isDateInYesterday(self) {
      return "Yesterday"
    } else if let daysAgo = calendar.dateComponents([.day], from: self, to: now).day, daysAgo < 7 {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: self)
    } else {
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      formatter.timeStyle = .none
      return formatter.string(from: self)
    }
  }
}

// MARK: - Models

extension SharedReaderKey
  where Self == FileStorageKey<TranscriptionHistory>.Default
{
  static var transcriptionHistory: Self {
    Self[
      .fileStorage(.transcriptionHistoryURL),
      default: .init()
    ]
  }
}

extension URL {
  static var transcriptionHistoryURL: URL {
    get {
      let newURL = (try? URL.hexApplicationSupport.appending(component: "transcription_history.json"))
        ?? URL.documentsDirectory.appending(component: "transcription_history.json")
      return newURL
    }
  }
}

class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
  private var player: AVAudioPlayer?
  var onPlaybackFinished: (() -> Void)?

  func play(url: URL) throws -> AVAudioPlayer {
    let player = try AVAudioPlayer(contentsOf: url)
    player.delegate = self
    player.play()
    self.player = player
    return player
  }

  func stop() {
    player?.stop()
    player = nil
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    self.player = nil
    Task { @MainActor in
      onPlaybackFinished?()
    }
  }
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    var playingTranscriptID: UUID?
    var audioPlayer: AVAudioPlayer?
    var audioPlayerController: AudioPlayerController?

    mutating func stopAudioPlayback() {
      audioPlayerController?.stop()
      audioPlayer = nil
      audioPlayerController = nil
      playingTranscriptID = nil
    }
  }

  enum Action {
    case playTranscript(UUID)
    case stopPlayback
    case copyToClipboard(String)
    case deleteTranscript(UUID)
    case deleteAllTranscripts
    case confirmDeleteAll
    case playbackFinished
    case navigateToSettings
  }

  @Dependency(\.pasteboard) var pasteboard

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .playTranscript(id):
        if state.playingTranscriptID == id {
          state.stopAudioPlayback()
          return .none
        }

        state.stopAudioPlayback()

        guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
          return .none
        }

        do {
          let controller = AudioPlayerController()
          let player = try controller.play(url: transcript.audioPath)
          state.audioPlayer = player
          state.audioPlayerController = controller
          state.playingTranscriptID = id

          return .run { send in
            await withCheckedContinuation { continuation in
              controller.onPlaybackFinished = {
                continuation.resume()
                Task { @MainActor in
                  send(.playbackFinished)
                }
              }
            }
          }
        } catch {
          historyLogger.error("Failed to play audio: \(error.localizedDescription)")
          return .none
        }

      case .stopPlayback, .playbackFinished:
        state.stopAudioPlayback()
        return .none

      case let .copyToClipboard(text):
        return .run { [pasteboard] _ in
          await pasteboard.copy(text)
        }

      case let .deleteTranscript(id):
        guard let index = state.transcriptionHistory.history.firstIndex(where: { $0.id == id }) else {
          return .none
        }
        let transcript = state.transcriptionHistory.history[index]
        if state.playingTranscriptID == id {
          state.stopAudioPlayback()
        }
        _ = state.$transcriptionHistory.withLock { history in
          history.history.remove(at: index)
        }
        return .run { _ in
          try? FileManager.default.removeItem(at: transcript.audioPath)
        }

      case .deleteAllTranscripts:
        return .send(.confirmDeleteAll)

      case .confirmDeleteAll:
        let transcripts = state.transcriptionHistory.history
        state.stopAudioPlayback()
        state.$transcriptionHistory.withLock { history in
          history.history.removeAll()
        }
        return .run { _ in
          for transcript in transcripts {
            try? FileManager.default.removeItem(at: transcript.audioPath)
          }
        }

      case .navigateToSettings:
        return .none
      }
    }
  }
}
