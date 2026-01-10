import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct WordRemappingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@FocusState private var isScratchpadFocused: Bool
	@State private var activeSection: ModificationSection = .removals

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 6) {
					Text("Transcript Modifications")
						.font(.title2.bold())
					Text("Remove or replace words in every transcript. Removals use regex patterns and match whole words.")
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

				Picker("Modification Type", selection: $activeSection) {
					ForEach(ModificationSection.allCases) { section in
						Text(section.title).tag(section)
					}
				}
				.pickerStyle(.segmented)
				.labelsHidden()

				switch activeSection {
				case .removals:
					removalsSection
				case .remappings:
					remappingsSection
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding()
		}
		.onDisappear {
			store.send(.setRemappingScratchpadFocused(false))
		}
		.enableInjection()
	}

	private var removalsSection: some View {
		GroupBox {
			VStack(alignment: .leading, spacing: 10) {
				Toggle("Enable Word Removals", isOn: $store.hexSettings.wordRemovalsEnabled)
					.toggleStyle(.checkbox)

				removalsColumnHeaders

				LazyVStack(alignment: .leading, spacing: 6) {
					ForEach(store.hexSettings.wordRemovals) { removal in
						if let removalBinding = removalBinding(for: removal.id) {
							RemovalRow(removal: removalBinding) {
								store.send(.removeWordRemoval(removal.id))
							}
						}
					}
				}

				HStack {
					Button {
						store.send(.addWordRemoval)
					} label: {
						Label("Add Removal", systemImage: "plus")
					}
					Spacer()
				}
			}
			.padding(.vertical, 4)
		} label: {
			VStack(alignment: .leading, spacing: 4) {
				Text("Word Removals")
					.font(.headline)
				Text("Remove filler words using case-insensitive regex patterns.")
					.settingsCaption()
			}
		}
	}

	private var remappingsSection: some View {
		GroupBox {
			VStack(alignment: .leading, spacing: 10) {
				remappingsColumnHeaders

				LazyVStack(alignment: .leading, spacing: 6) {
					ForEach(store.hexSettings.wordRemappings) { remapping in
						if let remappingBinding = remappingBinding(for: remapping.id) {
							RemappingRow(remapping: remappingBinding) {
								store.send(.removeWordRemapping(remapping.id))
							}
						}
					}
				}

				HStack {
					Button {
						store.send(.addWordRemapping)
					} label: {
						Label("Add Remapping", systemImage: "plus")
					}
					Spacer()
				}
			}
			.padding(.vertical, 4)
		} label: {
			VStack(alignment: .leading, spacing: 4) {
				Text("Word Remappings")
					.font(.headline)
				Text("Replace specific words in every transcript. Matches whole words, case-insensitive, in order.")
					.settingsCaption()
			}
		}
	}

	private var removalsColumnHeaders: some View {
		HStack(spacing: 8) {
			Text("On")
				.frame(width: Layout.toggleColumnWidth, alignment: .leading)
			Text("Pattern")
				.frame(maxWidth: .infinity, alignment: .leading)
			Spacer().frame(width: Layout.deleteColumnWidth)
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, Layout.rowHorizontalPadding)
	}

	private var remappingsColumnHeaders: some View {
		HStack(spacing: 8) {
			Text("On")
				.frame(width: Layout.toggleColumnWidth, alignment: .leading)
			Text("Match")
				.frame(maxWidth: .infinity, alignment: .leading)
			Image(systemName: "arrow.right")
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(width: Layout.arrowColumnWidth)
			Text("Replace")
				.frame(maxWidth: .infinity, alignment: .leading)
			Spacer().frame(width: Layout.deleteColumnWidth)
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, Layout.rowHorizontalPadding)
	}

	private func removalBinding(for id: UUID) -> Binding<WordRemoval>? {
		guard let index = store.hexSettings.wordRemovals.firstIndex(where: { $0.id == id }) else {
			return nil
		}
		return $store.hexSettings.wordRemovals[index]
	}

	private func remappingBinding(for id: UUID) -> Binding<WordRemapping>? {
		guard let index = store.hexSettings.wordRemappings.firstIndex(where: { $0.id == id }) else {
			return nil
		}
		return $store.hexSettings.wordRemappings[index]
	}

	private var previewText: String {
		var output = store.remappingScratchpadText
		if store.hexSettings.wordRemovalsEnabled {
			output = WordRemovalApplier.apply(output, removals: store.hexSettings.wordRemovals)
		}
		output = WordRemappingApplier.apply(output, remappings: store.hexSettings.wordRemappings)
		return output
	}
}

private struct RemovalRow: View {
	@Binding var removal: WordRemoval
	var onDelete: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Toggle("", isOn: $removal.isEnabled)
				.labelsHidden()
				.toggleStyle(.checkbox)
				.frame(width: Layout.toggleColumnWidth, alignment: .leading)

			TextField("Regex Pattern", text: $removal.pattern)
				.textFieldStyle(.roundedBorder)

			Button(role: .destructive, action: onDelete) {
				Image(systemName: "trash")
			}
			.buttonStyle(.borderless)
			.frame(width: Layout.deleteColumnWidth)
		}
		.padding(.horizontal, Layout.rowHorizontalPadding)
		.padding(.vertical, Layout.rowVerticalPadding)
		.frame(maxWidth: .infinity)
		.background(
			RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
				.fill(Color(nsColor: .controlBackgroundColor))
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
				.frame(width: Layout.toggleColumnWidth, alignment: .leading)

			TextField("Match", text: $remapping.match)
				.textFieldStyle(.roundedBorder)
				.frame(maxWidth: .infinity, alignment: .leading)

			Image(systemName: "arrow.right")
				.foregroundStyle(.secondary)
				.frame(width: Layout.arrowColumnWidth)

			TextField("Replace", text: $remapping.replacement)
				.textFieldStyle(.roundedBorder)
				.frame(maxWidth: .infinity, alignment: .leading)

			Button(role: .destructive, action: onDelete) {
				Image(systemName: "trash")
			}
			.buttonStyle(.borderless)
			.frame(width: Layout.deleteColumnWidth)
		}
		.padding(.horizontal, Layout.rowHorizontalPadding)
		.padding(.vertical, Layout.rowVerticalPadding)
		.frame(maxWidth: .infinity)
		.background(
			RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
				.fill(Color(nsColor: .controlBackgroundColor))
		)
	}
}

private enum ModificationSection: String, CaseIterable, Identifiable {
	case removals
	case remappings

	var id: String { rawValue }

	var title: String {
		switch self {
		case .removals:
			return "Word Removals"
		case .remappings:
			return "Word Remappings"
		}
	}
}

private enum Layout {
	static let toggleColumnWidth: CGFloat = 24
	static let deleteColumnWidth: CGFloat = 24
	static let arrowColumnWidth: CGFloat = 16
	static let rowHorizontalPadding: CGFloat = 10
	static let rowVerticalPadding: CGFloat = 6
	static let rowCornerRadius: CGFloat = 8
}
