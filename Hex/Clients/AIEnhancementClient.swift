//
//  AIEnhancementClient.swift
//  Hex
//
//  Created by Claude AI on 4/22/25.
//

import Dependencies
import DependenciesMacros
import Foundation
import HexCore

// Note: Future enhancement could use OllamaKit directly:
// import OllamaKit

/// A client that enhances transcribed text using local LLMs.
/// Supports both Ollama and other local options (future expansion).
@DependencyClient
struct AIEnhancementClient {
    /// Enhances the given text using the specified model.
    var enhance: @Sendable (String, String, EnhancementOptions, @escaping (Progress) -> Void) async throws -> String = { text, _, _, _ in text }
    
    /// Checks if Ollama is installed and running on the system
    var isOllamaAvailable: @Sendable () async -> Bool = { false }
    
    /// Gets a list of available models from Ollama
    var getAvailableModels: @Sendable () async throws -> [String] = { [] }
}

/// Enhancement options for AI processing
struct EnhancementOptions {
    /// The prompt to send to the AI model for text enhancement
    var prompt: String
    
    /// Temperature controls randomness: lower values (0.1-0.3) are more precise,
    /// higher values (0.7-1.0) give more creative/varied results
    var temperature: Double
    
    /// Maximum number of tokens to generate in the response
    var maxTokens: Int
    
    /// Default prompt for enhancing transcribed text with clear instructions
    static let defaultPrompt = HexSettings.defaultAIEnhancementPrompt
    
    /// Default enhancement options for transcribed text
    static let `default` = EnhancementOptions(
        prompt: defaultPrompt,
        temperature: 0.3,
        maxTokens: 1000
    )
    
    /// Custom initialization with sensible defaults
    init(prompt: String = defaultPrompt, temperature: Double = 0.3, maxTokens: Int = 1000) {
        self.prompt = prompt
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// Dependency Key for AIEnhancementClient
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

/// Live implementation of AIEnhancementClient
class AIEnhancementClientLive {
    // MARK: - Public Methods
    
    /// Enhances text using a local AI model
    func enhance(text: String, model: String, options: EnhancementOptions, progressCallback: @escaping (Progress) -> Void) async throws -> String {
        // Skip if the text is empty or too short
        guard !text.isEmpty, text.count > 5 else {
            return text
        }
        
        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)
        
        // For now, we support Ollama only
        do {
            let enhancedText = try await enhanceWithOllama(text: text, model: model, options: options) { fraction in
                progress.completedUnitCount = Int64(fraction * 100)
                progressCallback(progress)
            }
            
            progress.completedUnitCount = 100
            progressCallback(progress)
            
            return enhancedText
        } catch {
            print("[AIEnhancementClientLive] Error enhancing text: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Checks if Ollama is available on the system
    func isOllamaAvailable() async -> Bool {
        // Simple check - try to connect to Ollama's API endpoint
        do {
            var request = URLRequest(url: URL(string: "http://localhost:11434/api/version")!)
            request.timeoutInterval = 3.0 // Short timeout for quick feedback
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            print("[AIEnhancementClientLive] Ollama not available: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Gets a list of available models from Ollama
    func getAvailableModels() async throws -> [String] {
        // Our direct API implementation:
        struct ModelResponse: Decodable {
            struct Model: Decodable {
                let name: String
                let modifiedAt: String?
                let size: Int64?
                
                enum CodingKeys: String, CodingKey {
                    case name
                    case modifiedAt = "modified_at"
                    case size
                }
            }
            let models: [Model]
        }
        
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 5.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "AIEnhancementClient", code: -1, 
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response from Ollama"])
            }
            
            if httpResponse.statusCode != 200 {
                throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode, 
                              userInfo: [NSLocalizedDescriptionKey: "Ollama returned status code \(httpResponse.statusCode)"])
            }
            
            do {
                let modelResponse = try JSONDecoder().decode(ModelResponse.self, from: data)
                // Sort models alphabetically for better display
                return modelResponse.models.map { $0.name }.sorted()
            } catch let decodingError {
                print("[AIEnhancementClientLive] Failed to decode model list: \(decodingError)")
                throw NSError(domain: "AIEnhancementClient", code: -2, 
                            userInfo: [NSLocalizedDescriptionKey: "Failed to parse model list from Ollama. \(decodingError.localizedDescription)"])
            }
        } catch {
            print("[AIEnhancementClientLive] Error getting models: \(error.localizedDescription)")
            throw NSError(domain: "AIEnhancementClient", code: -3, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Ollama. Ensure it's running."])
        }
    }
    
    // MARK: - Private Helpers
    
    /// Enhances text using Ollama's API
    private func enhanceWithOllama(text: String, model: String, options: EnhancementOptions, progressCallback: @escaping (Double) -> Void) async throws -> String {
        // Initial progress update
        progressCallback(0.1)
        
        // Validate inputs
        guard !model.isEmpty else {
            throw NSError(domain: "AIEnhancementClient", code: -4, 
                          userInfo: [NSLocalizedDescriptionKey: "No model selected for enhancement"])
        }
        
        let url = URL(string: "http://localhost:11434/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0 // Allow longer timeout for generation
        
        // Create a well-formatted prompt with clear instructions
        let fullPrompt = """
        \(options.prompt)
        
        TEXT TO IMPROVE:
        \(text)
        
        IMPROVED TEXT:
        """
        
        // Build request parameters with appropriate defaults
        let requestDict: [String: Any] = [
            "model": model,
            "prompt": fullPrompt,
            "temperature": max(0.1, min(1.0, options.temperature)), // Ensure valid range
            "max_tokens": max(100, min(2000, options.maxTokens)),   // Reasonable limits
            "stream": false,
            "system": "You are an AI that improves transcribed text while preserving meaning."
        ]
        
        do {
            // Progress update - request prepared
            progressCallback(0.2)
            
            // Convert to JSON and send
            let requestData = try JSONSerialization.data(withJSONObject: requestDict)
            request.httpBody = requestData
            
            // Make the request
            let (responseData, urlResponse) = try await URLSession.shared.data(for: request)
            
            // Progress update - response received
            progressCallback(0.8)
            
            // Validate response
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw NSError(domain: "AIEnhancementClient", code: -1, 
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response from Ollama"])
            }
            
            if httpResponse.statusCode != 200 {
                // Try to extract error message if available
                if let errorDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let errorMessage = errorDict["error"] as? String {
                    throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode, 
                                  userInfo: [NSLocalizedDescriptionKey: "Ollama error: \(errorMessage)"])
                } else {
                    throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode, 
                                  userInfo: [NSLocalizedDescriptionKey: "Ollama returned status code \(httpResponse.statusCode)"])
                }
            }
            
            // Parse response
            if let responseDict = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let enhancedText = responseDict["response"] as? String {
                
                // Progress update - processing complete
                progressCallback(1.0)
                
                // Clean up the response - trim whitespace and ensure it's not empty
                let cleanedText = enhancedText.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanedText.isEmpty ? text : cleanedText
            } else {
                throw NSError(domain: "AIEnhancementClient", code: -2, 
                              userInfo: [NSLocalizedDescriptionKey: "Failed to parse Ollama response"])
            }
        } catch let error as NSError {
            // Log the error and rethrow
            print("[AIEnhancementClientLive] Error enhancing text: \(error.localizedDescription)")
            throw error
        } catch {
            // Handle unexpected errors
            print("[AIEnhancementClientLive] Unexpected error: \(error)")
            throw NSError(domain: "AIEnhancementClient", code: -3, 
                          userInfo: [NSLocalizedDescriptionKey: "Error communicating with Ollama: \(error.localizedDescription)"])
        }
    }
}