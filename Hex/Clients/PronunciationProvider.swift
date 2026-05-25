import Foundation
import HexCore

struct PronunciationInput: Sendable {
	let audioURL: URL
	let durationSec: TimeInterval
	let customPromptTemplate: String?
}

struct PronunciationOutput: Sendable {
	let feedback: Feedback
	let model: String
	let costUSDEstimate: Double?
}

enum PronunciationStreamEvent: Sendable {
	case delta(String)             // an incremental chunk of raw model text
	case completed(PronunciationOutput)
}

enum PronunciationProviderError: Error, LocalizedError {
	case missingAPIKey
	case audioReadFailed(URL)
	case audioTooLong
	case requestFailed(statusCode: Int, body: String)
	case invalidJSON(raw: String)
	case notImplemented(provider: CoachProvider)
	case cancelled

	var errorDescription: String? {
		switch self {
		case .missingAPIKey:
			return "API key is missing. Add it in Settings → Coach."
		case .audioReadFailed(let url):
			return "Could not read audio at \(url.path)."
		case .audioTooLong:
			return "Recording is too long for the provider; first 60s would be sent."
		case .requestFailed(let status, let body):
			return "Provider request failed (\(status)): \(body)"
		case .invalidJSON(let raw):
			return "Provider returned invalid JSON: \(raw.prefix(200))"
		case .notImplemented(let provider):
			return "Provider \(provider.rawValue) is not implemented yet."
		case .cancelled:
			return "Analysis was cancelled."
		}
	}
}

protocol PronunciationProvider: Sendable {
	var providerKind: CoachProvider { get }
	func analyze(_ input: PronunciationInput, apiKey: String) async throws -> PronunciationOutput

	/// Stream the model's response token-by-token so the UI can render it as it arrives.
	/// Default implementation falls back to a single `.delta` of the whole response,
	/// followed by `.completed`.
	func analyzeStreaming(
		_ input: PronunciationInput,
		apiKey: String
	) -> AsyncThrowingStream<PronunciationStreamEvent, Error>
}

extension PronunciationProvider {
	func analyzeStreaming(
		_ input: PronunciationInput,
		apiKey: String
	) -> AsyncThrowingStream<PronunciationStreamEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let output = try await analyze(input, apiKey: apiKey)
					continuation.yield(.completed(output))
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}
