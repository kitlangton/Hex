import Foundation

public struct LLMProviderModelMetadata: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(provider)#\(model)" }
    public let provider: String
    public let model: String
    public let displayName: String?
    public let context: Int?
    public let supportsToolCalling: Bool?
    public let toolReliability: LLMProviderCapabilities.ToolReliability?

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case displayName
        case context
        case supportsToolCalling
        case toolReliability
    }
}

public final class LLMModelRegistry: @unchecked Sendable {
    public static let shared = LLMModelRegistry()

    private let entries: [String: [String: LLMProviderModelMetadata]]
    private let logger = HexLog.llm

    private init() {
        let data = LLMModelRegistry.loadModelData()
        if let data, let decoded = try? JSONDecoder().decode([LLMProviderModelMetadata].self, from: data) {
            var grouped: [String: [String: LLMProviderModelMetadata]] = [:]
            for entry in decoded {
                var providerEntries = grouped[entry.provider, default: [:]]
                providerEntries[entry.model] = entry
                grouped[entry.provider] = providerEntries
            }
            self.entries = grouped
        } else {
            logger.error("Failed to load models_llm_providers.json; capabilities will use defaults")
            self.entries = [:]
        }
    }

    private static func loadModelData() -> Data? {
        let fileName = "models_llm_providers"
        let fileExtension = "json"
        if let url = Bundle.module.url(forResource: fileName, withExtension: fileExtension, subdirectory: "Data"),
           let data = try? Data(contentsOf: url) {
            return data
        }

        if let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension, subdirectory: "Data"),
           let data = try? Data(contentsOf: url) {
            return data
        }

        return nil
    }

    public func metadata(for providerType: LLMProvider.ProviderType, modelID: String?) -> LLMProviderModelMetadata? {
        guard let modelID else { return nil }
        return entries[providerType.rawValue]?[modelID]
    }

    public func models(for providerType: LLMProvider.ProviderType) -> [LLMProviderModelMetadata] {
        entries[providerType.rawValue]?.values.sorted { lhs, rhs in
            (lhs.displayName ?? lhs.model).localizedCaseInsensitiveCompare(rhs.displayName ?? rhs.model) == .orderedAscending
        } ?? []
    }
}
