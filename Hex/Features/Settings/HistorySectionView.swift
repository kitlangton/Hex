import ComposableArchitecture
import Inject
import SwiftUI
import HexCore

struct HistorySectionView: View {
	@ObserveInjection var inject
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

				PasteLastTranscriptHotkeyRow(store: store)
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
		.enableInjection()
	}
}

private struct PasteLastTranscriptHotkeyRow: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		let pasteHotkey = store.hexSettings.pasteLastTranscriptHotkey

		VStack(alignment: .leading, spacing: 12) {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("Paste Last Transcript")
						.font(.subheadline.weight(.semibold))
					Text("Assign a shortcut (modifier + key) to instantly paste your last transcription.")
						.font(.caption)
						.foregroundColor(.secondary)
				}
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}

			let key = store.isSettingPasteLastTranscriptHotkey ? nil : pasteHotkey?.key
			let modifiers = store.isSettingPasteLastTranscriptHotkey ? store.currentPasteLastModifiers : (pasteHotkey?.modifiers ?? .init(modifiers: []))

			HStack {
				Spacer()
				ZStack {
					HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingPasteLastTranscriptHotkey)

					if !store.isSettingPasteLastTranscriptHotkey, pasteHotkey == nil {
						Text("Not set")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.contentShape(Rectangle())
				.onTapGesture {
					store.send(.startSettingPasteLastTranscriptHotkey)
				}
				Spacer()
			}

			if store.isSettingPasteLastTranscriptHotkey {
				Text("Use at least one modifier (⌘, ⌥, ⇧, ⌃) plus a key.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} else if pasteHotkey != nil {
				Button {
					store.send(.clearPasteLastTranscriptHotkey)
				} label: {
					Label("Clear shortcut", systemImage: "xmark.circle")
				}
				.buttonStyle(.borderless)
				.font(.caption)
				.foregroundStyle(.secondary)
			}
		}
		.enableInjection()
	}
}
