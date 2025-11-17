import ComposableArchitecture
import Inject
import SwiftUI

public struct ModelDownloadView: View {
	@ObserveInjection var inject

	@Bindable var store: StoreOf<ModelDownloadFeature>

	public init(store: StoreOf<ModelDownloadFeature>) {
		self.store = store
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if !store.modelBootstrapState.isModelReady,
			   let message = store.modelBootstrapState.lastError,
			   !message.isEmpty
			{
				AutoDownloadBannerView(
					title: "Download failed",
					subtitle: message,
					progress: nil,
					style: .error
				)
			}
			// Always show a concise, opinionated list (no dropdowns)
			CuratedList(store: store)
			if let err = store.downloadError {
				Text("Download Error: \(err)")
					.foregroundColor(.red)
					.font(.caption)
			}
		}
		.frame(maxWidth: 500)
		.task {
			if store.availableModels.isEmpty {
				store.send(.fetchModels)
			}
		}
		.onAppear {
			store.send(.fetchModels)
		}
		.enableInjection()
	}
}

