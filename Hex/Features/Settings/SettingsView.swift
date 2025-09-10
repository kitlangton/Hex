import ComposableArchitecture
import Inject
import SwiftUI

struct SettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Form {
			PermissionsSectionView(store: store)

			if store.microphonePermission == .granted && !store.availableInputDevices.isEmpty {
				MicrophoneSelectionSectionView(store: store)
			}

			ModelSectionView(store: store)
			LanguageSectionView(store: store)
			HotKeySectionView(store: store)
			SoundSectionView(store: store)
			GeneralSectionView(store: store)
			HistorySectionView(store: store)
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
		.enableInjection()
	}
}
