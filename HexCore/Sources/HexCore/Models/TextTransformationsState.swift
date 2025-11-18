import Foundation

public struct TransformationStack: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var pipeline: TextTransformationPipeline
	public var appliesToBundleIdentifiers: [String]
	public var voicePrefixes: [String]
	
	private enum CodingKeys: String, CodingKey {
		case id, name, pipeline, appliesToBundleIdentifiers, voicePrefixes, voicePrefix
	}
	
	public init(
		id: UUID = UUID(),
		name: String,
		pipeline: TextTransformationPipeline = .init(),
		appliesToBundleIdentifiers: [String] = [],
		voicePrefixes: [String] = []
	) {
		self.id = id
		self.name = name
		self.pipeline = pipeline
		self.appliesToBundleIdentifiers = appliesToBundleIdentifiers
		self.voicePrefixes = voicePrefixes
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		name = try container.decode(String.self, forKey: .name)
		pipeline = try container.decode(TextTransformationPipeline.self, forKey: .pipeline)
		appliesToBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .appliesToBundleIdentifiers) ?? []
		
		// Support both old voicePrefix (string) and new voicePrefixes (array)
		if let prefixes = try container.decodeIfPresent([String].self, forKey: .voicePrefixes) {
			voicePrefixes = prefixes
		} else if let prefix = try container.decodeIfPresent(String.self, forKey: .voicePrefix) {
			voicePrefixes = [prefix]
		} else {
			voicePrefixes = []
		}
	}
	
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(name, forKey: .name)
		try container.encode(pipeline, forKey: .pipeline)
		try container.encode(appliesToBundleIdentifiers, forKey: .appliesToBundleIdentifiers)
		try container.encode(voicePrefixes, forKey: .voicePrefixes)
	}
}

public struct TextTransformationsState: Codable, Equatable, Sendable {
	public static let currentSchemaVersion = 3
	
	public var schemaVersion: Int
	public var stacks: [TransformationStack]
	public var providers: [LLMProvider]
	public var lastSelectedStackID: UUID?
	
	public init(
		stacks: [TransformationStack] = [],
		providers: [LLMProvider] = [],
		lastSelectedStackID: UUID? = nil,
		schemaVersion: Int = TextTransformationsState.currentSchemaVersion
	) {
		let resolvedStacks = stacks.isEmpty ? [TransformationStack(name: "General", pipeline: .init())] : stacks
		self.stacks = resolvedStacks
		self.providers = providers
		self.schemaVersion = schemaVersion
		self.lastSelectedStackID = lastSelectedStackID ?? fallbackStackID(in: resolvedStacks)
	}
	
	private enum CodingKeys: String, CodingKey {
		case schemaVersion
		case stacks
		case providers
		case lastSelectedStackID
		case pipeline // legacy
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
		let stacks: [TransformationStack]
		if version < 2 {
			let legacyPipeline = try container.decodeIfPresent(TextTransformationPipeline.self, forKey: .pipeline) ?? .init()
			stacks = [TransformationStack(name: "General", pipeline: legacyPipeline)]
		} else {
			stacks = try container.decodeIfPresent([TransformationStack].self, forKey: .stacks) ?? []
		}
		let providers: [LLMProvider] = version >= 3 ? (try container.decodeIfPresent([LLMProvider].self, forKey: .providers) ?? []) : []
		let selected = try container.decodeIfPresent(UUID.self, forKey: .lastSelectedStackID)
		self.init(stacks: stacks, providers: providers, lastSelectedStackID: selected, schemaVersion: max(version, TextTransformationsState.currentSchemaVersion))
	}
	
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(TextTransformationsState.currentSchemaVersion, forKey: .schemaVersion)
		try container.encode(stacks, forKey: .stacks)
		try container.encode(providers, forKey: .providers)
		try container.encodeIfPresent(lastSelectedStackID, forKey: .lastSelectedStackID)
	}
	
	public func stack(with id: UUID?) -> TransformationStack? {
		guard let id else { return nil }
		return stacks.first(where: { $0.id == id })
	}
	
	public func orderedStacks(for bundleIdentifier: String?) -> [TransformationStack] {
		let lowered = bundleIdentifier?.lowercased()
		let matching = stacks.enumerated().compactMap { index, stack -> (TransformationStack, Int, Int)? in
			guard let lowered else { return nil }
			let matches = stack.appliesToBundleIdentifiers.filter { $0.lowercased() == lowered }.count
			return matches > 0 ? (stack, matches, index) : nil
		}
		.sorted { lhs, rhs in
			if lhs.1 == rhs.1 {
				return lhs.2 < rhs.2
			}
			return lhs.1 > rhs.1
		}
		.map { $0.0 }
		
		if !matching.isEmpty {
			return matching
		}
		let general = stacks.filter { $0.appliesToBundleIdentifiers.isEmpty }
		return general.isEmpty ? stacks : general
	}
	
	public func stack(for bundleIdentifier: String?) -> TransformationStack? {
		orderedStacks(for: bundleIdentifier).first
	}
	
	/// Returns stack and stripped text if voice prefix matches
	public func stackByVoicePrefix(text: String) -> (stack: TransformationStack, strippedText: String, matchedPrefix: String)? {
		for stack in stacks {
			for prefix in stack.voicePrefixes {
				let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !trimmedPrefix.isEmpty else { continue }
				
				// Check if text starts with prefix (case-insensitive)
				let pattern = "^\\s*\(NSRegularExpression.escapedPattern(for: trimmedPrefix))(?:[,\\s]+|$)"
				if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
				   let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
					let matchRange = Range(match.range, in: text)!
					let strippedText = String(text[matchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
					return (stack, strippedText, trimmedPrefix)
				}
			}
		}
		return nil
	}
	
	public func pipeline(for bundleIdentifier: String?) -> TextTransformationPipeline {
		stack(for: bundleIdentifier)?.pipeline ?? TextTransformationPipeline()
	}
	
	public func provider(with id: String) -> LLMProvider? {
		providers.first(where: { $0.id == id })
	}
	
	public mutating func updateStack(id: UUID, mutate: (inout TransformationStack) -> Void) {
		guard let idx = stacks.firstIndex(where: { $0.id == id }) else { return }
		mutate(&stacks[idx])
	}
	
	public mutating func addStack(named name: String) -> TransformationStack {
		let stack = TransformationStack(name: name, pipeline: .init())
		stacks.append(stack)
		return stack
	}
	
	public mutating func removeStack(id: UUID) {
		stacks.removeAll { $0.id == id }
		if lastSelectedStackID == id {
			lastSelectedStackID = fallbackStackID(in: stacks)
		}
	}
	
	private func fallbackStackID(in stacks: [TransformationStack]) -> UUID? {
		stacks.first(where: { $0.appliesToBundleIdentifiers.isEmpty })?.id ?? stacks.first?.id
	}
}
