//
//  SettingsView.swift
//  HexIOS
//
//  Settings tab (locked design §4.5): grouped inset lists. Most rows are
//  placeholders wired to real backing as later issues land (model picker = P1-3
//  stage 3, session length, sync = P4, Full Access status, etc.).
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Bindable var model: DictationModel
    @Environment(\.openURL) private var openURL

    @State private var account = CloudAccountStatus()
    @State private var iCloudEnabled = SyncPreferences.iCloudEnabled
    @State private var syncAudio = SyncPreferences.syncAudio
    @State private var syncChangedThisLaunch = false

    // Placeholder (formatter seam #199).
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

                Section {
                    Toggle("iCloud sync", isOn: $iCloudEnabled)
                        .onChange(of: iCloudEnabled) { _, value in
                            SyncPreferences.iCloudEnabled = value
                            syncChangedThisLaunch = true
                        }
                    accountStatusRow
                    Toggle("Sync audio (Wi-Fi only)", isOn: $syncAudio)
                        .onChange(of: syncAudio) { _, value in SyncPreferences.syncAudio = value }
                        .disabled(!iCloudEnabled)
                } header: {
                    Text("iCloud")
                } footer: {
                    syncFooter
                }
                .task { await account.refresh() }

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

    @ViewBuilder
    private var accountStatusRow: some View {
        switch account.state {
        case .unknown:
            LabeledContent("Account") { ProgressView() }
        case .available:
            LabeledContent("Account") {
                Label("Signed in", systemImage: "checkmark.icloud.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
        case .noAccount:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Label("Not signed in — open Settings", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }
        case .restricted:
            LabeledContent("Account", value: "Restricted")
        case .unavailable:
            LabeledContent("Account", value: "Unavailable")
        }
    }

    @ViewBuilder
    private var syncFooter: some View {
        if syncChangedThisLaunch {
            Text("Restart Hex to apply the sync change.")
        } else if !iCloudEnabled {
            Text("History is kept on this device only.")
        } else {
            switch account.state {
            case .noAccount:
                Text("Sign in to iCloud (Settings ▸ your name) to sync history across your devices.")
            case .restricted, .unavailable:
                Text("iCloud is unavailable, so history stays on this device for now.")
            default:
                Text("History syncs across your devices via iCloud. Audio isn’t stored yet, so audio sync has no effect.")
            }
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
