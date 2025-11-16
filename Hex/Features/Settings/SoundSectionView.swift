import ComposableArchitecture
import Inject
import SwiftUI

struct SoundSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle("Sound Effects", isOn: $store.hexSettings.soundEffectsEnabled)
			} icon: {
				Image(systemName: "speaker.wave.2.fill")
			}
		} header: {
			Text("Sound")
		}
		.enableInjection()
	}
}
