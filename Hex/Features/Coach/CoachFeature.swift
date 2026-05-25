import AppKit
import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

private let coachLogger = HexLog.coach

@Reducer
struct CoachFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		@Shared(.coachFeedback) var feedbackHistory: CoachFeedbackHistory

		var lastObservedTranscriptID: UUID?
		var inFlightTranscriptIDs: Set<UUID> = []
		var lastError: String?
		var didShowErrorNoticeThisSession: Bool = false

		// Live streaming preview shown in the popover while a transcript is being analyzed.
		// Holds the most recent in-flight stream; we keep one at a time for simplicity.
		var streamingPreview: StreamingPreview?

		// API-key UI state. Stores the last 4 chars so the view can render
		// "•••• abcd" without exposing the full secret. Updated when the
		// key is loaded, saved, or removed.
		var apiKeyLast4: [CoachProvider: String] = [:]
		var apiKeyInputs: [CoachProvider: String] = [:]
		var apiKeyTestState: APITestState = .idle

		enum APITestState: Equatable, Sendable {
			case idle
			case testing
			case passed
			case failed(String)
		}
	}

	enum Action: BindableAction {
		case binding(BindingAction<State>)
		case task
		case transcriptionHistoryChanged
		case analyze(Transcript)
		case streamingDelta(transcriptID: UUID, chunk: String)
		case analysisSucceeded(CoachFeedbackEntry, audioPath: URL)
		case analysisFailed(transcriptID: UUID, error: String)

		// Settings management
		case setEnabled(Bool)
		case setProvider(CoachProvider)
		case setThresholdSec(Int)
		case setDeleteAudioAfterAnalysis(Bool)
		case setAutoShowPopover(Bool)
		case setCustomPromptTemplate(String?)
		case resetPromptTemplate

		// API key management
		case loadApiKeys
		case apiKeyLoaded(provider: CoachProvider, last4: String?)
		case setApiKeyInput(provider: CoachProvider, value: String)
		case saveApiKey(provider: CoachProvider)
		case removeApiKey(provider: CoachProvider)
		case testApiKey
		case apiKeyTestCompleted(Result<String, NSError>)

		// History maintenance
		case clearFeedbackHistory
	}

	@Dependency(\.coachClient) var coachClient
	@Dependency(\.keychain) var keychain
	@Dependency(\.transcriptPersistence) var transcriptPersistence
	@Dependency(\.coachNotifier) var coachNotifier

	var body: some ReducerOf<Self> {
		BindingReducer()

		Reduce { state, action in
			switch action {
			case .binding:
				return .none

			case .task:
				state.lastObservedTranscriptID = state.transcriptionHistory.history.first?.id
				let shouldRequestAuth = state.hexSettings.coach.enabled
				return .merge(
					startObservingTranscriptionHistory(),
					.send(.loadApiKeys),
					.run { [coachNotifier] _ in
						if shouldRequestAuth {
							await coachNotifier.requestAuthorization()
						}
					}
				)

			case .transcriptionHistoryChanged:
				return processNewTranscripts(&state)

			case let .analyze(transcript):
				state.inFlightTranscriptIDs.insert(transcript.id)
				state.streamingPreview = StreamingPreview(
					transcriptID: transcript.id,
					transcript: transcript.text,
					timestamp: Date(),
					streamingText: ""
				)
				let settings = state.hexSettings.coach
				if settings.autoShowPopover {
					NotificationCenter.default.post(name: .coachShouldPresentPopover, object: nil)
				}
				return .run { [coachClient] send in
					do {
						let stream = coachClient.analyzeStream(transcript, settings)
						for try await event in stream {
							switch event {
							case let .delta(chunk):
								await send(.streamingDelta(transcriptID: transcript.id, chunk: chunk))
							case let .completed(entry):
								await send(.analysisSucceeded(entry, audioPath: transcript.audioPath))
							}
						}
					} catch {
						let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
						coachLogger.error("Coach analysis failed: \(message, privacy: .public)")
						await send(.analysisFailed(transcriptID: transcript.id, error: message))
					}
				}

			case let .streamingDelta(transcriptID, chunk):
				guard state.streamingPreview?.transcriptID == transcriptID else { return .none }
				state.streamingPreview?.streamingText.append(chunk)
				return .none

			case let .analysisSucceeded(entry, audioPath):
				state.inFlightTranscriptIDs.remove(entry.transcriptID)
				state.lastError = nil
				if state.streamingPreview?.transcriptID == entry.transcriptID {
					state.streamingPreview = nil
				}
				state.$feedbackHistory.withLock { history in
					history.append(entry)
				}
				coachLogger.notice("Coach feedback ready: score=\(entry.feedback.overallScore) issues=\(entry.feedback.issues.count)")

				let shouldDeleteAudio = state.hexSettings.coach.deleteAudioAfterAnalysis
				let notifyBody = entry.feedback.issues.first?.tip ?? entry.feedback.summary
				let notifyEffect: Effect<Action> = .run { [coachNotifier] _ in
					await coachNotifier.postFeedback("Pronunciation tip", notifyBody)
				}

				if shouldDeleteAudio {
					return .merge(
						notifyEffect,
						.run { [transcriptPersistence] _ in
							let shim = Transcript(
								id: entry.transcriptID,
								timestamp: entry.timestamp,
								text: entry.transcript,
								audioPath: audioPath,
								duration: entry.durationSec
							)
							try? await transcriptPersistence.deleteAudio(shim)
						}
					)
				}
				return notifyEffect

			case let .analysisFailed(transcriptID, error):
				state.inFlightTranscriptIDs.remove(transcriptID)
				if state.streamingPreview?.transcriptID == transcriptID {
					state.streamingPreview = nil
				}
				state.lastError = error

				guard !state.didShowErrorNoticeThisSession else { return .none }
				state.didShowErrorNoticeThisSession = true
				return .run { [coachNotifier] _ in
					await coachNotifier.postError("Coach error", error)
				}

			case let .setEnabled(enabled):
				state.$hexSettings.withLock { $0.coach.enabled = enabled }
				guard enabled else { return .none }
				return .run { [coachNotifier] _ in
					await coachNotifier.requestAuthorization()
				}

			case let .setProvider(provider):
				state.$hexSettings.withLock { $0.coach.provider = provider }
				return .none

			case let .setThresholdSec(value):
				state.$hexSettings.withLock { $0.coach.thresholdSec = max(3, min(120, value)) }
				return .none

			case let .setDeleteAudioAfterAnalysis(enabled):
				state.$hexSettings.withLock { $0.coach.deleteAudioAfterAnalysis = enabled }
				return .none

			case let .setAutoShowPopover(enabled):
				state.$hexSettings.withLock { $0.coach.autoShowPopover = enabled }
				return .none

			case let .setCustomPromptTemplate(template):
				state.$hexSettings.withLock {
					$0.coach.customPromptTemplate = (template?.isEmpty == true) ? nil : template
				}
				return .none

			case .resetPromptTemplate:
				state.$hexSettings.withLock {
					$0.coach.customPromptTemplate = nil
				}
				return .none

			case .loadApiKeys:
				return .run { [keychain] send in
					for provider in CoachProvider.allCases {
						let key = await keychain.read(provider.rawValue)
						let last4 = key.flatMap { $0.count >= 4 ? String($0.suffix(4)) : $0 }
						await send(.apiKeyLoaded(provider: provider, last4: last4))
					}
				}

			case let .apiKeyLoaded(provider, last4):
				if let last4 {
					state.apiKeyLast4[provider] = last4
				} else {
					state.apiKeyLast4.removeValue(forKey: provider)
				}
				return .none

			case let .setApiKeyInput(provider, value):
				state.apiKeyInputs[provider] = value
				return .none

			case let .saveApiKey(provider):
				guard let value = state.apiKeyInputs[provider]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
					return .none
				}
				state.apiKeyInputs[provider] = ""
				let last4 = value.count >= 4 ? String(value.suffix(4)) : value
				state.apiKeyLast4[provider] = last4
				return .run { [keychain] _ in
					do {
						try await keychain.write(provider.rawValue, value)
					} catch {
						coachLogger.error("Failed to save API key for \(provider.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
					}
				}

			case let .removeApiKey(provider):
				state.apiKeyLast4.removeValue(forKey: provider)
				state.apiKeyInputs[provider] = ""
				return .run { [keychain] _ in
					try? await keychain.delete(provider.rawValue)
				}

			case .testApiKey:
				state.apiKeyTestState = .testing
				return .run { [coachClient, hexSettings = state.hexSettings] send in
					// We piggy-back on the existing analyze flow with a tiny, fixed-text
					// transcript and a 1-second silent WAV that we ship inline. If the
					// provider returns *any* parseable response, the key works.
					do {
						let url = try makeOneSecondSilentWAV()
						defer { try? FileManager.default.removeItem(at: url) }
						let synthetic = Transcript(
							timestamp: Date(),
							text: "Hello, this is a microphone test.",
							audioPath: url,
							duration: 1.0
						)
						_ = try await coachClient.analyze(synthetic, hexSettings.coach)
						await send(.apiKeyTestCompleted(.success("Key works.")))
					} catch {
						let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
						await send(.apiKeyTestCompleted(.failure(NSError(domain: "Coach", code: 0, userInfo: [NSLocalizedDescriptionKey: message]))))
					}
				}

			case let .apiKeyTestCompleted(.success(message)):
				state.apiKeyTestState = .passed
				coachLogger.notice("Coach API key test passed: \(message, privacy: .public)")
				return .none

			case let .apiKeyTestCompleted(.failure(error)):
				state.apiKeyTestState = .failed(error.localizedDescription)
				return .none

			case .clearFeedbackHistory:
				state.$feedbackHistory.withLock { $0 = .init() }
				return .none
			}
		}
	}

	private func startObservingTranscriptionHistory() -> Effect<Action> {
		.run { send in
			@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
			for await _ in $transcriptionHistory.publisher.values {
				await send(.transcriptionHistoryChanged)
			}
		}
	}

	private func processNewTranscripts(_ state: inout State) -> Effect<Action> {
		guard state.hexSettings.coach.enabled else { return .none }

		let threshold = TimeInterval(state.hexSettings.coach.thresholdSec)
		let history = state.transcriptionHistory.history
		let lastSeen = state.lastObservedTranscriptID

		var candidates: [Transcript] = []
		for transcript in history {
			if transcript.id == lastSeen { break }
			candidates.append(transcript)
		}
		candidates.reverse()

		if let newestID = history.first?.id {
			state.lastObservedTranscriptID = newestID
		}

		let qualifying = candidates.filter { $0.duration >= threshold && !state.inFlightTranscriptIDs.contains($0.id) }
		guard !qualifying.isEmpty else { return .none }

		return .merge(qualifying.map { .send(.analyze($0)) })
	}
}

/// Writes a 1-second, 16 kHz, mono, 32-bit float WAV of silence to a temp URL.
/// Used to verify provider API keys without actually capturing audio.
private func makeOneSecondSilentWAV() throws -> URL {
	let sampleRate: UInt32 = 16_000
	let bitsPerSample: UInt16 = 32
	let channels: UInt16 = 1
	let frames: UInt32 = sampleRate
	let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
	let blockAlign: UInt16 = channels * (bitsPerSample / 8)
	let dataSize: UInt32 = frames * UInt32(blockAlign)
	let riffSize: UInt32 = 36 + dataSize

	var data = Data()
	data.append("RIFF".data(using: .ascii)!)
	data.append(UInt32(riffSize).littleEndianData)
	data.append("WAVE".data(using: .ascii)!)
	data.append("fmt ".data(using: .ascii)!)
	data.append(UInt32(16).littleEndianData)         // fmt chunk size
	data.append(UInt16(3).littleEndianData)          // format = IEEE float
	data.append(UInt16(channels).littleEndianData)
	data.append(UInt32(sampleRate).littleEndianData)
	data.append(UInt32(byteRate).littleEndianData)
	data.append(UInt16(blockAlign).littleEndianData)
	data.append(UInt16(bitsPerSample).littleEndianData)
	data.append("data".data(using: .ascii)!)
	data.append(UInt32(dataSize).littleEndianData)
	data.append(Data(count: Int(dataSize)))          // silence

	let url = FileManager.default.temporaryDirectory.appendingPathComponent("coach-key-test-\(UUID().uuidString).wav")
	try data.write(to: url)
	return url
}

private extension FixedWidthInteger {
	var littleEndianData: Data {
		var value = self.littleEndian
		return Swift.withUnsafeBytes(of: &value) { Data($0) }
	}
}
