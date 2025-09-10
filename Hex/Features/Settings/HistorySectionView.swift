import ComposableArchitecture
import SwiftUI

struct HistorySectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle("Save Transcription History", isOn: Binding(
					get: { store.hexSettings.saveTranscriptionHistory },
					set: { store.send(.toggleSaveTranscriptionHistory($0)) }
				))
				Text("Save transcriptions and audio recordings for later access")
					.font(.caption)
					.foregroundColor(.secondary)
			} icon: {
				Image(systemName: "clock.arrow.circlepath")
			}

			if store.hexSettings.saveTranscriptionHistory {
				Label {
					HStack {
						Text("Maximum History Entries")
						Spacer()
						Picker("", selection: Binding(
							get: { store.hexSettings.maxHistoryEntries ?? 0 },
							set: { newValue in
								store.hexSettings.maxHistoryEntries = newValue == 0 ? nil : newValue
							}
						)) {
							Text("Unlimited").tag(0)
							Text("50").tag(50)
							Text("100").tag(100)
							Text("200").tag(200)
							Text("500").tag(500)
							Text("1000").tag(1000)
						}
						.pickerStyle(.menu)
						.frame(width: 120)
					}
				} icon: {
					Image(systemName: "number.square")
				}

				if store.hexSettings.maxHistoryEntries != nil {
					Text("Oldest entries will be automatically deleted when limit is reached")
						.font(.caption)
						.foregroundColor(.secondary)
						.padding(.leading, 28)
				}
			}
		} header: {
			Text("History")
		} footer: {
			if !store.hexSettings.saveTranscriptionHistory {
				Text("When disabled, transcriptions will not be saved and audio files will be deleted immediately after transcription.")
					.font(.footnote)
					.foregroundColor(.secondary)
			}
		}
	}
}
