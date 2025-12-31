import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct WordRemappingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@FocusState private var isScratchpadFocused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			VStack(alignment: .leading, spacing: 6) {
				Text("Word Remappings")
					.font(.title2.bold())
				Text("Replace specific words in every transcript. Matches whole words, case-insensitive, in order.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}

			GroupBox {
				VStack(alignment: .leading, spacing: 10) {
					HStack(spacing: 12) {
						VStack(alignment: .leading, spacing: 4) {
							Text("Scratchpad")
								.font(.caption.weight(.semibold))
								.foregroundStyle(.secondary)
							TextField("Say something…", text: $store.remappingScratchpadText)
								.textFieldStyle(.roundedBorder)
								.focused($isScratchpadFocused)
								.onChange(of: isScratchpadFocused) { _, newValue in
									store.send(.setRemappingScratchpadFocused(newValue))
								}
						}

						VStack(alignment: .leading, spacing: 4) {
							Text("Preview")
								.font(.caption.weight(.semibold))
								.foregroundStyle(.secondary)
							Text(previewText.isEmpty ? "—" : previewText)
								.font(.body)
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(.horizontal, 8)
								.padding(.vertical, 6)
								.background(
									RoundedRectangle(cornerRadius: 6)
										.fill(Color(nsColor: .controlBackgroundColor))
								)
						}
					}
				}
				.padding(.vertical, 6)
			}

			List {
				ForEach(store.hexSettings.wordRemappings) { remapping in
					if let remappingBinding = binding(for: remapping.id) {
						RemappingRow(remapping: remappingBinding) {
							store.send(.removeWordRemapping(remapping.id))
						}
					}
				}
			}
			.listStyle(.inset(alternatesRowBackgrounds: true))

			HStack {
				Button {
					store.send(.addWordRemapping)
				} label: {
					Label("Add Remapping", systemImage: "plus")
				}
				Spacer()
			}
		}
		.padding()
		.onDisappear {
			store.send(.setRemappingScratchpadFocused(false))
		}
		.enableInjection()
	}

	private func binding(for id: UUID) -> Binding<WordRemapping>? {
		guard let index = store.hexSettings.wordRemappings.firstIndex(where: { $0.id == id }) else {
			return nil
		}
		return $store.hexSettings.wordRemappings[index]
	}

	private var previewText: String {
		WordRemappingApplier.apply(
			store.remappingScratchpadText,
			remappings: store.hexSettings.wordRemappings
		)
	}
}

private struct RemappingRow: View {
	@Binding var remapping: WordRemapping
	var onDelete: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Toggle("", isOn: $remapping.isEnabled)
				.labelsHidden()
				.toggleStyle(.checkbox)

			TextField("Match", text: $remapping.match)
			Image(systemName: "arrow.right")
				.foregroundStyle(.secondary)
			TextField("Replace", text: $remapping.replacement)

			Button(role: .destructive, action: onDelete) {
				Image(systemName: "trash")
			}
			.buttonStyle(.borderless)
		}
	}
}
