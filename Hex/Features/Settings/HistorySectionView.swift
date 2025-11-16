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

		HStack(alignment: .center, spacing: 12) {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("Paste Last Transcript")
						.font(.subheadline.weight(.semibold))
					Text("Quick shortcut to drop your most recent transcription into any app.")
						.font(.caption)
						.foregroundColor(.secondary)
				}
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}

			Spacer()

			Button {
				store.send(.startSettingPasteLastTranscriptHotkey)
			} label: {
				Text(shortcutDescription(for: pasteHotkey))
					.font(.system(size: 15, weight: .semibold, design: .rounded))
					.foregroundColor(.primary)
					.padding(.vertical, 5)
					.padding(.horizontal, 12)
					.background(
						RoundedRectangle(cornerRadius: 10)
							.fill(store.isSettingPasteLastTranscriptHotkey ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
					)
					.overlay(
						RoundedRectangle(cornerRadius: 10)
							.stroke(Color.gray.opacity(store.isSettingPasteLastTranscriptHotkey ? 0.5 : 0.25))
					)
			}
			.buttonStyle(.plain)

			if store.isSettingPasteLastTranscriptHotkey, pasteHotkey != nil {
				Button {
					store.send(.clearPasteLastTranscriptHotkey)
				} label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 14, weight: .semibold))
				}
				.buttonStyle(.plain)
			}
		}
		.enableInjection()
	}
	
	func shortcutDescription(for hotkey: HotKey?) -> String {
		if store.isSettingPasteLastTranscriptHotkey {
			let modifiers = store.currentPasteLastModifiers.sorted.map { $0.stringValue }.joined()
			if modifiers.isEmpty {
				return "Press shortcut…"
			}
			return modifiers
		}
		guard let hotkey else { return "Not set" }
		let modifiers = hotkey.modifiers.sorted.map { $0.stringValue }.joined()
		let keySymbol = hotkey.key?.toString ?? ""
		return modifiers + keySymbol
	}
}
