import Foundation
import HexCore

/// Loads OpenRouter's catalog and keeps the last successful response available offline.
enum OpenRouterModelCatalog {
	private static let cacheURL = URL.hexMigratedFileURL(named: "openrouter_models.json")

	static func cachedModels() -> [OpenRouterModel] {
		guard let data = try? Data(contentsOf: cacheURL),
			  let models = try? JSONDecoder().decode([OpenRouterModel].self, from: data)
		else { return [] }
		return models
	}

	static func refresh(apiKey: String) async throws -> [OpenRouterModel] {
		var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models?input_modalities=text&output_modalities=text")!)
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
			throw OpenRouterModelCatalogError.requestFailed
		}

		let models = try JSONDecoder().decode(Response.self, from: data).data
			.filter { !$0.id.isEmpty && !$0.name.isEmpty }
		try save(models)
		return models
	}

	private static func save(_ models: [OpenRouterModel]) throws {
		let data = try JSONEncoder().encode(models)
		try data.write(to: cacheURL, options: .atomic)
	}

	private struct Response: Decodable {
		let data: [OpenRouterModel]
	}

	private enum OpenRouterModelCatalogError: LocalizedError {
		case requestFailed

		var errorDescription: String? { "Could not load OpenRouter models" }
	}
}
