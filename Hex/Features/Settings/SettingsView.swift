import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus

	var body: some View {
		Form {
			PermissionsSectionView(
				store: store,
				microphonePermission: microphonePermission,
				accessibilityPermission: accessibilityPermission
			)

			if microphonePermission == .granted && !store.availableInputDevices.isEmpty {
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
