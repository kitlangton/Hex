//
//  TranscriptStore.swift
//  HexIOS
//
//  Persistent, iCloud-synced transcript history (P4-2). SwiftData persists
//  locally (history survives relaunch) and, with the CloudKit container, syncs
//  across the user's devices automatically.
//

import Foundation
import HexCore
import SwiftData

/// User-controllable sync preferences, persisted in the App Group.
enum SyncPreferences {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: HexAppGroup.identifier) }

    /// Whether history should sync via iCloud. Read once at launch to pick the
    /// store configuration (changing it takes effect on next launch).
    static var iCloudEnabled: Bool {
        get { defaults?.object(forKey: "hex.iCloudEnabled") as? Bool ?? true }
        set { defaults?.set(newValue, forKey: "hex.iCloudEnabled") }
    }

    /// Forward-looking: sync audio recordings too (audio isn't persisted yet).
    static var syncAudio: Bool {
        get { defaults?.bool(forKey: "hex.syncAudio") ?? false }
        set { defaults?.set(newValue, forKey: "hex.syncAudio") }
    }
}

@Model
final class TranscriptEntry {
    // CloudKit-backed SwiftData requires every attribute to have a default.
    var text: String = ""
    var date: Date = Date()
    var sourceRaw: String = DictationSource.note.rawValue

    var source: DictationSource { DictationSource(rawValue: sourceRaw) ?? .note }

    init(text: String, date: Date, source: DictationSource) {
        self.text = text
        self.date = date
        self.sourceRaw = source.rawValue
    }
}

enum TranscriptStore {
    /// Build the model container. Prefers the CloudKit-synced store; falls back
    /// to a local-only store if CloudKit is unavailable (e.g. no iCloud account).
    @MainActor
    static func makeContainer() -> ModelContainer {
        if SyncPreferences.iCloudEnabled,
           let cloud = try? ModelContainer(
               for: TranscriptEntry.self,
               configurations: ModelConfiguration(cloudKitDatabase: .automatic)
           ) {
            return cloud
        }
        if let local = try? ModelContainer(
            for: TranscriptEntry.self,
            configurations: ModelConfiguration(cloudKitDatabase: .none)
        ) {
            return local
        }
        // In-memory last resort so the app still runs.
        return try! ModelContainer(
            for: TranscriptEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
