//
//  AIEnhancementClient.swift
//  Hex
//

import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let logger = HexLog.aiEnhancement

/// Errors that can occur during AI enhancement.
enum AIEnhancementError: LocalizedError {
    case ollamaUnavailable
    case noModelSelected
    case invalidResponse
    case httpError(statusCode: Int, message: String?)
    case decodingFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .ollamaUnavailable:
            return "Ollama is not available. Please ensure it's running."
        case .noModelSelected:
            return "No model selected for enhancement."
        case .invalidResponse:
            return "Invalid response from Ollama."
        case let .httpError(code, message):
            return message ?? "Ollama returned status code \(code)."
        case let .decodingFailed(detail):
            return "Failed to parse response from Ollama: \(detail)"
        case let .connectionFailed(detail):
            return "Failed to connect to Ollama: \(detail)"
        }
    }
}

/// A client that enhances transcribed text using local LLMs via Ollama.
@DependencyClient
struct AIEnhancementClient {
    var enhance: @Sendable (String, String, EnhancementOptions, @escaping (Progress) -> Void) async throws -> String = { text, _, _, _ in text }
    var isOllamaAvailable: @Sendable () async -> Bool = { false }
    var getAvailableModels: @Sendable () async throws -> [String] = { [] }
}

/// Enhancement options for AI processing.
struct EnhancementOptions {
    var prompt: String
    var temperature: Double
    var maxTokens: Int

    static let defaultPrompt = HexSettings.defaultAIEnhancementPrompt

    static let `default` = EnhancementOptions(
        prompt: defaultPrompt,
        temperature: 0.3,
        maxTokens: 1000
    )

    init(prompt: String = defaultPrompt, temperature: Double = 0.3, maxTokens: Int = 1000) {
        self.prompt = prompt
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

extension AIEnhancementClient: DependencyKey {
    static var liveValue: Self {
        let live = AIEnhancementClientLive()
        return Self(
            enhance: { try await live.enhance(text: $0, model: $1, options: $2, progressCallback: $3) },
            isOllamaAvailable: { await live.isOllamaAvailable() },
            getAvailableModels: { try await live.getAvailableModels() }
        )
    }
}

extension DependencyValues {
    var aiEnhancement: AIEnhancementClient {
        get { self[AIEnhancementClient.self] }
        set { self[AIEnhancementClient.self] = newValue }
    }
}

// MARK: - Live Implementation

private final class AIEnhancementClientLive {
    private static let baseURL = "http://localhost:11434"
    private static let requestTimeout: TimeInterval = 5
    private static let generateTimeout: TimeInterval = 60

    func enhance(text: String, model: String, options: EnhancementOptions, progressCallback: @escaping (Progress) -> Void) async throws -> String {
        guard !text.isEmpty, text.count > 5 else {
            logger.debug("Text too short for enhancement, returning original")
            return text
        }

        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)

        logger.info("Starting enhancement with model '\(model)' for \(text.count) chars")

        guard await isOllamaAvailable() else {
            throw AIEnhancementError.ollamaUnavailable
        }

        progress.completedUnitCount = 20
        progressCallback(progress)

        let enhancedText = try await generate(text: text, model: model, options: options)

        progress.completedUnitCount = 100
        progressCallback(progress)

        logger.info("Enhancement complete (\(enhancedText.count) chars)")
        return enhancedText
    }

    func isOllamaAvailable() async -> Bool {
        do {
            var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/version")!)
            request.timeoutInterval = Self.requestTimeout
            let (_, response) = try await URLSession.shared.data(for: request)
            let available = (response as? HTTPURLResponse)?.statusCode == 200
            logger.debug("Ollama availability: \(available)")
            return available
        } catch {
            logger.debug("Ollama not reachable: \(error.localizedDescription)")
            return false
        }
    }

    func getAvailableModels() async throws -> [String] {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/tags")!)
        request.timeoutInterval = Self.requestTimeout

        let (data, response) = try await fetchData(for: request)
        try validateHTTPResponse(response)

        struct ModelResponse: Decodable {
            struct Model: Decodable {
                let name: String
            }
            let models: [Model]
        }

        do {
            let decoded = try JSONDecoder().decode(ModelResponse.self, from: data)
            return decoded.models.map(\.name).sorted()
        } catch {
            throw AIEnhancementError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func generate(text: String, model: String, options: EnhancementOptions) async throws -> String {
        guard !model.isEmpty else {
            throw AIEnhancementError.noModelSelected
        }

        let url = URL(string: "\(Self.baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.generateTimeout

        let fullPrompt = """
        \(options.prompt)

        TEXT TO IMPROVE:
        \(text)

        IMPROVED TEXT:
        """

        let temperature = max(0.1, min(1.0, options.temperature))
        let maxTokens = max(100, min(2000, options.maxTokens))

        let requestDict: [String: Any] = [
            "model": model,
            "prompt": fullPrompt,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
            "system": "You are an AI that improves transcribed text while preserving meaning."
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestDict)

        let (data, response) = try await fetchData(for: request)
        try validateHTTPResponse(response, responseData: data)

        guard let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enhancedText = responseDict["response"] as? String else {
            throw AIEnhancementError.invalidResponse
        }

        let cleaned = enhancedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }

    private func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw AIEnhancementError.connectionFailed(error.localizedDescription)
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, responseData: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIEnhancementError.invalidResponse
        }
        guard http.statusCode == 200 else {
            var message: String?
            if let data = responseData,
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = dict["error"] as? String
            }
            throw AIEnhancementError.httpError(statusCode: http.statusCode, message: message)
        }
    }
}
