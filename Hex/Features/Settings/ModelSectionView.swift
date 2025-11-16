import ComposableArchitecture
import Inject
import SwiftUI

struct ModelSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section("Transcription Model") {
			ModelDownloadView(store: store.scope(state: \.modelDownload, action: \.modelDownload))
		}
		.enableInjection()
	}
}
