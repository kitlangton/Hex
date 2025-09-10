import ComposableArchitecture
import SwiftUI

struct ModelSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section("Transcription Model") {
			ModelDownloadView(store: store.scope(state: \.modelDownload, action: \.modelDownload))
		}
	}
}
