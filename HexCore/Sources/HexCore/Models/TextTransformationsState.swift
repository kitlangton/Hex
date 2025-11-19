import Foundation

public struct TransformationMode: Codable, Equatable, Identifiable, Sendable {
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
	public var modes: [TransformationMode]
	public var providers: [LLMProvider]
	public var lastSelectedModeID: UUID?
	
	public init(
		modes: [TransformationMode] = [],
		providers: [LLMProvider] = [],
		lastSelectedModeID: UUID? = nil,
		schemaVersion: Int = TextTransformationsState.currentSchemaVersion
	) {
		let resolvedModes = modes.isEmpty ? [TransformationMode(name: "General", pipeline: .init())] : modes
		self.modes = resolvedModes
		self.providers = providers
		self.schemaVersion = schemaVersion
		self.lastSelectedModeID = lastSelectedModeID ?? fallbackModeID(in: resolvedModes)
	}
	
	private enum CodingKeys: String, CodingKey {
		case schemaVersion
		case modes
		case stacks // legacy
		case providers
		case lastSelectedModeID
		case lastSelectedStackID // legacy
		case pipeline // legacy
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
		let modes: [TransformationMode]
		if version < 2 {
			let legacyPipeline = try container.decodeIfPresent(TextTransformationPipeline.self, forKey: .pipeline) ?? .init()
			modes = [TransformationMode(name: "General", pipeline: legacyPipeline)]
		} else {
			// Support both old "stacks" and new "modes" keys
			if let decodedModes = try container.decodeIfPresent([TransformationMode].self, forKey: .modes) {
				modes = decodedModes
			} else {
				modes = try container.decodeIfPresent([TransformationMode].self, forKey: .stacks) ?? []
			}
		}
		let providers: [LLMProvider] = version >= 3 ? (try container.decodeIfPresent([LLMProvider].self, forKey: .providers) ?? []) : []
		// Support both old and new selected ID keys
		let selected = try container.decodeIfPresent(UUID.self, forKey: .lastSelectedModeID) ?? container.decodeIfPresent(UUID.self, forKey: .lastSelectedStackID)
		self.init(modes: modes, providers: providers, lastSelectedModeID: selected, schemaVersion: max(version, TextTransformationsState.currentSchemaVersion))
	}
	
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(TextTransformationsState.currentSchemaVersion, forKey: .schemaVersion)
		try container.encode(modes, forKey: .modes)
		try container.encode(providers, forKey: .providers)
		try container.encodeIfPresent(lastSelectedModeID, forKey: .lastSelectedModeID)
	}
	
	public func mode(with id: UUID?) -> TransformationMode? {
		guard let id else { return nil }
		return modes.first(where: { $0.id == id })
	}
	
	public func orderedModes(for bundleIdentifier: String?) -> [TransformationMode] {
		let lowered = bundleIdentifier?.lowercased()
		let matching = modes.enumerated().compactMap { index, mode -> (TransformationMode, Int, Int)? in
			guard let lowered else { return nil }
			let matches = mode.appliesToBundleIdentifiers.filter { $0.lowercased() == lowered }.count
			return matches > 0 ? (mode, matches, index) : nil
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
		let general = modes.filter { $0.appliesToBundleIdentifiers.isEmpty }
		return general.isEmpty ? modes : general
	}
	
	public func mode(for bundleIdentifier: String?) -> TransformationMode? {
		orderedModes(for: bundleIdentifier).first
	}
	
	/// Returns mode and stripped text if voice prefix matches
	public func modeByVoicePrefix(text: String) -> (mode: TransformationMode, strippedText: String, matchedPrefix: String)? {
		for mode in modes {
			for prefix in mode.voicePrefixes {
				let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !trimmedPrefix.isEmpty else { continue }

				// Check if text starts with prefix (case-insensitive)
				// Match prefix followed by punctuation and/or whitespace, or end of string
				let pattern = "^\\s*\(NSRegularExpression.escapedPattern(for: trimmedPrefix))(?:[.,;:!?\\s]+|$)"
				if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
				   let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
					let matchRange = Range(match.range, in: text)!
					let strippedText = String(text[matchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
					return (mode, strippedText, trimmedPrefix)
				}
			}
		}
		return nil
	}
	
	public func pipeline(for bundleIdentifier: String?) -> TextTransformationPipeline {
		mode(for: bundleIdentifier)?.pipeline ?? TextTransformationPipeline()
	}
	
	public func provider(with id: String) -> LLMProvider? {
		providers.first(where: { $0.id == id })
	}
	
	public mutating func updateMode(id: UUID, mutate: (inout TransformationMode) -> Void) {
		guard let idx = modes.firstIndex(where: { $0.id == id }) else { return }
		mutate(&modes[idx])
	}
	
	public mutating func addMode(named name: String) -> TransformationMode {
		let mode = TransformationMode(name: name, pipeline: .init())
		modes.append(mode)
		return mode
	}
	
	public mutating func removeMode(id: UUID) {
		modes.removeAll { $0.id == id }
		if lastSelectedModeID == id {
			lastSelectedModeID = fallbackModeID(in: modes)
		}
	}
	
	private func fallbackModeID(in modes: [TransformationMode]) -> UUID? {
		modes.first(where: { $0.appliesToBundleIdentifiers.isEmpty })?.id ?? modes.first?.id
	}

    public struct ResolutionResult: Equatable {
        public var mode: TransformationMode?
        public var strippedText: String
        public var matchedPrefix: String?
        public var matchedBundleID: Bool
    }

    public func resolveMode(for text: String, bundleIdentifier: String?) -> ResolutionResult {
        // 1. Check voice prefix
        if let match = modeByVoicePrefix(text: text) {
            let prefixMode = match.mode
            var matchedBundleID = false
            
            if let bundleIdentifier,
               !prefixMode.appliesToBundleIdentifiers.isEmpty,
               prefixMode.appliesToBundleIdentifiers.contains(where: { $0.lowercased() == bundleIdentifier.lowercased() }) {
                matchedBundleID = true
            }
            
            return ResolutionResult(
                mode: prefixMode,
                strippedText: match.strippedText,
                matchedPrefix: match.matchedPrefix,
                matchedBundleID: matchedBundleID
            )
        }
        
        // 2. Fallback to Bundle ID match
        let mode = mode(for: bundleIdentifier)
        return ResolutionResult(
            mode: mode,
            strippedText: text,
            matchedPrefix: nil,
            matchedBundleID: mode != nil && !(mode?.appliesToBundleIdentifiers.isEmpty ?? true)
        )
    }
}
