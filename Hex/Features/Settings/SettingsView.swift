import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus
	let inputMonitoringPermission: PermissionStatus
  
	var body: some View {
		Form {
			PermissionsSectionView(
				store: store,
				microphonePermission: microphonePermission,
				accessibilityPermission: accessibilityPermission,
				inputMonitoringPermission: inputMonitoringPermission
			)

			ModelSectionView(store: store)
			
			// Only show language picker for WhisperKit models (not Parakeet)
			if !store.hexSettings.selectedModel.hasPrefix("parakeet-") {
				LanguageSectionView(store: store)
			}
			
			HotKeySectionView(store: store)
          
			if microphonePermission == .granted && !store.availableInputDevices.isEmpty {
				MicrophoneSelectionSectionView(store: store)
			}

			SoundSectionView(store: store)
			GeneralSectionView(store: store)
			HistorySectionView(store: store)
			AdvancedSectionView(store: store)
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
		.enableInjection()
	}
}
