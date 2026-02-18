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
				Toggle("Use clipboard to insert", isOn: $store.hexSettings.useClipboardPaste)
				Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}

			Label {
				Toggle("Copy to clipboard", isOn: $store.hexSettings.copyToClipboard)
				Text("Copy transcription text to clipboard in addition to pasting it")
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}

			Label {
				HStack(alignment: .center) {
					Text("Auto Submit")
				Spacer()
					Picker("", selection: $store.hexSettings.autoSubmitKey) {
						Text("Off").tag(AutoSubmitKey.off)
						Text("Enter").tag(AutoSubmitKey.enter)
						Text("⌘ Enter").tag(AutoSubmitKey.cmdEnter)
						Text("⇧ Enter").tag(AutoSubmitKey.shiftEnter)
					}
					.pickerStyle(.menu)
				}
				Text("Automatically send a keystroke after pasting transcribed text")
			} icon: {
				Image(systemName: "return")
			}

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
}
