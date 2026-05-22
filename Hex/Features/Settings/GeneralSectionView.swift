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
				Toggle(
					"Show Dock Icon",
					isOn: Binding(
						get: { store.hexSettings.showDockIcon },
						set: { store.send(.toggleShowDockIcon($0)) }
					)
				)
			} icon: {
				Image(systemName: "dock.rectangle")
			}

			Label {
				Toggle(
					"Use clipboard to insert",
					isOn: Binding(
						get: { store.hexSettings.useClipboardPaste },
						set: { store.send(.setUseClipboardPaste($0)) }
					)
				)
				Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}

			Label {
				Toggle(
					"Copy to clipboard",
					isOn: Binding(
						get: { store.hexSettings.copyToClipboard },
						set: { store.send(.setCopyToClipboard($0)) }
					)
				)
				Text("Copy transcription text to clipboard in addition to pasting it")
			} icon: {
				Image(systemName: "doc.on.clipboard")
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
				Toggle(
					"Super Fast Mode",
					isOn: Binding(
						get: { store.hexSettings.superFastModeEnabled },
						set: { store.send(.toggleSuperFastMode($0)) }
					)
				)
				Text("Keep the microphone warm and prepend a short in-memory buffer for near-instant capture. macOS will keep showing the microphone indicator while this mode is armed.")
			} icon: {
				Image(systemName: "bolt.circle")
			}

			Label {
				VStack(alignment: .leading, spacing: 8) {
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
							Label("Reduce Volume", systemImage: "speaker.wave.1")
								.tag(RecordingAudioBehavior.reduceVolume)
							Label("Do Nothing", systemImage: "hand.raised.slash")
								.tag(RecordingAudioBehavior.doNothing)
						}
						.pickerStyle(.menu)
					}

					if store.hexSettings.recordingAudioBehavior == .reduceVolume {
						VStack(alignment: .leading, spacing: 8) {
							HStack(alignment: .top) {
								VStack(alignment: .leading, spacing: 2) {
									Text("Reduced Volume")
									Text("Playback level while recording")
										.recordingVolumeDescriptionStyle()
								}
								Spacer()
								Text(formattedRecordingVolume(store.hexSettings.recordingReducedVolume))
									.foregroundStyle(.secondary)
									.monospacedDigit()
							}
							Slider(
								value: Binding(
									get: { store.hexSettings.recordingReducedVolume },
									set: { store.send(.setRecordingReducedVolume($0)) }
								),
								in: 0...1,
								step: 0.05
							)

							HStack(alignment: .top) {
								VStack(alignment: .leading, spacing: 2) {
									Text("Fade Out")
									Text("At recording start")
										.recordingVolumeDescriptionStyle()
								}
								Spacer()
								Text(formattedFadeDuration(store.hexSettings.recordingVolumeFadeOutDuration))
									.foregroundStyle(.secondary)
									.monospacedDigit()
							}
							Slider(
								value: Binding(
									get: { store.hexSettings.recordingVolumeFadeOutDuration },
									set: { store.send(.setRecordingVolumeFadeOutDuration($0)) }
								),
								in: 0...HexSettings.maximumRecordingVolumeFadeDuration,
								step: 0.05
							)

							HStack(alignment: .top) {
								VStack(alignment: .leading, spacing: 2) {
									Text("Fade In")
									Text("After recording ends")
										.recordingVolumeDescriptionStyle()
								}
								Spacer()
								Text(formattedFadeDuration(store.hexSettings.recordingVolumeFadeInDuration))
									.foregroundStyle(.secondary)
									.monospacedDigit()
							}
							Slider(
								value: Binding(
									get: { store.hexSettings.recordingVolumeFadeInDuration },
									set: { store.send(.setRecordingVolumeFadeInDuration($0)) }
								),
								in: 0...HexSettings.maximumRecordingVolumeFadeDuration,
								step: 0.05
							)
						}
						.padding(.top, 10)
					}
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

private func formattedRecordingVolume(_ volume: Double) -> String {
	let clampedVolume = HexSettings.clampVolume(volume)
	return "\(Int(round(clampedVolume * 100)))%"
}

private func formattedFadeDuration(_ duration: Double) -> String {
	let clampedDuration = HexSettings.clampFadeDuration(duration)
	return String(format: "%.2fs", clampedDuration)
}

private extension Text {
	func recordingVolumeDescriptionStyle() -> some View {
		self
			.font(.subheadline)
			.foregroundStyle(.secondary)
	}
}
