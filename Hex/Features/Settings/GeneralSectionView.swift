import ComposableArchitecture
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
					"Pause Media while Recording",
					isOn: Binding(
						get: { store.hexSettings.pauseMediaOnRecord },
						set: { store.send(.togglePauseMediaOnRecord($0)) }
					)
				)
			} icon: {
				Image(systemName: "pause")
			}
		} header: {
			Text("General")
		}
		.enableInjection()
	}
}
