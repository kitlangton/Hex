//
//  SettingsView.swift
//  HexIOS
//
//  Settings tab (locked design §4.5): grouped inset lists. Most rows are
//  placeholders wired to real backing as later issues land (model picker = P1-3
//  stage 3, session length, sync = P4, Full Access status, etc.).
//

import SwiftUI

struct SettingsView: View {
    @Bindable var model: DictationModel

    // Placeholder toggles (real backing arrives with P4 / formatter seam #199).
    @State private var iCloudSync = true
    @State private var syncAudio = false
    @State private var cleanUpFiller = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcription") {
                    LabeledContent("Model", value: model.modelName)
                    Picker("Session length", selection: $model.sessionLength) {
                        ForEach(SessionLength.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Language", value: "Automatic")
                    NavigationLink("Vocabulary") { vocabularyPlaceholder }
                }

                Section("Sync") {
                    Toggle("iCloud sync", isOn: $iCloudSync).disabled(true)
                    Toggle("Sync audio (Wi-Fi only)", isOn: $syncAudio).disabled(true)
                }

                Section {
                    Toggle("Clean up filler words", isOn: $cleanUpFiller).disabled(true)
                } footer: {
                    Text("Removes “um”, “uh”, and tidies punctuation. Coming soon.")
                }

                Section("Keyboard") {
                    LabeledContent("Full Access") {
                        Text("Check in Settings")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var vocabularyPlaceholder: some View {
        ContentUnavailableView(
            "Vocabulary",
            systemImage: "character.book.closed",
            description: Text("Custom words and replacements will live here.")
        )
    }
}
