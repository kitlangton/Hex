import Foundation

public enum CoachProvider: String, Codable, CaseIterable, Equatable, Sendable {
	case gemini
	case openai
}

/// HexCoach-specific settings nested into `HexSettings`.
public struct CoachSettings: Codable, Equatable, Sendable {
	public var enabled: Bool
	public var provider: CoachProvider
	public var thresholdSec: Int
	public var deleteAudioAfterAnalysis: Bool
	public var autoShowPopover: Bool
	public var customPromptTemplate: String?

	public init(
		enabled: Bool = false,
		provider: CoachProvider = .gemini,
		thresholdSec: Int = 10,
		deleteAudioAfterAnalysis: Bool = false,
		autoShowPopover: Bool = true,
		customPromptTemplate: String? = nil
	) {
		self.enabled = enabled
		self.provider = provider
		self.thresholdSec = max(3, min(120, thresholdSec))
		self.deleteAudioAfterAnalysis = deleteAudioAfterAnalysis
		self.autoShowPopover = autoShowPopover
		self.customPromptTemplate = customPromptTemplate
	}

	enum CodingKeys: String, CodingKey {
		case enabled
		case provider
		case thresholdSec
		case deleteAudioAfterAnalysis
		case autoShowPopover
		case customPromptTemplate
	}

	public init(from decoder: Decoder) throws {
		// Tolerate older saved settings that included l1Language, targetAccent,
		// userGoal, and customGuidance — we silently drop them now.
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
			provider: (try? c.decode(CoachProvider.self, forKey: .provider)) ?? .gemini,
			thresholdSec: (try? c.decode(Int.self, forKey: .thresholdSec)) ?? 10,
			deleteAudioAfterAnalysis: (try? c.decode(Bool.self, forKey: .deleteAudioAfterAnalysis)) ?? false,
			autoShowPopover: (try? c.decode(Bool.self, forKey: .autoShowPopover)) ?? true,
			customPromptTemplate: try? c.decodeIfPresent(String.self, forKey: .customPromptTemplate)
		)
	}
}
