//
//  HistoryView.swift
//  HexIOS
//
//  History tab (locked design §4.4): unified transcript list (notes + keyboard
//  insertions), day-grouped, searchable. Source tagging + inline audio playback
//  arrive with the unified-history data model (P4); for now every row is a note.
//

import SwiftUI

struct HistoryView: View {
    let model: DictationModel
    @State private var query = ""

    private var filtered: [DictationEntry] {
        guard !query.isEmpty else { return model.entries }
        return model.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var grouped: [(day: Date, entries: [DictationEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.entries.isEmpty {
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
                                    row(entry)
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

    private func row(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
            HStack(spacing: 6) {
                Image(systemName: entry.source.systemImage)
                Text(entry.source.label)
                Text("·")
                Text(entry.date, style: .time)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
