import HexCore
import SwiftUI

/// Searches the locally cached OpenRouter catalog while refreshing it in the background.
struct OpenRouterModelPickerView: View {
	@Binding var selectedModelID: String?
	let apiKey: String
	@Environment(\.dismiss) private var dismiss
	@State private var models: [OpenRouterModel] = []
	@State private var searchText = ""
	@State private var sortOrder = SortOrder.name
	@State private var isRefreshing = false
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack {
			Group {
				if models.isEmpty, isRefreshing {
					ProgressView("Loading OpenRouter models…")
				} else if models.isEmpty {
					ContentUnavailableView(
						"No Models Available",
						systemImage: "cpu",
						description: Text("Check your OpenRouter API key and refresh the catalog.")
					)
				} else {
					List(filteredModels) { model in
						Button {
							selectedModelID = model.id
							dismiss()
						} label: {
							HStack(spacing: 12) {
								VStack(alignment: .leading, spacing: 3) {
									Text(model.name)
										.foregroundStyle(.primary)
									Text(model.id)
										.font(.caption)
										.foregroundStyle(.secondary)
								}
								Spacer()
								Text(inputPrice(for: model))
									.font(.caption)
									.foregroundStyle(.secondary)
								if selectedModelID == model.id {
									Image(systemName: "checkmark")
										.foregroundStyle(.tint)
								}
							}
						}
						.buttonStyle(.plain)
					}
				}
			}
			.navigationTitle("OpenRouter Models")
			.searchable(text: $searchText, prompt: "Search models")
			.toolbar {
				ToolbarItem(placement: .primaryAction) {
					Button(action: refresh) {
						if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
					}
					.disabled(isRefreshing)
				}
				ToolbarItem(placement: .automatic) {
					Picker("Sort", selection: $sortOrder) {
						Text("Name").tag(SortOrder.name)
						Text("Input Price").tag(SortOrder.inputPrice)
					}
					.pickerStyle(.menu)
				}
			}
			.alert("Couldn’t Refresh Models", isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			)) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(errorMessage ?? "Unknown error")
			}
		}
		.frame(minWidth: 620, minHeight: 520)
		.task {
			models = OpenRouterModelCatalog.cachedModels()
			refresh()
		}
	}

	private var filteredModels: [OpenRouterModel] {
		let filtered = searchText.isEmpty ? models : models.filter {
			$0.name.localizedCaseInsensitiveContains(searchText) || $0.id.localizedCaseInsensitiveContains(searchText)
		}
		return filtered.sorted(by: { lhs, rhs in
			switch sortOrder {
			case .name:
				lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
			case .inputPrice:
				switch (lhs.pricing.inputPricePerMillionTokens, rhs.pricing.inputPricePerMillionTokens) {
				case let (lhsPrice?, rhsPrice?):
					lhsPrice == rhsPrice ? lhs.name < rhs.name : lhsPrice < rhsPrice
				case (.some, .none): true
				case (.none, .some): false
				case (.none, .none): lhs.name < rhs.name
				}
			}
		})
	}

	private func refresh() {
		guard !apiKey.isEmpty, !isRefreshing else { return }
		isRefreshing = true
		Task {
			defer { isRefreshing = false }
			do {
				models = try await OpenRouterModelCatalog.refresh(apiKey: apiKey)
			} catch is CancellationError {
				return
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func inputPrice(for model: OpenRouterModel) -> String {
		guard let price = model.pricing.inputPricePerMillionTokens else { return "Input price unavailable" }
		return "\(price.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))) / M input"
	}

	private enum SortOrder: String, CaseIterable, Identifiable {
		case name
		case inputPrice

		var id: Self { self }
	}
}
