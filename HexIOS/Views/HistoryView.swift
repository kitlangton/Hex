//
//  HistoryView.swift
//  HexIOS
//
//  History tab (locked design §4.4): unified transcript list (notes + keyboard
//  insertions), day-grouped, searchable. Backed by SwiftData (@Query), so it
//  persists across launches and syncs via CloudKit. Inline audio playback is a
//  later add (P4-3).
//

import SwiftData
import SwiftUI

struct HistoryView: View {
    @Query(sort: \TranscriptEntry.date, order: .reverse) private var entries: [TranscriptEntry]
    @State private var query = ""

    private var filtered: [TranscriptEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var grouped: [(day: Date, entries: [TranscriptEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No transcripts yet",
                        systemImage: "text.bubble",
                        description: Text("Notes and keyboard dictations show up here.")
                    )
                } else {
                    List {
                        ForEach(grouped, id: \.day) { group in
                            Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(group.entries) { entry in
                                    NavigationLink {
                                        TranscriptDetailView(entry: entry)
                                    } label: {
                                        row(entry)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .searchable(text: $query, prompt: "Search transcripts")
        }
    }

    private func row(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
            HStack(spacing: 6) {
                Image(systemName: entry.kind.systemImage)
                Text(entry.kind.label)
                Text("·")
                Text(entry.date, style: .time)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
