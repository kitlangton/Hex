//
//  ModeSettingsView.swift
//  Hex
//
//  Settings section for selecting operation mode (Transcription vs Conversation).
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// A settings section for selecting between Transcription and Conversation modes.
///
/// When Conversation mode is selected, additional settings are shown for:
/// - Persona selection and management
/// - Conversation-specific hotkey
/// - Model status and download
struct ModeSettingsView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Section {
            // Mode picker
            modePickerRow

            // Mode-specific settings
            if store.hexSettings.operationMode == .conversation {
                conversationSettings
            }
        } header: {
            Text("Operation Mode")
        } footer: {
            Text(store.hexSettings.operationMode.description)
                .settingsCaption()
        }
        .enableInjection()
    }

    // MARK: - Mode Picker

    @ViewBuilder
    private var modePickerRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(OperationMode.allCases, id: \.self) { mode in
                ModeOptionRow(
                    mode: mode,
                    isSelected: store.hexSettings.operationMode == mode,
                    action: {
                        store.send(.setOperationMode(mode))
                    }
                )
            }
        }
    }

    // MARK: - Conversation Settings

    @ViewBuilder
    private var conversationSettings: some View {
        Divider()
            .padding(.vertical, 4)

        // Persona selection
        personaSection

        // Conversation hotkey
        hotkeySection

        // Model status (placeholder for future implementation)
        modelStatusSection
    }

    @ViewBuilder
    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                HStack {
                    Text("Active Persona")
                    Spacer()
                    Menu {
                        ForEach(store.conversationPersonas) { persona in
                            Button {
                                store.send(.selectConversationPersona(persona.id))
                            } label: {
                                HStack {
                                    Text(persona.name)
                                    if store.selectedConversationPersonaID == persona.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            store.send(.showPersonaEditor)
                        } label: {
                            Label("Manage Personas...", systemImage: "gear")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedPersonaName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            } icon: {
                Image(systemName: "person.wave.2")
            }

            // Persona description preview
            if let persona = selectedPersona, let prompt = persona.textPrompt {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private var hotkeySection: some View {
        Label {
            HStack {
                Text("Conversation Hotkey")
                Spacer()
                Text("Same as Transcription")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: "keyboard")
        }
        .help("Conversation mode uses the same hotkey as transcription mode. The active mode determines the behavior.")
    }

    @ViewBuilder
    private var modelStatusSection: some View {
        Label {
            HStack {
                Text("PersonaPlex Model")
                Spacer()
                modelStatusBadge
            }
        } icon: {
            Image(systemName: "cpu")
        }
    }

    @ViewBuilder
    private var modelStatusBadge: some View {
        // TODO: Connect to actual model status from ConversationFeature
        HStack(spacing: 4) {
            Circle()
                .fill(Color.yellow)
                .frame(width: 8, height: 8)
            Text("Not Available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.yellow.opacity(0.1))
        )
    }

    // MARK: - Helpers

    private var selectedPersona: PersonaConfig? {
        store.conversationPersonas.first { $0.id == store.selectedConversationPersonaID }
    }

    private var selectedPersonaName: String {
        selectedPersona?.name ?? "None"
    }
}

// MARK: - Mode Option Row

private struct ModeOptionRow: View {
    let mode: OperationMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Radio button
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.body)

                // Mode icon
                Image(systemName: mode.icon)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 20)

                // Mode info
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Status indicator for conversation mode
                if mode == .conversation {
                    Text("Beta")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.15))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Conversation Settings Section (Expanded)

/// A detailed conversation settings section for use in a dedicated settings panel
struct ConversationSettingsSectionView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Section {
            // Persona management
            personaManagementRow

            // Voice output device
            outputDeviceRow

            // Quantization setting
            quantizationRow
        } header: {
            Text("Conversation Settings")
        }
        .enableInjection()
    }

    @ViewBuilder
    private var personaManagementRow: some View {
        Label {
            HStack {
                Text("Personas")
                Spacer()
                Button("Manage...") {
                    store.send(.showPersonaEditor)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } icon: {
            Image(systemName: "person.3")
        }
    }

    @ViewBuilder
    private var outputDeviceRow: some View {
        Label {
            HStack {
                Text("Output Device")
                Spacer()
                Picker("", selection: .constant("default")) {
                    Text("System Default").tag("default")
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }
        } icon: {
            Image(systemName: "speaker.wave.2")
        }
    }

    @ViewBuilder
    private var quantizationRow: some View {
        Label {
            HStack {
                Text("Model Quantization")
                Spacer()
                Picker("", selection: .constant(4)) {
                    Text("4-bit (Recommended)").tag(4)
                    Text("8-bit (Higher Quality)").tag(8)
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }
        } icon: {
            Image(systemName: "square.grid.3x3")
        }
        .help("4-bit quantization uses less memory. 8-bit provides higher quality but requires more RAM.")
    }
}

// MARK: - Previews

#Preview("Mode Settings - Transcription") {
    Form {
        ModeSettingsView(
            store: Store(
                initialState: SettingsFeature.State()
            ) {
                SettingsFeature()
            }
        )
    }
    .formStyle(.grouped)
    .frame(width: 500, height: 400)
}

#Preview("Mode Option Rows") {
    VStack(spacing: 8) {
        ModeOptionRow(
            mode: .transcription,
            isSelected: true,
            action: {}
        )

        ModeOptionRow(
            mode: .conversation,
            isSelected: false,
            action: {}
        )
    }
    .padding()
    .frame(width: 400)
}
