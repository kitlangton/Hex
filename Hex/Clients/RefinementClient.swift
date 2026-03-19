import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FoundationModels)
import FoundationModels
#endif

private let refinementLogger = HexLog.transcription
private let appleTimeout: Duration = .seconds(5)
private let geminiTimeout: Duration = .seconds(15)

@DependencyClient
struct RefinementClient {
	var refine: @Sendable (String, RefinementMode, RefinementTone, RefinementProvider, String?) async throws -> String = { text, _, _, _, _ in text }
}

extension RefinementClient: DependencyKey {
	static var liveValue: Self {
		Self(
			refine: { text, mode, tone, provider, apiKey in
				refinementLogger.notice("Refinement requested: mode=\(mode.rawValue) tone=\(tone.rawValue) provider=\(provider.rawValue) hasKey=\(apiKey?.isEmpty == false)")
				guard mode != .raw else { return text }
				return await safeRefine(text, mode: mode, tone: tone, provider: provider, apiKey: apiKey)
			}
		)
	}

	/// Wraps AI processing with timeout and error fallback — always returns usable text.
	private static func safeRefine(_ text: String, mode: RefinementMode, tone: RefinementTone, provider: RefinementProvider, apiKey: String?) async -> String {
		let timeout = provider == .gemini ? geminiTimeout : appleTimeout
		do {
			return try await withThrowingTaskGroup(of: String.self) { group in
				group.addTask {
					try await dispatch(text, mode: mode, tone: tone, provider: provider, apiKey: apiKey)
				}
				group.addTask {
					try await Task.sleep(for: timeout)
					throw RefinementError.timeout
				}

				guard let result = try await group.next() else {
					refinementLogger.warning("Refinement produced no result; falling back to raw text")
					return text
				}
				group.cancelAll()
				return result
			}
		} catch RefinementError.timeout {
			refinementLogger.warning("Refinement timed out after \(timeout) (\(provider.rawValue)); falling back to raw text")
			return text
		} catch RefinementError.geminiRequestFailed(let reason) {
			refinementLogger.warning("Gemini request failed: \(reason); falling back to raw text")
			return text
		} catch {
			refinementLogger.warning("Refinement failed (\(provider.rawValue)): \(error.localizedDescription); falling back to raw text")
			return text
		}
	}

	private static func dispatch(_ text: String, mode: RefinementMode, tone: RefinementTone, provider: RefinementProvider, apiKey: String?) async throws -> String {
		let result: String
		switch provider {
		case .apple:
			if #available(macOS 26.0, *) {
				result = try await appleProcess(text, mode: mode, tone: tone)
			} else {
				refinementLogger.warning("Apple Intelligence requires macOS 26+; returning raw text")
				return text
			}
		case .gemini:
			guard let apiKey, !apiKey.isEmpty else {
				refinementLogger.warning("Gemini API key not configured; returning raw text")
				return text
			}
			result = try await geminiProcess(text, mode: mode, tone: tone, apiKey: apiKey)
		}

		let cleaned = RefinementTextProcessor.clean(result)

		if RefinementTextProcessor.isRefusal(cleaned) {
			refinementLogger.warning("Model refused refinement; falling back to raw text")
			return text
		}

		if RefinementTextProcessor.isOffScript(output: cleaned, input: text, mode: mode) {
			refinementLogger.warning("Model likely went off-script; falling back to raw text")
			return text
		}

		return cleaned.isEmpty ? text : cleaned
	}

	private enum RefinementError: Error {
		case timeout
		case geminiRequestFailed(String)
	}

	// MARK: - Apple Intelligence

	@available(macOS 26.0, *)
	private static func appleProcess(_ text: String, mode: RefinementMode, tone: RefinementTone) async throws -> String {
		let session = LanguageModelSession()
		let prompt = RefinementPromptBuilder.buildPrompt(mode: mode, tone: tone, text: text)
		let label = mode == .summarized ? "Summarizing" : "Refining"
		refinementLogger.notice("\(label) via Apple Intelligence (\(text.count) chars)")
		let response = try await session.respond(to: prompt)
		refinementLogger.notice("\(label) complete (\(response.content.count) chars)")
		return response.content
	}

	// MARK: - Gemini

	private static func geminiProcess(_ text: String, mode: RefinementMode, tone: RefinementTone, apiKey: String) async throws -> String {
		let label = mode == .summarized ? "Summarizing" : "Refining"
		refinementLogger.notice("\(label) via Gemini (\(text.count) chars)")

		let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite-preview:generateContent?key=\(apiKey)")!

		let body: [String: Any] = [
			"contents": [
				["parts": [["text": RefinementPromptBuilder.buildPrompt(mode: mode, tone: tone, text: text)]]]
			],
			"generationConfig": [
				"temperature": 0.2,
				"maxOutputTokens": 2048
			]
		]

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		let (data, response) = try await URLSession.shared.data(for: request)

		guard let httpResponse = response as? HTTPURLResponse else {
			throw RefinementError.geminiRequestFailed("Not an HTTP response")
		}

		guard httpResponse.statusCode == 200 else {
			let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
			refinementLogger.error("Gemini API error \(httpResponse.statusCode): \(errorBody)")
			throw RefinementError.geminiRequestFailed("HTTP \(httpResponse.statusCode)")
		}

		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let candidates = json["candidates"] as? [[String: Any]],
			  let firstCandidate = candidates.first,
			  let content = firstCandidate["content"] as? [String: Any],
			  let parts = content["parts"] as? [[String: Any]],
			  let firstPart = parts.first,
			  let resultText = firstPart["text"] as? String else {
			throw RefinementError.geminiRequestFailed("Unexpected response format")
		}

		refinementLogger.notice("\(label) complete (\(resultText.count) chars)")
		return resultText
	}
}

extension DependencyValues {
	var refinement: RefinementClient {
		get { self[RefinementClient.self] }
		set { self[RefinementClient.self] = newValue }
	}
}
