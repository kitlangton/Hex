//
//  ConversationModels.swift
//  Hex
//
//  Models for Conversation Mode integration with PersonaPlex

import Foundation
import HexCore

// Re-export OperationMode from HexCore for convenience
public typealias OperationMode = HexCore.OperationMode

// MARK: - Conversation Model Type

/// Available conversation model types
public enum ConversationModelType: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case moshi
    case personaPlex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .moshi:
            return "Moshi"
        case .personaPlex:
            return "PersonaPlex"
        }
    }

    public var description: String {
        switch self {
        case .moshi:
            return "Full-duplex voice AI powered by Kyutai"
        case .personaPlex:
            return "Multi-voice AI with 18 voice presets"
        }
    }

    /// HuggingFace model identifiers
    public var modelIdentifiers: [String] {
        switch self {
        case .moshi:
            return ["kyutai/moshiko-mlx-bf16", "kyutai/mimi"]
        case .personaPlex:
            return ["eastlondoner/personaplex-mlx"]
        }
    }

    /// Primary identifier for display purposes
    public var primaryIdentifier: String {
        modelIdentifiers.first ?? ""
    }

    /// Estimated total download size
    public var estimatedSize: String {
        switch self {
        case .moshi:
            return "~15.8 GB"
        case .personaPlex:
            return "~17.1 GB"
        }
    }

    /// Icon for the model
    public var icon: String {
        switch self {
        case .moshi:
            return "waveform.circle.fill"
        case .personaPlex:
            return "person.3.fill"
        }
    }

    /// Color for the model
    public var color: String {
        switch self {
        case .moshi:
            return "purple"
        case .personaPlex:
            return "blue"
        }
    }

    /// Whether this model supports voice presets
    public var supportsVoicePresets: Bool {
        switch self {
        case .moshi:
            return false
        case .personaPlex:
            return true
        }
    }
}

// Backward compatibility alias
public typealias ConversationSessionState = ConversationState

// MARK: - Conversation State

/// Represents the current state of a conversation session
public enum ConversationState: Equatable, Sendable {
    case idle
    case loading(progress: Double)
    case ready
    case active(speaking: Bool, listening: Bool)
    case error(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .idle:
            return "Press hotkey to start conversation"
        case .loading(let progress):
            return "Loading model... \(Int(progress * 100))%"
        case .ready:
            return "Ready"
        case .active(let speaking, let listening):
            if speaking && listening {
                return "Conversing"
            } else if speaking {
                return "Speaking"
            } else if listening {
                return "Listening"
            } else {
                return "Active"
            }
        case .error(let message):
            return message
        }
    }
}

// MARK: - Persona Configuration

/// Configuration for a conversation persona
public struct PersonaConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var textPrompt: String?
    public var voicePreset: String?
    public var voiceEmbeddingPath: URL?

    public init(
        id: UUID = UUID(),
        name: String,
        textPrompt: String? = nil,
        voicePreset: String? = nil,
        voiceEmbeddingPath: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.textPrompt = textPrompt
        self.voicePreset = voicePreset
        self.voiceEmbeddingPath = voiceEmbeddingPath
    }

    /// Default persona for new users
    public static let `default` = PersonaConfig(
        name: "Assistant",
        textPrompt: "You are a helpful assistant who speaks concisely and clearly.",
        voicePreset: "NATF0"
    )
}

// MARK: - Voice Presets

/// Available voice presets from PersonaPlex
public struct VoicePreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var gender: Gender
    public var style: Style

    public enum Gender: String, Codable, CaseIterable, Sendable {
        case female
        case male

        var displayName: String {
            switch self {
            case .female: return "Female"
            case .male: return "Male"
            }
        }
    }

    public enum Style: String, Codable, CaseIterable, Sendable {
        case natural
        case variable

        var displayName: String {
            switch self {
            case .natural: return "Natural"
            case .variable: return "Variable"
            }
        }
    }

    public init(id: String, name: String, gender: Gender, style: Style) {
        self.id = id
        self.name = name
        self.gender = gender
        self.style = style
    }

    /// All 18 available voice presets
    public static let allPresets: [VoicePreset] = [
        // Natural Female (4 presets)
        VoicePreset(id: "NATF0", name: "Natural Female 1", gender: .female, style: .natural),
        VoicePreset(id: "NATF1", name: "Natural Female 2", gender: .female, style: .natural),
        VoicePreset(id: "NATF2", name: "Natural Female 3", gender: .female, style: .natural),
        VoicePreset(id: "NATF3", name: "Natural Female 4", gender: .female, style: .natural),

        // Natural Male (4 presets)
        VoicePreset(id: "NATM0", name: "Natural Male 1", gender: .male, style: .natural),
        VoicePreset(id: "NATM1", name: "Natural Male 2", gender: .male, style: .natural),
        VoicePreset(id: "NATM2", name: "Natural Male 3", gender: .male, style: .natural),
        VoicePreset(id: "NATM3", name: "Natural Male 4", gender: .male, style: .natural),

        // Variable Female (5 presets)
        VoicePreset(id: "VARF0", name: "Variable Female 1", gender: .female, style: .variable),
        VoicePreset(id: "VARF1", name: "Variable Female 2", gender: .female, style: .variable),
        VoicePreset(id: "VARF2", name: "Variable Female 3", gender: .female, style: .variable),
        VoicePreset(id: "VARF3", name: "Variable Female 4", gender: .female, style: .variable),
        VoicePreset(id: "VARF4", name: "Variable Female 5", gender: .female, style: .variable),

        // Variable Male (5 presets)
        VoicePreset(id: "VARM0", name: "Variable Male 1", gender: .male, style: .variable),
        VoicePreset(id: "VARM1", name: "Variable Male 2", gender: .male, style: .variable),
        VoicePreset(id: "VARM2", name: "Variable Male 3", gender: .male, style: .variable),
        VoicePreset(id: "VARM3", name: "Variable Male 4", gender: .male, style: .variable),
        VoicePreset(id: "VARM4", name: "Variable Male 5", gender: .male, style: .variable),
    ]

    /// Returns presets filtered by gender
    public static func presets(for gender: Gender) -> [VoicePreset] {
        allPresets.filter { $0.gender == gender }
    }

    /// Returns presets filtered by style
    public static func presets(for style: Style) -> [VoicePreset] {
        allPresets.filter { $0.style == style }
    }

    /// Finds a preset by ID
    public static func preset(withID id: String) -> VoicePreset? {
        allPresets.first { $0.id == id }
    }
}

// MARK: - Conversation History

/// A single turn in a conversation
public struct ConversationTurn: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var speaker: Speaker
    public var text: String

    public enum Speaker: String, Codable, Sendable {
        case user
        case assistant
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        speaker: Speaker,
        text: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - Conversation Configuration

/// Configuration for starting a conversation session
public struct ConversationConfig: Codable, Equatable, Sendable {
    public var persona: PersonaConfig
    public var inputDeviceID: String?
    public var outputDeviceID: String?
    public var quantization: Int

    public init(
        persona: PersonaConfig,
        inputDeviceID: String? = nil,
        outputDeviceID: String? = nil,
        quantization: Int = 4
    ) {
        self.persona = persona
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        self.quantization = quantization
    }
}
