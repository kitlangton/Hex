//
//  PersonaEditorView.swift
//  Hex
//
//  Form for creating and editing conversation personas.
//

import Inject
import SwiftUI

/// A form view for editing persona configuration.
///
/// Allows users to configure:
/// - Persona name
/// - System prompt / personality
/// - Voice preset selection
/// - Custom voice file (optional)
struct PersonaEditorView: View {
    @ObserveInjection var inject
    @Binding var persona: PersonaConfig
    @Environment(\.dismiss) private var dismiss

    /// Whether this is a new persona being created
    var isNew: Bool = false
    /// Callback when save is pressed
    var onSave: ((PersonaConfig) -> Void)?
    /// Callback when delete is pressed
    var onDelete: (() -> Void)?

    @State private var selectedGenderFilter: VoicePreset.Gender?
    @State private var showingVoiceFilePicker = false

    private var filteredVoicePresets: [VoicePreset] {
        if let gender = selectedGenderFilter {
            return VoicePreset.allPresets.filter { $0.gender == gender }
        }
        return VoicePreset.allPresets
    }

    var body: some View {
        Form {
            basicInfoSection
            promptSection
            voiceSection
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New Persona" : "Edit Persona")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Create" : "Save") {
                    onSave?(persona)
                    dismiss()
                }
                .disabled(persona.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .enableInjection()
    }

    // MARK: - Sections

    @ViewBuilder
    private var basicInfoSection: some View {
        Section {
            Label {
                TextField("Name", text: $persona.name)
                    .textFieldStyle(.roundedBorder)
            } icon: {
                Image(systemName: "person.fill")
            }
        } header: {
            Text("Basic Info")
        } footer: {
            Text("Give your persona a memorable name.")
                .settingsCaption()
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt")
                    .font(.body.weight(.medium))

                TextEditor(text: Binding(
                    get: { persona.textPrompt ?? "" },
                    set: { persona.textPrompt = $0.isEmpty ? nil : $0 }
                ))
                .font(.body)
                .frame(minHeight: 120, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
        } header: {
            Text("Personality")
        } footer: {
            Text("Describe how the AI should behave. For example: \"You are a friendly assistant who explains things simply.\"")
                .settingsCaption()
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            // Voice preset picker
            VStack(alignment: .leading, spacing: 12) {
                // Gender filter
                HStack {
                    Text("Filter by")
                        .foregroundStyle(.secondary)
                    Picker("Gender", selection: $selectedGenderFilter) {
                        Text("All").tag(VoicePreset.Gender?.none)
                        Text("Female").tag(VoicePreset.Gender?.some(.female))
                        Text("Male").tag(VoicePreset.Gender?.some(.male))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                // Voice preset grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    // Default option
                    VoicePresetCard(
                        preset: nil,
                        isSelected: persona.voicePreset == nil,
                        action: { persona.voicePreset = nil }
                    )

                    ForEach(filteredVoicePresets) { preset in
                        VoicePresetCard(
                            preset: preset,
                            isSelected: persona.voicePreset == preset.id,
                            action: { persona.voicePreset = preset.id }
                        )
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Custom voice file
            HStack {
                Image(systemName: "waveform.circle")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Voice File")
                        .font(.body.weight(.medium))
                    if let path = persona.voiceEmbeddingPath {
                        Text(path.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("None selected")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if persona.voiceEmbeddingPath != nil {
                    Button {
                        persona.voiceEmbeddingPath = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                Button("Choose...") {
                    showingVoiceFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .fileImporter(
                isPresented: $showingVoiceFilePicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    persona.voiceEmbeddingPath = url
                }
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Select a voice preset or provide a custom voice embedding file (.safetensors).")
                .settingsCaption()
        }
    }
}

// MARK: - Voice Preset Card

private struct VoicePresetCard: View {
    let preset: VoicePreset?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // Icon
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : .secondary)

                // Name
                Text(preset?.name ?? "Default")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                // Style badge
                if let preset {
                    Text(preset.style.displayName)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        guard let preset else {
            return "speaker.wave.2"
        }
        switch preset.gender {
        case .female:
            return "person.fill"
        case .male:
            return "person.fill"
        }
    }
}

// MARK: - Persona List View

/// A list view for managing multiple personas
struct PersonaListView: View {
    @ObserveInjection var inject
    @Binding var personas: [PersonaConfig]
    @Binding var selectedID: UUID?
    var onCreateNew: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with add button
            HStack {
                Text("Personas")
                    .font(.headline)
                Spacer()
                Button {
                    onCreateNew?()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create new persona")
            }

            // Persona list
            if personas.isEmpty {
                Text("No personas configured")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(personas) { persona in
                    PersonaRow(
                        persona: persona,
                        isSelected: selectedID == persona.id,
                        action: { selectedID = persona.id }
                    )
                }
            }
        }
        .enableInjection()
    }
}

// MARK: - Persona Row

private struct PersonaRow: View {
    let persona: PersonaConfig
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)

                // Persona info
                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    if let voice = persona.voicePreset,
                       let preset = VoicePreset.preset(withID: voice) {
                        Text(preset.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Default voice")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Voice icon
                Image(systemName: "waveform")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Persona Picker View

/// A compact picker for selecting a persona
struct PersonaPickerView: View {
    @ObserveInjection var inject
    let personas: [PersonaConfig]
    @Binding var selectedID: UUID?

    var body: some View {
        Label {
            Picker("Persona", selection: $selectedID) {
                ForEach(personas) { persona in
                    Text(persona.name).tag(Optional(persona.id))
                }
            }
            .pickerStyle(.menu)
        } icon: {
            Image(systemName: "person.wave.2")
        }
        .enableInjection()
    }
}

// MARK: - Previews

#Preview("Persona Editor - New") {
    NavigationStack {
        PersonaEditorView(
            persona: .constant(PersonaConfig(name: "", textPrompt: nil)),
            isNew: true
        )
    }
    .frame(width: 500, height: 600)
}

#Preview("Persona Editor - Edit") {
    NavigationStack {
        PersonaEditorView(
            persona: .constant(PersonaConfig(
                name: "Helpful Assistant",
                textPrompt: "You are a friendly and knowledgeable assistant. You explain complex topics in simple terms and always maintain a positive, encouraging tone.",
                voicePreset: "NATF0"
            )),
            isNew: false
        )
    }
    .frame(width: 500, height: 600)
}

#Preview("Persona List") {
    PersonaListView(
        personas: .constant([
            PersonaConfig(name: "Assistant", textPrompt: "Helpful assistant", voicePreset: "NATF0"),
            PersonaConfig(name: "Teacher", textPrompt: "Educational guide", voicePreset: "NATM0"),
            PersonaConfig(name: "Creative Writer", textPrompt: "Creative storyteller", voicePreset: "VARF1")
        ]),
        selectedID: .constant(nil)
    )
    .padding()
    .frame(width: 300)
}

#Preview("Persona Picker") {
    Form {
        PersonaPickerView(
            personas: [
                PersonaConfig(name: "Assistant"),
                PersonaConfig(name: "Teacher"),
                PersonaConfig(name: "Writer")
            ],
            selectedID: .constant(nil)
        )
    }
    .formStyle(.grouped)
    .frame(width: 400)
}

