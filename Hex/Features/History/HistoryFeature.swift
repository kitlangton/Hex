import AVFoundation
import ComposableArchitecture
import Dependencies
import SwiftUI
import Inject

// MARK: - Models

struct Transcript: Codable, Equatable, Identifiable {
	var id: UUID
	var timestamp: Date
	var text: String
	var audioPath: URL?
	var duration: TimeInterval

	// Persisted cache indicating whether audio is expected to be available for this transcript.
	// This avoids synchronous file system checks during UI rendering.
	var audioAvailable: Bool

	// Cheap computed property that uses the cached flag.
	var hasAudio: Bool {
		audioAvailable && audioPath != nil
	}

	init(
		id: UUID = UUID(),
		timestamp: Date,
		text: String,
		audioPath: URL?,
		duration: TimeInterval,
		audioAvailable: Bool? = nil
	) {
		self.id = id
		self.timestamp = timestamp
		self.text = text
		self.audioPath = audioPath
		self.duration = duration
		// Default to true only when an audioPath exists; remains false otherwise.
		self.audioAvailable = audioAvailable ?? (audioPath != nil)
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case timestamp
		case text
		case audioPath
		case duration
		case audioAvailable
	}

	// Custom decoding for backward compatibility: if audioAvailable is absent,
	// infer it from whether audioPath is present.
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decode(UUID.self, forKey: .id)
		self.timestamp = try container.decode(Date.self, forKey: .timestamp)
		self.text = try container.decode(String.self, forKey: .text)
		self.audioPath = try container.decodeIfPresent(URL.self, forKey: .audioPath)
		self.duration = try container.decode(TimeInterval.self, forKey: .duration)
		self.audioAvailable = try container.decodeIfPresent(Bool.self, forKey: .audioAvailable) ?? (self.audioPath != nil)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(self.id, forKey: .id)
		try container.encode(self.timestamp, forKey: .timestamp)
		try container.encode(self.text, forKey: .text)
		try container.encodeIfPresent(self.audioPath, forKey: .audioPath)
		try container.encode(self.duration, forKey: .duration)
		try container.encode(self.audioAvailable, forKey: .audioAvailable)
	}
}

struct TranscriptionHistory: Codable, Equatable {
	var history: [Transcript] = []
}

extension SharedReaderKey
	where Self == FileStorageKey<TranscriptionHistory>.Default
{
	static var transcriptionHistory: Self {
		Self[
			.fileStorage(URL.documentsDirectory.appending(component: "transcription_history.json")),
			default: .init()
		]
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
		// Break any potential retain cycles by clearing callback
		onPlaybackFinished = nil
	}

	// AVAudioPlayerDelegate method
	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		self.player = nil
		// Capture and clear the callback to avoid any retain cycles
		let completion = self.onPlaybackFinished
		self.onPlaybackFinished = nil
		Task { @MainActor in
			completion?()
		}
	}
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
	@ObservableState
	struct State {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		var playingTranscriptID: UUID?
		var audioPlayer: AVAudioPlayer?
		var audioPlayerController: AudioPlayerController?
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
					// Stop playback if tapping the same transcript
					state.audioPlayerController?.stop()
					state.audioPlayer = nil
					state.audioPlayerController = nil
					state.playingTranscriptID = nil
					return .none
				}

				// Stop any existing playback
				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil

				// Find the transcript and play its audio
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}
				// Ensure audio exists: require both a URL and an actual file on disk.
				// If the file is missing but we previously believed it was available, correct the cache and persist so the UI updates.
				guard let url = transcript.audioPath, FileManager.default.fileExists(atPath: url.path) else {
					if transcript.audioAvailable {
						state.$transcriptionHistory.withLock { history in
							if let idx = history.history.firstIndex(where: { $0.id == id }) {
								history.history[idx].audioAvailable = false
							}
						}
						return .run { [sharedHistory = state.$transcriptionHistory] _ in
							try? await sharedHistory.save()
						}
					}
					return .none
				}

				do {
					let controller = AudioPlayerController()
					let player = try controller.play(url: url)

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
					print("Error playing audio: \(error)")
        // Surface error to user via alert
        return .run { _ in
          await MainActor.run {
            _ = NSApp.presentError(error as NSError)
          }
        }
				}

			case .stopPlayback, .playbackFinished:
				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil
				state.playingTranscriptID = nil
				return .none

			case let .copyToClipboard(text):
				return .run { _ in
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				}

			case let .deleteTranscript(id):
				guard let index = state.transcriptionHistory.history.firstIndex(where: { $0.id == id }) else {
					return .none
				}

				let transcript = state.transcriptionHistory.history[index]

				if state.playingTranscriptID == id {
					state.audioPlayerController?.stop()
					state.audioPlayer = nil
					state.audioPlayerController = nil
					state.playingTranscriptID = nil
				}

				// Update state first
				_ = state.$transcriptionHistory.withLock { history in
					history.history.remove(at: index)
				}

				// Delete file after ensuring state persistence completes
				return .run { [sharedHistory = state.$transcriptionHistory] _ in
					// Explicitly save the state and wait for completion
					try? await sharedHistory.save()
					// Now safe to delete the file (if it exists)
					if let url = transcript.audioPath {
						try? FileManager.default.removeItem(at: url)
					}
				}

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				// Capture transcripts before clearing state
				let transcripts = state.transcriptionHistory.history

				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil
				state.playingTranscriptID = nil

				// Update state first
				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}

				// Delete files after ensuring state persistence completes
				return .run { [sharedHistory = state.$transcriptionHistory] _ in
					// Explicitly save the state and wait for completion
					try? await sharedHistory.save()
					// Now safe to delete all files
					for transcript in transcripts {
						if let url = transcript.audioPath {
							try? FileManager.default.removeItem(at: url)
						}
					}
				}

			case .navigateToSettings:
				// This will be handled by the parent reducer
				return .none
			}
		}
	}
}

struct TranscriptView: View {
	let transcript: Transcript
	let isPlaying: Bool
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onDelete: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(transcript.text)
				.font(.body)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.trailing, 40) // Space for buttons
				.padding(12)

			Divider()

			HStack {
				HStack(spacing: 6) {
					Image(systemName: "clock")
					Text(transcript.timestamp.formatted(date: .numeric, time: .shortened))
					Text("•")
					Text(String(format: "%.1fs", transcript.duration))
					if !transcript.hasAudio {
						Text("•")
						Label("Text only", systemImage: "text.alignleft")
					}
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)

				Spacer()

				HStack(spacing: 10) {
					Button {
						onCopy()
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

					if transcript.hasAudio {
						Button(action: onPlay) {
							Image(systemName: isPlaying ? "stop.fill" : "play.fill")
						}
						.buttonStyle(.plain)
						.foregroundStyle(isPlaying ? .blue : .secondary)
						.help(isPlaying ? "Stop playback" : "Play audio")
					}

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
		.onDisappear {
			// Clean up any running task when view disappears
			copyTask?.cancel()
		}
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

#Preview {
	TranscriptView(
		transcript: Transcript(timestamp: Date(), text: "Hello, world!", audioPath: URL(fileURLWithPath: "/Users/langton/Downloads/test.m4a"), duration: 1.0),
		isPlaying: false,
		onPlay: {},
		onCopy: {},
		onDelete: {}
	)
}

struct HistoryView: View {
	@ObserveInjection var inject
	let store: StoreOf<HistoryFeature>
	@State private var showingDeleteConfirmation = false
	@Shared(.hexSettings) var hexSettings: HexSettings

	var body: some View {
      Group {
		if hexSettings.historyStorageMode == .off {
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
                  onPlay: { store.send(.playTranscript(transcript.id)) },
                  onCopy: { store.send(.copyToClipboard(transcript.text)) },
                  onDelete: { store.send(.deleteTranscript(transcript.id)) }
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
