import AVFoundation
import ComposableArchitecture
import Dependencies
import HexCore
import UIKit
import WhisperKit

private let transcriptionLogger = HexLog.transcription

@Reducer
struct IOSTranscriptionFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

    var isRecording = false
    var isTranscribing = false
    var isPrewarming = false
    var meter = Meter(averagePower: 0, peakPower: 0)
    var lastTranscriptionResult: String?
    var transcriptionError: String?
    var recordingStartTime: Date?
  }

  enum Action {
    case task
    case startRecording
    case stopRecording
    case cancel
    case audioLevelUpdated(Meter)
    case transcriptionResult(String, URL)
    case transcriptionFailed(String)
    case copyResult
    case shareResult
    case clearResult
    case prewarmCompleted
  }

  @Dependency(\.recording) var recording
  @Dependency(\.transcription) var transcription
  @Dependency(\.soundEffects) var soundEffects
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date) var date
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.pasteboard) var pasteboard

  enum CancelID {
    case metering
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        state.isPrewarming = true
        return .run { send in
          await soundEffects.preloadSounds()
          await recording.warmUpRecorder()
          await send(.prewarmCompleted)
        }

      case .prewarmCompleted:
        state.isPrewarming = false
        return .none

      case .startRecording:
        guard !state.isRecording, !state.isTranscribing else { return .none }
        state.isRecording = true
        state.lastTranscriptionResult = nil
        state.transcriptionError = nil
        state.recordingStartTime = date.now
        soundEffects.play(.startRecording)

        return .merge(
          .run { _ in
            await recording.startRecording()
          },
          .run { send in
            let haptic = await UIImpactFeedbackGenerator(style: .medium)
            await haptic.impactOccurred()
            for await level in await recording.observeAudioLevel() {
              await send(.audioLevelUpdated(level))
            }
          }
          .cancellable(id: CancelID.metering)
        )

      case .stopRecording:
        guard state.isRecording else { return .none }
        state.isRecording = false
        state.isTranscribing = true
        soundEffects.play(.stopRecording)

        let model = state.hexSettings.selectedModel
        let language = state.hexSettings.outputLanguage
        let wordRemappings = state.hexSettings.wordRemappings
        let wordRemovals = state.hexSettings.wordRemovals
        let wordRemovalsEnabled = state.hexSettings.wordRemovalsEnabled
        let saveHistory = state.hexSettings.saveTranscriptionHistory
        let startTime = state.recordingStartTime
        let transcriptionHistory = state.$transcriptionHistory
        let maxHistoryEntries = state.hexSettings.maxHistoryEntries

        return .merge(
          .cancel(id: CancelID.metering),
          .run { send in
            let haptic = await UIImpactFeedbackGenerator(style: .light)
            await haptic.impactOccurred()

            let audioURL = await recording.stopRecording()
            let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0

            do {
              var options = DecodingOptions()
              if let language, !language.isEmpty {
                options.language = language
              }
              var text = try await transcription.transcribe(audioURL, model, options) { _ in }

              // Apply word removals
              if wordRemovalsEnabled {
                text = WordRemovalApplier.apply(text, removals: wordRemovals)
              }

              // Apply word remappings
              text = WordRemappingApplier.apply(text, remappings: wordRemappings)

              text = text.trimmingCharacters(in: .whitespacesAndNewlines)

              // Save to history
              if saveHistory {
                if let transcript = try? await transcriptPersistence.save(text, audioURL, duration, nil, nil) {
                  transcriptionHistory.withLock { history in
                    history.history.insert(transcript, at: 0)

                    if let maxEntries = maxHistoryEntries, maxEntries > 0 {
                      while history.history.count > maxEntries {
                        if let removed = history.history.popLast() {
                          Task {
                            try? await transcriptPersistence.deleteAudio(removed)
                          }
                        }
                      }
                    }
                  }
                }
              } else {
                try? FileManager.default.removeItem(at: audioURL)
              }

              await send(.transcriptionResult(text, audioURL))
            } catch {
              transcriptionLogger.error("Transcription failed: \(error.localizedDescription)")
              await send(.transcriptionFailed(error.localizedDescription))
            }
          }
        )

      case .cancel:
        guard state.isRecording else { return .none }
        state.isRecording = false
        soundEffects.play(.cancel)
        return .merge(
          .cancel(id: CancelID.metering),
          .run { _ in
            _ = await recording.stopRecording()
            let haptic = await UINotificationFeedbackGenerator()
            await haptic.notificationOccurred(.warning)
          }
        )

      case .audioLevelUpdated(let meter):
        state.meter = meter
        return .none

      case .transcriptionResult(let text, _):
        state.isTranscribing = false
        state.lastTranscriptionResult = text
        soundEffects.play(.pasteTranscript)
        return .none

      case .transcriptionFailed(let error):
        state.isTranscribing = false
        state.transcriptionError = error
        return .none

      case .copyResult:
        guard let text = state.lastTranscriptionResult else { return .none }
        return .run { _ in
          await pasteboard.copy(text)
          let haptic = await UINotificationFeedbackGenerator()
          await haptic.notificationOccurred(.success)
        }

      case .shareResult:
        return .none

      case .clearResult:
        state.lastTranscriptionResult = nil
        state.transcriptionError = nil
        return .none
      }
    }
  }
}

