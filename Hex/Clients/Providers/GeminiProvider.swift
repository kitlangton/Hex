import Foundation
import HexCore

private let coachLogger = HexLog.coach

struct GeminiProvider: PronunciationProvider {
	let providerKind: CoachProvider = .gemini
	let model: String

	init(model: String = "gemini-3.1-flash-lite") {
		self.model = model
	}

	private static let endpointHost = "generativelanguage.googleapis.com"

	func analyze(_ input: PronunciationInput, apiKey: String) async throws -> PronunciationOutput {
		let (data, http) = try await sendRequest(input: input, apiKey: apiKey, streaming: false)
		guard (200...299).contains(http.statusCode) else {
			let body = String(data: data, encoding: .utf8) ?? "<binary>"
			throw PronunciationProviderError.requestFailed(statusCode: http.statusCode, body: body)
		}
		let raw = String(data: data, encoding: .utf8) ?? ""
		let markdownText = try Self.extractJSONText(from: data, raw: raw)
		let feedback = try decodeFeedback(from: markdownText)
		return PronunciationOutput(feedback: feedback, model: model, costUSDEstimate: nil)
	}

	func analyzeStreaming(
		_ input: PronunciationInput,
		apiKey: String
	) -> AsyncThrowingStream<PronunciationStreamEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task<Void, Never> {
				do {
					guard !apiKey.isEmpty else {
						throw PronunciationProviderError.missingAPIKey
					}
					let request = try buildRequest(input: input, apiKey: apiKey, streaming: true)
					let (bytes, response) = try await URLSession.shared.bytes(for: request)
					guard let http = response as? HTTPURLResponse else {
						throw PronunciationProviderError.requestFailed(statusCode: -1, body: "no HTTP response")
					}
					if !(200...299).contains(http.statusCode) {
						var body = ""
						for try await line in bytes.lines { body += line + "\n" }
						throw PronunciationProviderError.requestFailed(statusCode: http.statusCode, body: body)
					}

					var accumulated = ""
					for try await line in bytes.lines {
						try Task.checkCancellation()
						guard line.hasPrefix("data: ") else { continue }
						let payload = String(line.dropFirst("data: ".count))
						if payload == "[DONE]" { break }
						guard let chunkData = payload.data(using: .utf8),
						      let chunkText = Self.extractDeltaText(from: chunkData)
						else { continue }
						accumulated += chunkText
						continuation.yield(.delta(chunkText))
					}

					let feedback = try decodeFeedback(from: accumulated)
					continuation.yield(.completed(.init(feedback: feedback, model: model, costUSDEstimate: nil)))
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	// MARK: - Request builder

	private func buildRequest(input: PronunciationInput, apiKey: String, streaming: Bool) throws -> URLRequest {
		let audioData: Data
		do {
			audioData = try Data(contentsOf: input.audioURL)
		} catch {
			coachLogger.error("Gemini: failed to read audio at \(input.audioURL.path, privacy: .private)")
			throw PronunciationProviderError.audioReadFailed(input.audioURL)
		}
		let base64Audio = audioData.base64EncodedString()
		let prompt = Self.buildPrompt(template: input.customPromptTemplate)

		let body: [String: Any] = [
			"contents": [[
				"role": "user",
				"parts": [
					["text": prompt],
					["inlineData": ["mimeType": "audio/wav", "data": base64Audio]]
				]
			]],
			"generationConfig": [
				"temperature": 0.2
				// Plain text response so it streams cleanly as Markdown.
			]
		]

		var components = URLComponents()
		components.scheme = "https"
		components.host = Self.endpointHost
		components.path = "/v1beta/models/\(model):\(streaming ? "streamGenerateContent" : "generateContent")"
		var queryItems = [URLQueryItem(name: "key", value: apiKey)]
		if streaming { queryItems.append(URLQueryItem(name: "alt", value: "sse")) }
		components.queryItems = queryItems

		guard let url = components.url else {
			throw PronunciationProviderError.requestFailed(statusCode: -1, body: "bad URL")
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		return request
	}

	private func sendRequest(input: PronunciationInput, apiKey: String, streaming: Bool) async throws -> (Data, HTTPURLResponse) {
		guard !apiKey.isEmpty else { throw PronunciationProviderError.missingAPIKey }
		let request = try buildRequest(input: input, apiKey: apiKey, streaming: streaming)
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw PronunciationProviderError.requestFailed(statusCode: -1, body: "no HTTP response")
		}
		return (data, http)
	}

	private func decodeFeedback(from text: String) throws -> Feedback {
		CoachMarkdownParser.parse(text)
	}

	/// Strip Markdown fences and whitespace, return the substring from the first `{`
	/// to the matching closing `}`. Returns nil if no balanced object is found.
	static func extractJSONObject(from text: String) -> String? {
		guard let openIdx = text.firstIndex(of: "{") else { return nil }
		var depth = 0
		var inString = false
		var escape = false
		var i = openIdx
		while i < text.endIndex {
			let c = text[i]
			if escape { escape = false }
			else if c == "\\", inString { escape = true }
			else if c == "\"" { inString.toggle() }
			else if !inString {
				if c == "{" { depth += 1 }
				else if c == "}" {
					depth -= 1
					if depth == 0 {
						return String(text[openIdx...i])
					}
				}
			}
			i = text.index(after: i)
		}
		return nil
	}

	static func extractDeltaText(from chunkData: Data) -> String? {
		guard let root = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
			return nil
		}
		guard let candidates = root["candidates"] as? [[String: Any]],
		      let first = candidates.first,
		      let content = first["content"] as? [String: Any],
		      let parts = content["parts"] as? [[String: Any]]
		else { return nil }
		let text = parts.compactMap { $0["text"] as? String }.joined()
		return text.isEmpty ? nil : text
	}

	private static func extractJSONText(from data: Data, raw: String) throws -> String {
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let candidates = root["candidates"] as? [[String: Any]],
		      let first = candidates.first,
		      let content = first["content"] as? [String: Any],
		      let parts = content["parts"] as? [[String: Any]]
		else {
			throw PronunciationProviderError.invalidJSON(raw: raw)
		}
		let text = parts.compactMap { $0["text"] as? String }.joined()
		guard !text.isEmpty else { throw PronunciationProviderError.invalidJSON(raw: raw) }
		return text
	}

	/// The shipped default. Users can override this entirely from Settings →
	/// Pronunciation Coach → "Coach Prompt". There are no placeholders — the
	/// audio is attached separately by the API call, and the model is expected
	/// to do its own perception of what was said.
	static let defaultPromptTemplate: String = """
	You are a focused, kind English pronunciation coach.

	Listen to the attached audio. Identify the most impactful pronunciation
	issues you can clearly hear. You do not have a pre-supplied transcript —
	rely entirely on what you hear.

	Respond in EXACTLY this Markdown structure, in this order, with these
	headers verbatim. Do not wrap in code fences. Do not add prose outside
	the sections.

	## Score: <integer 1–10, calibrated against fluent native English as 10>

	## Summary
	<one sentence — what stood out most overall>

	## Native phrasing
	<The most natural way a confident native English speaker would say what
	you heard. Preserve meaning and tone — adjust word choice, grammar, idiom,
	or filler that gives the speaker away as non-native. NEVER leave this
	section blank: if the audio is already native-level, restate the sentence
	verbatim.>

	## Issues
	<For each issue (0–3 of them), use this block — omit the entire ## Issues
	section only if you have nothing to flag.>

	### <word or phrase that was mispronounced>
	- **You said:** <phonetic approximation of what you heard>
	- **Target:** <phonetic target>
	- **Tip:** <one concrete drill or memory device>

	## Wins
	- <one or two things the user did well>

	Constraints:
	- At most 3 issues, prioritized by impact (intelligibility > naturalness > finesse).
	- Skip issues you can't clearly hear. Better zero issues than guesses.
	- "Tip" should be a concrete drill, not vague advice.
	- Be warm and direct. No filler.
	"""

	/// User-facing help displayed under the prompt editor.
	static let placeholderHelp: String = """
	No placeholders — write the prompt exactly as you'd send it. The audio is \
	attached to the request automatically; the model produces its own perception \
	of what was said.
	"""

	static func buildPrompt(template overrideTemplate: String?) -> String {
		overrideTemplate?.isEmpty == false ? overrideTemplate! : defaultPromptTemplate
	}
}

/// Parse the Markdown response produced by the prompt above into a `Feedback`.
/// Tolerant of minor formatting drift (extra whitespace, missing optional sections).
/// Always returns a `Feedback` — even if every structured field is empty, the
/// `rawMarkdown` field carries the model's full response so the popover can
/// render it verbatim. The view layer uses `Feedback.isStructured` to decide
/// between card-style and raw-markdown rendering.
enum CoachMarkdownParser {
	static func parse(_ markdown: String) -> Feedback {
		let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
		let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

		// Section bodies keyed by lowercased header text (e.g. "summary", "native phrasing", "issues", "wins").
		var sections: [String: [String]] = [:]
		var scoreInline: Int?
		var currentKey: String?
		var currentBody: [String] = []

		func flush() {
			if let key = currentKey {
				sections[key, default: []].append(contentsOf: currentBody)
			}
			currentKey = nil
			currentBody = []
		}

		for raw in lines {
			let line = raw
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			// Match `## Score: 7` inline
			if let m = trimmed.range(of: #"^## *Score *: *(\d+)"#, options: .regularExpression) {
				flush()
				let token = String(trimmed[m]).replacingOccurrences(of: " ", with: "")
				if let digits = token.split(separator: ":").last, let n = Int(digits) {
					scoreInline = n
				}
				continue
			}

			if trimmed.hasPrefix("## ") {
				flush()
				currentKey = trimmed.dropFirst(3).lowercased().trimmingCharacters(in: .whitespaces)
			} else if currentKey != nil {
				currentBody.append(line)
			}
		}
		flush()

		// Score — fall back to looking in the body of "score" if not inline.
		let score: Int = scoreInline
			?? sections["score"]?.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first
			?? 0

		let summary = sections["summary"]?
			.joined(separator: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			?? ""

		let rewrite = sections["native phrasing"]?
			.joined(separator: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			?? ""

		let issues = parseIssues(sections["issues"] ?? [])
		let wins = parseBulletList(sections["wins"] ?? [])

		let extracted = score > 0 || !summary.isEmpty || !rewrite.isEmpty || !issues.isEmpty
		return Feedback(
			overallScore: extracted ? max(1, min(10, score == 0 ? 5 : score)) : 0,
			summary: summary,
			nativeRewrite: rewrite,
			issues: issues,
			wins: wins,
			rawMarkdown: markdown
		)
	}

	private static func parseIssues(_ body: [String]) -> [Issue] {
		var issues: [Issue] = []
		var word: String?
		var youSaid: String?
		var target: String?
		var tip: String?

		func emit() {
			guard let word else { return }
			issues.append(Issue(
				wordOrPhrase: word.trimmingCharacters(in: .whitespacesAndNewlines),
				whatYouSaid: youSaid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
				whatToSay: target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
				tip: tip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			))
		}

		func reset() {
			word = nil; youSaid = nil; target = nil; tip = nil
		}

		for raw in body {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("### ") {
				emit()
				reset()
				word = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
			} else if let value = parseLabeledBullet(line, label: "You said") {
				youSaid = value
			} else if let value = parseLabeledBullet(line, label: "Target") {
				target = value
			} else if let value = parseLabeledBullet(line, label: "Tip") {
				tip = value
			}
		}
		emit()
		return issues
	}

	private static func parseLabeledBullet(_ line: String, label: String) -> String? {
		let lower = line.lowercased()
		let labelKey = label.lowercased()
		// Match "- **You said:** xxx" or "- You said: xxx"
		guard lower.contains(labelKey + ":") else { return nil }
		guard let colon = line.range(of: ":") else { return nil }
		return String(line[colon.upperBound...])
			.replacingOccurrences(of: "**", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func parseBulletList(_ body: [String]) -> [String] {
		body.compactMap { raw -> String? in
			let line = raw.trimmingCharacters(in: .whitespaces)
			guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
			return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
		}
	}
}

