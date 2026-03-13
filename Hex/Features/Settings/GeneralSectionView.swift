import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct GeneralSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle("Open on Login",
				       isOn: Binding(
				       	get: { store.hexSettings.openOnLogin },
				       	set: { store.send(.toggleOpenOnLogin($0)) }
				       ))
			} icon: {
				Image(systemName: "arrow.right.circle")
			}

			Label {
				Toggle("Show Dock Icon", isOn: $store.hexSettings.showDockIcon)
			} icon: {
				Image(systemName: "dock.rectangle")
			}

			Label {
				HStack(alignment: .center) {
					Text("Transcription Output")
					Spacer()
					Picker("", selection: $store.hexSettings.transcriptionOutputMode) {
						Text("Insert in focused app")
							.tag(TranscriptionOutputMode.pasteIntoFocusedApp)
						Text("Append to file")
							.tag(TranscriptionOutputMode.appendToFile)
					}
					.pickerStyle(.menu)
				}
				Text("Choose whether transcriptions are pasted into the active app or written to a text file.")
					.settingsCaption()
			} icon: {
				Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
			}

			if store.hexSettings.transcriptionOutputMode == .appendToFile {
				Label {
					VStack(alignment: .leading, spacing: 6) {
						Text(store.hexSettings.transcriptionOutputFilePath ?? "Default: ~/Library/Application Support/com.kitlangton.Hex/transcriptions.txt")
							.font(.caption)
							.textSelection(.enabled)

						HStack(spacing: 8) {
							Button("Choose File…") {
								chooseOutputFile()
							}

							if store.hexSettings.transcriptionOutputFilePath != nil {
								Button("Use Default") {
									store.hexSettings.transcriptionOutputFilePath = nil
								}
							}
						}
					}
				} icon: {
					Image(systemName: "doc.badge.gearshape")
				}
			}

			Label {
				Toggle("Use clipboard to insert", isOn: $store.hexSettings.useClipboardPaste)
				Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}
			.disabled(store.hexSettings.transcriptionOutputMode == .appendToFile)

			Label {
				Toggle("Copy to clipboard", isOn: $store.hexSettings.copyToClipboard)
				Text("Copy transcription text to clipboard in addition to pasting it")
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}
			.disabled(store.hexSettings.transcriptionOutputMode == .appendToFile)

			Label {
				Toggle(
					"Prevent System Sleep while Recording",
					isOn: Binding(
						get: { store.hexSettings.preventSystemSleep },
						set: { store.send(.togglePreventSystemSleep($0)) }
					)
				)
			} icon: {
				Image(systemName: "zzz")
			}

			Label {
				HStack(alignment: .center) {
					Text("Audio Behavior while Recording")
				Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.recordingAudioBehavior },
						set: { store.send(.setRecordingAudioBehavior($0)) }
					)) {
						Label("Pause Media", systemImage: "pause")
							.tag(RecordingAudioBehavior.pauseMedia)
						Label("Mute Volume", systemImage: "speaker.slash")
							.tag(RecordingAudioBehavior.mute)
						Label("Do Nothing", systemImage: "hand.raised.slash")
							.tag(RecordingAudioBehavior.doNothing)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "speaker.wave.2")
			}
		} header: {
			Text("General")
		}
		.enableInjection()
	}

	private func chooseOutputFile() {
		let panel = NSOpenPanel()
		panel.title = "Select Transcription Output File"
		panel.prompt = "Choose"
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = true
		panel.allowedContentTypes = [.text, .plainText, .utf8PlainText]

		if panel.runModal() == .OK, let url = panel.url {
			store.hexSettings.transcriptionOutputFilePath = url.path
		}
	}
}
