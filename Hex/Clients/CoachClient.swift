import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

@DependencyClient
struct CoachClient {
	var analyze: @Sendable (
		_ transcript: Transcript,
		_ settings: CoachSettings
	) async throws -> CoachFeedbackEntry

	/// Streamed flavor. Yields raw text deltas while the model is responding,
	/// and a final `.completed(CoachFeedbackEntry)` when done.
	var analyzeStream: @Sendable (
		_ transcript: Transcript,
		_ settings: CoachSettings
	) -> AsyncThrowingStream<CoachStreamEvent, Error> = { _, _ in
		AsyncThrowingStream { $0.finish() }
	}
}

enum CoachStreamEvent: Sendable {
	case delta(String)
	case completed(CoachFeedbackEntry)
}

extension CoachClient: DependencyKey {
	static var liveValue: Self {
		let keychain = KeychainClient.liveValue

		func providerAndInput(for transcript: Transcript, settings: CoachSettings) async throws -> (any PronunciationProvider, PronunciationInput, String) {
			let provider: any PronunciationProvider = {
				switch settings.provider {
				case .gemini: return GeminiProvider()
				case .openai: return OpenAIProvider()
				}
			}()
			guard let apiKey = await keychain.read(settings.provider.rawValue), !apiKey.isEmpty else {
				throw PronunciationProviderError.missingAPIKey
			}
			let input = PronunciationInput(
				audioURL: transcript.audioPath,
				durationSec: transcript.duration,
				customPromptTemplate: settings.customPromptTemplate
			)
			return (provider, input, apiKey)
		}

		return .init(
			analyze: { transcript, settings in
				let (provider, input, apiKey) = try await providerAndInput(for: transcript, settings: settings)
				let output = try await provider.analyze(input, apiKey: apiKey)
				return CoachFeedbackEntry(
					transcriptID: transcript.id,
					transcript: transcript.text,
					durationSec: transcript.duration,
					provider: settings.provider,
					model: output.model,
					feedback: output.feedback,
					costUSDEstimate: output.costUSDEstimate
				)
			},
			analyzeStream: { transcript, settings in
				AsyncThrowingStream { continuation in
					let task = Task<Void, Never> {
						do {
							let (provider, input, apiKey) = try await providerAndInput(for: transcript, settings: settings)
							let stream = provider.analyzeStreaming(input, apiKey: apiKey)
							for try await event in stream {
								try Task.checkCancellation()
								switch event {
								case let .delta(text):
									continuation.yield(.delta(text))
								case let .completed(output):
									let entry = CoachFeedbackEntry(
										transcriptID: transcript.id,
										transcript: transcript.text,
										durationSec: transcript.duration,
										provider: settings.provider,
										model: output.model,
										feedback: output.feedback,
										costUSDEstimate: output.costUSDEstimate
									)
									continuation.yield(.completed(entry))
								}
							}
							continuation.finish()
						} catch {
							continuation.finish(throwing: error)
						}
					}
					continuation.onTermination = { _ in task.cancel() }
				}
			}
		)
	}
}

extension DependencyValues {
	var coachClient: CoachClient {
		get { self[CoachClient.self] }
		set { self[CoachClient.self] = newValue }
	}
}
