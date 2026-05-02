import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import Inject
import SwiftUI
import WhisperKit

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
			formatter.dateFormat = "EEEE" // Day of week
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

// MARK: - Storage Migration

extension URL {
	static var transcriptionHistoryURL: URL {
		get {
			URL.hexMigratedFileURL(named: "transcription_history.json")
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

	// AVAudioPlayerDelegate method
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
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
		var playingTranscriptID: UUID?
		var audioPlayer: AVAudioPlayer?
		var audioPlayerController: AudioPlayerController?
		var retryingTranscriptIDs: Set<UUID> = []
		var lastRetryError: [UUID: String] = [:]
		var copiedTranscriptIDs: Set<UUID> = []

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
		case copyTranscript(UUID)
		case copiedFlashEnded(UUID)
		case deleteTranscript(UUID)
		case deleteAllTranscripts
		case confirmDeleteAll
		case playbackFinished
		case navigateToSettings
		case retryTranscript(UUID)
		case retrySucceeded(UUID, String)
		case retryFailed(UUID, String)
	}

	enum CancelID: Hashable {
		case retry(UUID)
		case copyFlash(UUID)
	}

	@Dependency(\.pasteboard) var pasteboard
	@Dependency(\.transcriptPersistence) var transcriptPersistence
	@Dependency(\.transcription) var transcription

	private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
		.run { [transcriptPersistence] _ in
			for transcript in transcripts {
				try? await transcriptPersistence.deleteAudio(transcript)
			}
		}
	}

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .playTranscript(id):
				if state.playingTranscriptID == id {
					// Stop playback if tapping the same transcript
					state.stopAudioPlayback()
					return .none
				}

				// Stop any existing playback
				state.stopAudioPlayback()

				// Find the transcript and play its audio
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
						// Using non-throwing continuation since we don't need to throw errors
						await withCheckedContinuation { continuation in
							controller.onPlaybackFinished = {
								continuation.resume()

								// Use Task to switch to MainActor for sending the action
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

			case let .copyTranscript(id):
				guard let row = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}
				state.copiedTranscriptIDs.insert(id)
				let text = row.text
				return .merge(
					.run { [pasteboard] _ in await pasteboard.copy(text) },
					.run { send in
						try? await Task.sleep(for: .seconds(1.5))
						await send(.copiedFlashEnded(id))
					}
					.cancellable(id: CancelID.copyFlash(id), cancelInFlight: true)
				)

			case let .copiedFlashEnded(id):
				state.copiedTranscriptIDs.remove(id)
				return .none

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

				// Clear retry- and copy-flash-related state and abort any in-flight effects for this id.
				state.retryingTranscriptIDs.remove(id)
				state.lastRetryError[id] = nil
				state.copiedTranscriptIDs.remove(id)

				return .merge(
					deleteAudioEffect(for: [transcript]),
					.cancel(id: CancelID.retry(id)),
					.cancel(id: CancelID.copyFlash(id))
				)

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				let transcripts = state.transcriptionHistory.history
				let activeRetryIDs = state.retryingTranscriptIDs
				let activeCopyIDs = state.copiedTranscriptIDs
				state.stopAudioPlayback()

				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}
				state.retryingTranscriptIDs.removeAll()
				state.lastRetryError.removeAll()
				state.copiedTranscriptIDs.removeAll()

				return .merge(
					[deleteAudioEffect(for: transcripts)] +
						activeRetryIDs.map { .cancel(id: CancelID.retry($0)) } +
						activeCopyIDs.map { .cancel(id: CancelID.copyFlash($0)) }
				)

			case .navigateToSettings:
				// This will be handled by the parent reducer
				return .none

			case let .retryTranscript(id):
				// Duplicate-retry guard: silently ignore if already retrying.
				guard !state.retryingTranscriptIDs.contains(id) else {
					return .none
				}
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}
				guard FileManager.default.fileExists(atPath: transcript.audioPath.path) else {
					state.lastRetryError[id] = "Audio file no longer available"
					return .none
				}

				state.retryingTranscriptIDs.insert(id)
				state.lastRetryError[id] = nil

				let audioURL = transcript.audioPath
				let model = state.hexSettings.selectedModel
				let language = state.hexSettings.outputLanguage
				let settingsSnapshot = state.hexSettings

				return .run { [transcription] send in
					// Authoritative model-readiness check (in-state value can be stale if
					// model files were deleted externally).
					let isReady = await transcription.isModelDownloaded(model)
					guard isReady else {
						await send(.retryFailed(id, "Selected model not available — open Settings to download"))
						return
					}

					let options = DecodingOptions(
						language: language,
						detectLanguage: language == nil,
						chunkingStrategy: .vad
					)
					do {
						let raw = try await transcription.transcribe(audioURL, model, options) { _ in }
						let processed = TranscriptTextProcessor.process(
							raw,
							settings: settingsSnapshot,
							bypassFilters: false
						)
						await send(.retrySucceeded(id, processed))
					} catch {
						await send(.retryFailed(id, error.localizedDescription))
					}
				}
				.cancellable(id: CancelID.retry(id))

			case let .retrySucceeded(id, text):
				// Row-still-exists guard: drop late-arriving results for deleted rows.
				guard state.transcriptionHistory.history.contains(where: { $0.id == id }) else {
					return .none
				}

				// Empty post-processed text: surface as inline error, leave row in prior state.
				guard !text.isEmpty else {
					state.retryingTranscriptIDs.remove(id)
					state.lastRetryError[id] = "Transcript empty after word filters"
					return .none
				}

				state.$transcriptionHistory.withLock { current in
					if let idx = current.history.firstIndex(where: { $0.id == id }) {
						current.history[idx].text = text
						current.history[idx].status = .completed
					}
				}
				state.retryingTranscriptIDs.remove(id)
				state.lastRetryError[id] = nil

				// Auto-copy + flash: the row morphs to .completed and the Copy button slot
				// becomes visible; .copyTranscript puts text on the clipboard and lights up
				// the existing "Copied" flash for 1.5s. Single click → fully done.
				return .send(.copyTranscript(id))

			case let .retryFailed(id, message):
				// Row-still-exists guard.
				guard state.transcriptionHistory.history.contains(where: { $0.id == id }) else {
					return .none
				}
				state.retryingTranscriptIDs.remove(id)
				state.lastRetryError[id] = message
				return .none
			}
		}
	}
}

// MARK: - Status Pill

private struct TranscriptStatusPill: View {
	let status: TranscriptStatus

	var body: some View {
		HStack(spacing: 4) {
			Image(systemName: iconName)
			Text(label)
		}
		.font(.subheadline)
		.foregroundStyle(.secondary)
	}

	private var iconName: String {
		switch status {
		case .completed: return ""
		case .cancelled: return "xmark.circle"
		case .failed: return "exclamationmark.triangle"
		}
	}

	private var label: String {
		switch status {
		case .completed: return ""
		case .cancelled: return "Cancelled"
		case .failed: return "Failed"
		}
	}
}

// MARK: - Retry Button

private struct RetryButton: View {
	let isRetrying: Bool
	let errorMessage: String?
	let onRetry: () -> Void

	var body: some View {
		Button(action: onRetry) {
			content
		}
		.buttonStyle(.plain)
		.disabled(isRetrying)
		.help(helpText)
	}

	@ViewBuilder
	private var content: some View {
		if isRetrying {
			ProgressView()
				.controlSize(.small)
				.tint(.blue)
		} else if errorMessage != nil {
			Image(systemName: "exclamationmark")
				.foregroundStyle(.orange)
		} else {
			Image(systemName: "arrow.clockwise")
				.foregroundStyle(.secondary)
		}
	}

	private var helpText: String {
		if let errorMessage { return errorMessage }
		if isRetrying { return "Retrying transcription…" }
		return "Retry transcription"
	}
}

struct TranscriptView: View {
	let transcript: Transcript
	let isPlaying: Bool
	let isRetrying: Bool
	let isCopied: Bool
	let retryError: String?
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onDelete: () -> Void
	let onRetry: () -> Void

	private var status: TranscriptStatus { transcript.resolvedStatus }
	private var isIncomplete: Bool { status != .completed }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Group {
				if isIncomplete {
					Text(placeholderText)
						.font(.body)
						.foregroundStyle(.secondary)
						.italic()
				} else {
					Text(transcript.text)
						.font(.body)
				}
			}
			.lineLimit(nil)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.trailing, 40) // Space for buttons
			.padding(12)

			Divider()

			HStack {
				HStack(spacing: 6) {
					// App icon and name
					if let bundleID = transcript.sourceAppBundleID,
					   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
						Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
							.resizable()
							.frame(width: 14, height: 14)
						if let appName = transcript.sourceAppName {
							Text(appName)
						}
						Text("•")
					}

					if isIncomplete {
						TranscriptStatusPill(status: status)
						Text("•")
					}

					Image(systemName: "clock")
					Text(transcript.timestamp.relativeFormatted())
					Text("•")
					Text(transcript.timestamp.formatted(date: .omitted, time: .shortened))
					Text("•")
					Text(String(format: "%.1fs", transcript.duration))
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)

				Spacer()

				HStack(spacing: 10) {
					if isIncomplete {
						RetryButton(
							isRetrying: isRetrying,
							errorMessage: retryError,
							onRetry: onRetry
						)
					} else {
						Button(action: onCopy) {
							HStack(spacing: 4) {
								Image(systemName: isCopied ? "checkmark" : "doc.on.doc.fill")
								if isCopied {
									Text("Copied").font(.caption)
								}
							}
						}
						.buttonStyle(.plain)
						.foregroundStyle(isCopied ? .green : .secondary)
						.help("Copy to clipboard")
					}

					Button(action: onPlay) {
						Image(systemName: isPlaying ? "stop.fill" : "play.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(isPlaying ? .blue : .secondary)
					.help(isPlaying ? "Stop playback" : "Play audio")

					Button(action: onDelete) {
						Image(systemName: "trash.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.help("Delete transcript")
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
		.animation(.bouncy(duration: 0.3), value: status)
		.animation(.easeInOut(duration: 0.2), value: isCopied)
	}

	private var placeholderText: String {
		switch status {
		case .completed: return transcript.text
		case .cancelled: return "Recording cancelled"
		case .failed: return "Transcription failed"
		}
	}
}

#Preview {
	TranscriptView(
		transcript: Transcript(timestamp: Date(), text: "Hello, world!", audioPath: URL(fileURLWithPath: "/Users/langton/Downloads/test.m4a"), duration: 1.0),
		isPlaying: false,
		isRetrying: false,
		isCopied: false,
		retryError: nil,
		onPlay: {},
		onCopy: {},
		onDelete: {},
		onRetry: {}
	)
}

struct HistoryView: View {
	@ObserveInjection var inject
	let store: StoreOf<HistoryFeature>
	@State private var showingDeleteConfirmation = false
	@Shared(.hexSettings) var hexSettings: HexSettings

	var body: some View {
      Group {
        if !hexSettings.saveTranscriptionHistory {
          ContentUnavailableView {
            Label("History Disabled", systemImage: "clock.arrow.circlepath")
          } description: {
            Text("Transcription history is currently disabled.")
          } actions: {
            Button("Enable in Settings") {
              store.send(.navigateToSettings)
            }
          }
        } else if store.transcriptionHistory.history.isEmpty {
          ContentUnavailableView {
            Label("No Transcriptions", systemImage: "text.bubble")
          } description: {
            Text("Your transcription history will appear here.")
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(store.transcriptionHistory.history) { transcript in
                TranscriptView(
                  transcript: transcript,
                  isPlaying: store.playingTranscriptID == transcript.id,
                  isRetrying: store.retryingTranscriptIDs.contains(transcript.id),
                  isCopied: store.copiedTranscriptIDs.contains(transcript.id),
                  retryError: store.lastRetryError[transcript.id],
                  onPlay: { store.send(.playTranscript(transcript.id)) },
                  onCopy: { store.send(.copyTranscript(transcript.id)) },
                  onDelete: { store.send(.deleteTranscript(transcript.id)) },
                  onRetry: { store.send(.retryTranscript(transcript.id)) }
                )
              }
            }
            .padding()
          }
          .toolbar {
            Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
              Label("Delete All", systemImage: "trash")
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
      }.enableInjection()
	}
}
