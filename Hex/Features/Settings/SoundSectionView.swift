import ComposableArchitecture
import SwiftUI

struct SoundSectionView: View {
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
	}
}
