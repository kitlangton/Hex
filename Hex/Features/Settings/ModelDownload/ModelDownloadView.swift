import ComposableArchitecture
import Inject
import SwiftUI

public struct ModelDownloadView: View {
	@ObserveInjection var inject

	@Bindable var store: StoreOf<ModelDownloadFeature>
	var shouldFlash: Bool = false

	public init(store: StoreOf<ModelDownloadFeature>, shouldFlash: Bool = false) {
		self.store = store
		self.shouldFlash = shouldFlash
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
			if !store.anyModelDownloaded {
				AutoDownloadBannerView(
					title: "Download a model to start transcribing",
					subtitle: "Choose a model below and tap download. Without a model, recordings can't be transcribed.",
					progress: store.isDownloading ? store.downloadProgress : nil,
					style: .info
				)
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.stroke(Color.accentColor, lineWidth: shouldFlash ? 3 : 0)
						.animation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true), value: shouldFlash)
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
