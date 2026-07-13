import Foundation

/// A text-capable model returned by OpenRouter's public model catalog.
public struct OpenRouterModel: Codable, Equatable, Identifiable, Sendable {
	public struct Pricing: Codable, Equatable, Sendable {
		public let prompt: String
		public let completion: String

		public init(prompt: String, completion: String) {
			self.prompt = prompt
			self.completion = completion
		}

		public var inputPricePerMillionTokens: Decimal? {
			Decimal(string: prompt).map { $0 * Decimal(1_000_000) }
		}
	}

	public let id: String
	public let name: String
	public let pricing: Pricing
	public let contextLength: Int?

	public init(id: String, name: String, pricing: Pricing, contextLength: Int? = nil) {
		self.id = id
		self.name = name
		self.pricing = pricing
		self.contextLength = contextLength
	}

	enum CodingKeys: String, CodingKey {
		case id, name, pricing
		case contextLength = "context_length"
	}
}
