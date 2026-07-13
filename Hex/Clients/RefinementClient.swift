import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FoundationModels)
import FoundationModels
#endif

private let refinementLogger = HexLog.transcription

@DependencyClient
struct RefinementClient {
	var refine: @Sendable (RefinementRequest) async throws -> String = { $0.text }
}

extension RefinementClient: DependencyKey {
	static var liveValue: Self {
		Self(refine: { request in
			guard request.mode != .raw else { return request.text }
			return try await safeRefine(request)
		})
	}

	private static func safeRefine(_ request: RefinementRequest) async throws -> String {
		let timeout: Duration = request.provider == .apple ? .seconds(5) : .seconds(15)
		let prompt = RefinementPromptBuilder.prompt(
			mode: request.mode,
			instructions: request.instructions,
			text: request.text
		)
		let result = try await RefinementTimeout.run(after: timeout) {
			try await process(request, prompt: prompt)
		}
		guard let validatedResult = validated(result) else {
			throw RefinementError.invalidResponse
		}
		return validatedResult
	}

	private static func validated(_ output: String) -> String? {
		let cleaned = RefinementTextProcessor.clean(output)
		guard !cleaned.isEmpty,
			  !RefinementTextProcessor.isRefusal(cleaned)
		else { return nil }
		return cleaned
	}

	private static func process(_ request: RefinementRequest, prompt: RefinementPrompt) async throws -> String {
		switch request.provider {
		case .apple:
			#if canImport(FoundationModels)
			if #available(macOS 26.0, *) {
				return try await appleProcess(prompt)
			}
			#endif
			throw RefinementError.providerUnavailable
		case .gemini:
			guard let apiKey = GeminiAPIKeyStore.read(), !apiKey.isEmpty else { throw RefinementError.missingConfiguration }
			return try await geminiProcess(prompt: prompt, apiKey: apiKey)
		case .openRouter:
			guard let apiKey = OpenRouterAPIKeyStore.read(), !apiKey.isEmpty,
				  let modelID = request.modelID, !modelID.isEmpty
			else { throw RefinementError.missingConfiguration }
			return try await openRouterProcess(prompt: prompt, apiKey: apiKey, modelID: modelID)
		}
	}

	#if canImport(FoundationModels)
	@available(macOS 26.0, *)
	private static func appleProcess(_ prompt: RefinementPrompt) async throws -> String {
		let session = LanguageModelSession(
			instructions: prompt.systemInstruction
		)
		return try await session.respond(to: prompt.sourceText).content
	}
	#endif

	private static func geminiProcess(prompt: RefinementPrompt, apiKey: String) async throws -> String {
		let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")!
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
		request.httpBody = try JSONEncoder().encode(
			GeminiRequest(
				instruction: prompt.systemInstruction,
				text: prompt.sourceText
			)
		)
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw RefinementError.requestFailed }
		guard let result = try JSONDecoder().decode(GeminiResponse.self, from: data).text else { throw RefinementError.invalidResponse }
		return result
	}

	private static func openRouterProcess(prompt: RefinementPrompt, apiKey: String, modelID: String) async throws -> String {
		var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		request.httpBody = try JSONEncoder().encode(
			OpenRouterRequest(
				model: modelID,
				instruction: prompt.systemInstruction,
				text: prompt.sourceText
			)
		)
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw RefinementError.requestFailed }
		guard let result = try JSONDecoder().decode(OpenRouterResponse.self, from: data).text else { throw RefinementError.invalidResponse }
		return result
	}

	private enum RefinementError: LocalizedError {
		case timeout, requestFailed, invalidResponse, missingConfiguration, providerUnavailable
		var errorDescription: String? {
			switch self {
			case .timeout: "Refinement timed out"
			case .requestFailed: "Refinement request failed"
			case .invalidResponse: "Refinement returned an invalid response"
			case .missingConfiguration: "Refinement provider is not configured"
			case .providerUnavailable: "Refinement provider is unavailable on this Mac"
			}
		}
	}
}

/// Runs an operation with a responsive timeout even if its implementation does not cooperate
/// with task cancellation. The losing operation is cancelled but never delays the caller.
enum RefinementTimeout {
	static func run<Value: Sendable>(
		after timeout: Duration,
		operation: @escaping @Sendable () async throws -> Value
	) async throws -> Value {
		let box = ContinuationBox<Value>()
		return try await withTaskCancellationHandler(operation: {
			try await withCheckedThrowingContinuation { continuation in
				box.install(continuation)
				let operationTask = Task.detached {
					do {
						box.resolve(.success(try await operation()))
					} catch {
						box.resolve(.failure(error))
					}
				}
				box.setOperationTask(operationTask)
				let timeoutTask = Task.detached {
					do {
						try await Task.sleep(for: timeout)
						box.cancel(with: RefinementTimeoutError.timedOut)
					} catch is CancellationError {
						return
					} catch {
						box.cancel(with: error)
					}
				}
				box.setTimeoutTask(timeoutTask)
			}
		}, onCancel: {
			box.cancel(with: CancellationError())
		})
	}

	private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
		private let lock = NSLock()
		private var continuation: CheckedContinuation<Value, Error>?
		private var operationTask: Task<Void, Never>?
		private var timeoutTask: Task<Void, Never>?
		private var isResolved = false
		private var pendingResult: Result<Value, Error>?

		func install(_ continuation: CheckedContinuation<Value, Error>) {
			lock.lock()
			let pendingResult = self.pendingResult
			if pendingResult == nil {
				self.continuation = continuation
			}
			lock.unlock()
			if let pendingResult {
				continuation.resume(with: pendingResult)
			}
		}

		func setOperationTask(_ task: Task<Void, Never>) {
			lock.lock()
			operationTask = task
			let shouldCancel = isResolved
			lock.unlock()
			if shouldCancel { task.cancel() }
		}

		func setTimeoutTask(_ task: Task<Void, Never>) {
			lock.lock()
			timeoutTask = task
			let shouldCancel = isResolved
			lock.unlock()
			if shouldCancel { task.cancel() }
		}

		func resolve(_ result: Result<Value, Error>) {
			finish(result, cancelOperation: false)
		}

		func cancel(with error: Error) {
			finish(.failure(error), cancelOperation: true)
		}

		private func finish(_ result: Result<Value, Error>, cancelOperation: Bool) {
			lock.lock()
			guard !isResolved else {
				lock.unlock()
				return
			}
			isResolved = true
			let continuation = self.continuation
			self.continuation = nil
			if continuation == nil {
				pendingResult = result
			}
			let task = operationTask
			let timeoutTask = self.timeoutTask
			lock.unlock()
			if cancelOperation { task?.cancel() }
			timeoutTask?.cancel()
			continuation?.resume(with: result)
		}
	}

	private enum RefinementTimeoutError: LocalizedError {
		case timedOut
		var errorDescription: String? { "Refinement timed out" }
	}
}

private struct GeminiRequest: Encodable {
	let systemInstruction: Content
	let contents: [Content]
	let generationConfig = GenerationConfig()
	let store = false

	init(instruction: String, text: String) {
		systemInstruction = .init(parts: [.init(text: instruction)])
		contents = [.init(parts: [.init(text: text)])]
	}

	struct Content: Encodable { let parts: [Part] }
	struct Part: Encodable { let text: String }
	struct GenerationConfig: Encodable {
		let temperature = 0.2
		let maxOutputTokens = RefinementOutput.maximumTokens
	}
}

private struct OpenRouterRequest: Encodable {
	let model: String
	let messages: [Message]
	let temperature = 0.2
	let maxTokens = RefinementOutput.maximumTokens

	init(model: String, instruction: String, text: String) {
		self.model = model
		messages = [
			.init(role: "system", content: instruction),
			.init(role: "user", content: text),
		]
	}

	struct Message: Encodable {
		let role: String
		let content: String
	}

	enum CodingKeys: String, CodingKey {
		case model, messages, temperature
		case maxTokens = "max_tokens"
	}
}

private enum RefinementOutput {
	static let maximumTokens = 2_048
}

private struct OpenRouterResponse: Decodable {
	let choices: [Choice]

	var text: String? { choices.first?.message.content }

	struct Choice: Decodable {
		let message: Message
	}

	struct Message: Decodable {
		let content: String?
	}
}

private struct GeminiResponse: Decodable {
	let candidates: [Candidate]?
	var text: String? { candidates?.first?.content?.parts?.first?.text }

	struct Candidate: Decodable { let content: Content? }
	struct Content: Decodable { let parts: [Part]? }
	struct Part: Decodable { let text: String? }
}

extension DependencyValues {
	var refinement: RefinementClient {
		get { self[RefinementClient.self] }
		set { self[RefinementClient.self] = newValue }
	}
}
