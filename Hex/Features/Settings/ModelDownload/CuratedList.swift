import ComposableArchitecture
import Inject
import SwiftUI

struct CuratedList: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<ModelDownloadFeature>

	private var visibleModels: [CuratedModelInfo] {
		if store.showAllModels {
			return Array(store.curatedModels)
		} else {
			// Show only Parakeet by default
			return store.curatedModels.filter { $0.internalName.hasPrefix("parakeet-") }
		}
	}

	private var hiddenModels: [CuratedModelInfo] {
		store.curatedModels.filter { !$0.internalName.hasPrefix("parakeet-") }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach(visibleModels) { model in
				CuratedRow(store: store, model: model)
			}

			// Show "Show more"/"Show less" button
			if !hiddenModels.isEmpty {
				Button(action: { store.send(.toggleModelDisplay) }) {
					HStack {
                      Spacer()
						Text(store.showAllModels ? "Show less" : "Show more")
							.font(.subheadline)
						Spacer()
					}
				}
				.buttonStyle(.plain)
				.foregroundStyle(.secondary)
			}
		}
		.enableInjection()
	}
}

