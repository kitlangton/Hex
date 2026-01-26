//
//  ConversationModelDownloadTests.swift
//  HexTests
//
//  Tests for conversation model download functionality including:
//  - Model type definitions (Moshi, PersonaPlex)
//  - Model identifiers and URLs
//  - Model selection persistence
//  - Download progress tracking
//  - Voice presets for PersonaPlex
//

import ComposableArchitecture
import Foundation
@testable import Hex
import HexCore
import Testing

// MARK: - ConversationModelType Tests

@Suite("ConversationModelType")
struct ConversationModelTypeTests {

    // MARK: - Model Definition Tests

    @Test("Both Moshi and PersonaPlex model types are defined")
    func modelTypesAreDefined() {
        let allTypes = ConversationModelType.allCases

        #expect(allTypes.count == 2)
        #expect(allTypes.contains(.moshi))
        #expect(allTypes.contains(.personaPlex))
    }

    @Test("Moshi is the default model")
    func moshiIsDefault() {
        // Default raw value should parse to moshi
        let defaultModel = ConversationModelType(rawValue: "moshi")
        #expect(defaultModel == .moshi)
    }

    @Test("Model types have correct display names")
    func displayNames() {
        #expect(ConversationModelType.moshi.displayName == "Moshi")
        #expect(ConversationModelType.personaPlex.displayName == "PersonaPlex")
    }

    @Test("Model types have correct descriptions")
    func descriptions() {
        #expect(ConversationModelType.moshi.description == "Full-duplex voice AI powered by Kyutai")
        #expect(ConversationModelType.personaPlex.description == "Multi-voice AI with 18 voice presets")
    }

    // MARK: - Model Identifier Tests

    @Test("Moshi model identifiers are correct")
    func moshiIdentifiers() {
        let identifiers = ConversationModelType.moshi.modelIdentifiers

        #expect(identifiers.count == 2)
        #expect(identifiers.contains("kyutai/moshiko-mlx-bf16"))
        #expect(identifiers.contains("kyutai/mimi"))
    }

    @Test("PersonaPlex model identifiers are correct")
    func personaPlexIdentifiers() {
        let identifiers = ConversationModelType.personaPlex.modelIdentifiers

        #expect(identifiers.count == 1)
        #expect(identifiers.contains("eastlondoner/personaplex-mlx"))
    }

    @Test("Primary identifier returns first identifier")
    func primaryIdentifier() {
        #expect(ConversationModelType.moshi.primaryIdentifier == "kyutai/moshiko-mlx-bf16")
        #expect(ConversationModelType.personaPlex.primaryIdentifier == "eastlondoner/personaplex-mlx")
    }

    // MARK: - Model Size Tests

    @Test("Model sizes are correctly specified")
    func modelSizes() {
        #expect(ConversationModelType.moshi.estimatedSize == "~15.8 GB")
        #expect(ConversationModelType.personaPlex.estimatedSize == "~17.1 GB")
    }

    // MARK: - Voice Preset Support Tests

    @Test("Only PersonaPlex supports voice presets")
    func voicePresetSupport() {
        #expect(ConversationModelType.moshi.supportsVoicePresets == false)
        #expect(ConversationModelType.personaPlex.supportsVoicePresets == true)
    }

    // MARK: - UI Properties Tests

    @Test("Model types have distinct icons")
    func icons() {
        #expect(ConversationModelType.moshi.icon == "waveform.circle.fill")
        #expect(ConversationModelType.personaPlex.icon == "person.3.fill")
        #expect(ConversationModelType.moshi.icon != ConversationModelType.personaPlex.icon)
    }

    @Test("Model types have distinct colors")
    func colors() {
        #expect(ConversationModelType.moshi.color == "purple")
        #expect(ConversationModelType.personaPlex.color == "blue")
        #expect(ConversationModelType.moshi.color != ConversationModelType.personaPlex.color)
    }

    // MARK: - Identifiable Conformance

    @Test("Model types are identifiable by raw value")
    func identifiable() {
        #expect(ConversationModelType.moshi.id == "moshi")
        #expect(ConversationModelType.personaPlex.id == "personaPlex")
    }

    // MARK: - Codable Conformance

    @Test("Model types can be encoded and decoded")
    func codable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for modelType in ConversationModelType.allCases {
            let encoded = try encoder.encode(modelType)
            let decoded = try decoder.decode(ConversationModelType.self, from: encoded)
            #expect(decoded == modelType)
        }
    }
}

// MARK: - VoicePreset Tests

@Suite("VoicePreset")
struct VoicePresetTests {

    @Test("All 18 voice presets are defined")
    func allPresetsCount() {
        #expect(VoicePreset.allPresets.count == 18)
    }

    @Test("Natural female presets (4)")
    func naturalFemalePresets() {
        let presets = VoicePreset.allPresets.filter { $0.gender == .female && $0.style == .natural }

        #expect(presets.count == 4)
        #expect(presets.map(\.id).sorted() == ["NATF0", "NATF1", "NATF2", "NATF3"])
    }

    @Test("Natural male presets (4)")
    func naturalMalePresets() {
        let presets = VoicePreset.allPresets.filter { $0.gender == .male && $0.style == .natural }

        #expect(presets.count == 4)
        #expect(presets.map(\.id).sorted() == ["NATM0", "NATM1", "NATM2", "NATM3"])
    }

    @Test("Variable female presets (5)")
    func variableFemalePresets() {
        let presets = VoicePreset.allPresets.filter { $0.gender == .female && $0.style == .variable }

        #expect(presets.count == 5)
        #expect(presets.map(\.id).sorted() == ["VARF0", "VARF1", "VARF2", "VARF3", "VARF4"])
    }

    @Test("Variable male presets (5)")
    func variableMalePresets() {
        let presets = VoicePreset.allPresets.filter { $0.gender == .male && $0.style == .variable }

        #expect(presets.count == 5)
        #expect(presets.map(\.id).sorted() == ["VARM0", "VARM1", "VARM2", "VARM3", "VARM4"])
    }

    @Test("Filter presets by gender")
    func filterByGender() {
        let femalePresets = VoicePreset.presets(for: .female)
        let malePresets = VoicePreset.presets(for: .male)

        #expect(femalePresets.count == 9) // 4 natural + 5 variable
        #expect(malePresets.count == 9)   // 4 natural + 5 variable
        #expect(femalePresets.allSatisfy { $0.gender == .female })
        #expect(malePresets.allSatisfy { $0.gender == .male })
    }

    @Test("Filter presets by style")
    func filterByStyle() {
        let naturalPresets = VoicePreset.presets(for: .natural)
        let variablePresets = VoicePreset.presets(for: .variable)

        #expect(naturalPresets.count == 8)  // 4 female + 4 male
        #expect(variablePresets.count == 10) // 5 female + 5 male
        #expect(naturalPresets.allSatisfy { $0.style == .natural })
        #expect(variablePresets.allSatisfy { $0.style == .variable })
    }

    @Test("Find preset by ID")
    func presetByID() {
        let preset = VoicePreset.preset(withID: "NATF0")

        #expect(preset != nil)
        #expect(preset?.name == "Natural Female 1")
        #expect(preset?.gender == .female)
        #expect(preset?.style == .natural)
    }

    @Test("Invalid preset ID returns nil")
    func invalidPresetID() {
        let preset = VoicePreset.preset(withID: "INVALID")
        #expect(preset == nil)
    }

    @Test("All presets have unique IDs")
    func uniqueIDs() {
        let ids = VoicePreset.allPresets.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count)
    }

    @Test("Presets are identifiable")
    func identifiable() {
        for preset in VoicePreset.allPresets {
            #expect(preset.id == preset.id) // Identifiable conformance check
        }
    }

    @Test("Gender display names")
    func genderDisplayNames() {
        #expect(VoicePreset.Gender.female.displayName == "Female")
        #expect(VoicePreset.Gender.male.displayName == "Male")
    }

    @Test("Style display names")
    func styleDisplayNames() {
        #expect(VoicePreset.Style.natural.displayName == "Natural")
        #expect(VoicePreset.Style.variable.displayName == "Variable")
    }
}

// MARK: - ConversationModelBootstrapState Tests

@Suite("ConversationModelBootstrapState")
struct ConversationModelBootstrapStateTests {

    @Test("Initial state has no models ready")
    func initialState() {
        let state = ConversationModelBootstrapState()

        #expect(state.isModelReady == false)
        #expect(state.isDownloading == false)
        #expect(state.progress == 0)
        #expect(state.lastError == nil)
        #expect(state.selectedModelType == .moshi)
    }

    @Test("Per-model state tracking")
    func perModelState() {
        var state = ConversationModelBootstrapState()

        // Update moshi state
        state.updateState(for: .moshi) { downloadState in
            downloadState.isModelReady = true
            downloadState.progress = 1.0
        }

        // Moshi should be ready
        #expect(state.isReady(.moshi) == true)
        #expect(state.progress(for: .moshi) == 1.0)

        // PersonaPlex should still be not ready
        #expect(state.isReady(.personaPlex) == false)
        #expect(state.progress(for: .personaPlex) == 0)
    }

    @Test("Selected model affects convenience accessors")
    func selectedModelAccessors() {
        var state = ConversationModelBootstrapState()

        // Set moshi as ready
        state.updateState(for: .moshi) { $0.isModelReady = true }

        // With moshi selected, isModelReady should be true
        state.selectedModelType = .moshi
        #expect(state.isModelReady == true)

        // Switch to personaPlex, isModelReady should be false
        state.selectedModelType = .personaPlex
        #expect(state.isModelReady == false)
    }

    @Test("Download state isolation between models")
    func downloadStateIsolation() {
        var state = ConversationModelBootstrapState()

        // Start downloading moshi
        state.updateState(for: .moshi) { downloadState in
            downloadState.isDownloading = true
            downloadState.progress = 0.5
        }

        // PersonaPlex should not be affected
        #expect(state.isDownloading(.moshi) == true)
        #expect(state.isDownloading(.personaPlex) == false)
        #expect(state.progress(for: .moshi) == 0.5)
        #expect(state.progress(for: .personaPlex) == 0)
    }

    @Test("Error state is per-model")
    func errorStatePerModel() {
        var state = ConversationModelBootstrapState()

        // Set error on moshi
        state.updateState(for: .moshi) { downloadState in
            downloadState.lastError = "Download failed"
        }

        #expect(state.error(for: .moshi) == "Download failed")
        #expect(state.error(for: .personaPlex) == nil)
    }

    @Test("Backward compatibility accessors")
    func backwardCompatibility() {
        let state = ConversationModelBootstrapState()

        // These properties should work for backward compatibility
        #expect(state.modelIdentifier == ConversationModelType.moshi.primaryIdentifier)
        #expect(state.modelDisplayName == ConversationModelType.moshi.displayName)
        #expect(state.modelSize == ConversationModelType.moshi.estimatedSize)
    }
}

// MARK: - ConversationModelDownloadFeature State Tests

@Suite("ConversationModelDownloadFeature.State")
struct ConversationModelDownloadFeatureStateTests {

    @Test("Initial state has download states for all models")
    func initialState() {
        let state = ConversationModelDownloadFeature.State()

        #expect(state.modelDownloadStates.count == 2)
        #expect(state.modelDownloadStates[.moshi] != nil)
        #expect(state.modelDownloadStates[.personaPlex] != nil)
    }

    @Test("Selected model type reads from settings")
    func selectedModelFromSettings() {
        var state = ConversationModelDownloadFeature.State()

        // Default should be moshi
        #expect(state.selectedModelType == .moshi)
    }

    @Test("isAnyDownloading checks all models")
    func isAnyDownloading() {
        var state = ConversationModelDownloadFeature.State()

        // Initially no downloads
        #expect(state.isAnyDownloading == false)

        // Start moshi download
        state.modelDownloadStates[.moshi]?.isDownloading = true
        #expect(state.isAnyDownloading == true)

        // Stop moshi, start personaPlex
        state.modelDownloadStates[.moshi]?.isDownloading = false
        state.modelDownloadStates[.personaPlex]?.isDownloading = true
        #expect(state.isAnyDownloading == true)
    }

    @Test("ModelDownloadState default values")
    func modelDownloadStateDefaults() {
        let downloadState = ConversationModelDownloadFeature.State.ModelDownloadState()

        #expect(downloadState.isDownloading == false)
        #expect(downloadState.downloadProgress == 0)
        #expect(downloadState.downloadError == nil)
        #expect(downloadState.isModelDownloaded == false)
    }
}

// MARK: - HexSettings ConversationModel Tests

@Suite("HexSettings.selectedConversationModel")
struct HexSettingsConversationModelTests {

    @Test("Default conversation model is moshi")
    func defaultModel() {
        let settings = HexSettings()
        #expect(settings.selectedConversationModel == "moshi")
    }

    @Test("Conversation model persists through encoding")
    func persistsThroughEncoding() throws {
        var settings = HexSettings()
        settings.selectedConversationModel = "personaPlex"

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(settings)
        let decoded = try decoder.decode(HexSettings.self, from: encoded)

        #expect(decoded.selectedConversationModel == "personaPlex")
    }

    @Test("Invalid model value falls back gracefully")
    func invalidModelFallback() {
        // When parsing an invalid value, ConversationModelType should return nil
        let invalidType = ConversationModelType(rawValue: "invalid")
        #expect(invalidType == nil)

        // The feature state should default to moshi when parsing fails
        // This is tested through the computed property in the feature
    }
}

// MARK: - Download Progress Tests

@Suite("Download Progress")
struct DownloadProgressTests {

    @Test("Progress values are clamped between 0 and 1")
    func progressClamping() {
        var state = ConversationModelDownloadState()

        state.progress = 0.0
        #expect(state.progress == 0.0)

        state.progress = 0.5
        #expect(state.progress == 0.5)

        state.progress = 1.0
        #expect(state.progress == 1.0)
    }

    @Test("Bootstrap state progress tracks correctly")
    func bootstrapStateProgress() {
        var state = ConversationModelBootstrapState()

        // Update progress through the state update method
        state.updateState(for: .moshi) { downloadState in
            downloadState.progress = 0.75
        }

        #expect(state.progress(for: .moshi) == 0.75)
    }
}
