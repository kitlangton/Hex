import Foundation

// MARK: - Transformation Types

public enum TransformationType: Codable, Equatable, Sendable {
	case uppercase
	case lowercase
	case capitalize
	case capitalizeFirst
	case spongebobCase
	case trimWhitespace
	case removeExtraSpaces
	case replaceText(ReplaceTextConfig)
	case addPrefix(String)
	case addSuffix(String)
}

public struct ReplaceTextConfig: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var pattern: String
	public var replacement: String
	public var caseSensitive: Bool
	public var useRegex: Bool
	
	public init(
		id: UUID = UUID(),
		pattern: String,
		replacement: String,
		caseSensitive: Bool = false,
		useRegex: Bool = false
	) {
		self.id = id
		self.pattern = pattern
		self.replacement = replacement
		self.caseSensitive = caseSensitive
		self.useRegex = useRegex
	}
}

// MARK: - Transformation

public struct Transformation: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var isEnabled: Bool
	public var type: TransformationType
	
	public init(id: UUID = UUID(), isEnabled: Bool = true, type: TransformationType) {
		self.id = id
		self.isEnabled = isEnabled
		self.type = type
	}
	
	public var name: String {
		switch type {
		case .uppercase: return "UPPERCASE"
		case .lowercase: return "lowercase"
		case .capitalize: return "Title Case"
		case .capitalizeFirst: return "Capitalize first"
		case .spongebobCase: return "sPoNgEbOb cAsE"
		case .trimWhitespace: return "Trim whitespace"
		case .removeExtraSpaces: return "Remove extra spaces"
		case .replaceText(let config): return "Replace: \(config.pattern)"
		case .addPrefix(let prefix): return "Prefix: \(prefix)"
		case .addSuffix(let suffix): return "Suffix: \(suffix)"
		}
	}
	
	public func transform(_ text: String) async -> String {
		guard isEnabled else { return text }
		
		switch type {
		case .uppercase:
			return text.uppercased()
			
		case .lowercase:
			return text.lowercased()
			
		case .capitalize:
			return text.capitalized
			
		case .capitalizeFirst:
			guard !text.isEmpty else { return text }
			return text.prefix(1).uppercased() + text.dropFirst()
			
		case .spongebobCase:
			return text.enumerated().map { index, char in
				index % 2 == 0 ? String(char).lowercased() : String(char).uppercased()
			}.joined()
			
		case .trimWhitespace:
			return text.trimmingCharacters(in: .whitespacesAndNewlines)
			
		case .removeExtraSpaces:
			return text.replacingOccurrences(
				of: "\\s+",
				with: " ",
				options: .regularExpression
			)
			
		case .replaceText(let config):
			return applyReplacement(text, config: config)
			
		case .addPrefix(let prefix):
			return prefix + text
			
		case .addSuffix(let suffix):
			return text + suffix
		}
	}
	
	private func applyReplacement(_ text: String, config: ReplaceTextConfig) -> String {
		if config.useRegex {
			let options: String.CompareOptions = config.caseSensitive 
				? .regularExpression 
				: [.regularExpression, .caseInsensitive]
			return text.replacingOccurrences(
				of: config.pattern,
				with: config.replacement,
				options: options
			)
		} else {
			let options: String.CompareOptions = config.caseSensitive ? [] : .caseInsensitive
			return text.replacingOccurrences(
				of: config.pattern,
				with: config.replacement,
				options: options
			)
		}
	}
}

// MARK: - Codable for TransformationType

extension TransformationType {
	private enum CodingKeys: String, CodingKey {
		case uppercase, lowercase, capitalize, capitalizeFirst
		case spongebobCase, trimWhitespace, removeExtraSpaces
		case replaceText, addPrefix, addSuffix
	}
	
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .uppercase:
			try container.encode(true, forKey: .uppercase)
		case .lowercase:
			try container.encode(true, forKey: .lowercase)
		case .capitalize:
			try container.encode(true, forKey: .capitalize)
		case .capitalizeFirst:
			try container.encode(true, forKey: .capitalizeFirst)
		case .spongebobCase:
			try container.encode(true, forKey: .spongebobCase)
		case .trimWhitespace:
			try container.encode(true, forKey: .trimWhitespace)
		case .removeExtraSpaces:
			try container.encode(true, forKey: .removeExtraSpaces)
		case .replaceText(let config):
			try container.encode(config, forKey: .replaceText)
		case .addPrefix(let prefix):
			try container.encode(prefix, forKey: .addPrefix)
		case .addSuffix(let suffix):
			try container.encode(suffix, forKey: .addSuffix)
		}
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		
		if container.contains(.uppercase) {
			self = .uppercase
		} else if container.contains(.lowercase) {
			self = .lowercase
		} else if container.contains(.capitalize) {
			self = .capitalize
		} else if container.contains(.capitalizeFirst) {
			self = .capitalizeFirst
		} else if container.contains(.spongebobCase) {
			self = .spongebobCase
		} else if container.contains(.trimWhitespace) {
			self = .trimWhitespace
		} else if container.contains(.removeExtraSpaces) {
			self = .removeExtraSpaces
		} else if let config = try? container.decode(ReplaceTextConfig.self, forKey: .replaceText) {
			self = .replaceText(config)
		} else if let prefix = try? container.decode(String.self, forKey: .addPrefix) {
			self = .addPrefix(prefix)
		} else if let suffix = try? container.decode(String.self, forKey: .addSuffix) {
			self = .addSuffix(suffix)
		} else {
			throw DecodingError.dataCorrupted(
				DecodingError.Context(
					codingPath: decoder.codingPath,
					debugDescription: "Unknown transformation type"
				)
			)
		}
	}
}
