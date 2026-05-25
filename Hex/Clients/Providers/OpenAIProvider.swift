import Foundation
import HexCore

struct OpenAIProvider: PronunciationProvider {
	let providerKind: CoachProvider = .openai
	let model: String

	init(model: String = "gpt-4o-audio-preview") {
		self.model = model
	}

	func analyze(_ input: PronunciationInput, apiKey: String) async throws -> PronunciationOutput {
		// M3: implement audio-capable Chat Completions call against
		// https://api.openai.com/v1/chat/completions with input_audio parts.
		throw PronunciationProviderError.notImplemented(provider: .openai)
	}
}
