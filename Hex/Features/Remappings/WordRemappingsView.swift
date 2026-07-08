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
			VStack(alignment: .leading, spacing: 24) {
				previewSection
				wordRulesSection
				outputFormattingSection
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(20)
		}
		.onDisappear {
			store.send(.setRemappingScratchpadFocused(false))
		}
		.enableInjection()
	}

	private var previewSection: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Preview")
				.font(.headline)

			GroupBox {
				HStack(alignment: .top, spacing: 12) {
					VStack(alignment: .leading, spacing: 5) {
						Text("Input")
							.font(.caption.weight(.semibold))
							.foregroundStyle(.secondary)
						TextField("Type or speak a sample…", text: $store.remappingScratchpadText)
							.textFieldStyle(.roundedBorder)
							.focused($isScratchpadFocused)
							.onChange(of: isScratchpadFocused) { _, newValue in
								store.send(.setRemappingScratchpadFocused(newValue))
							}
					}

					Image(systemName: "arrow.right")
						.foregroundStyle(.tertiary)
						.padding(.top, 27)

					VStack(alignment: .leading, spacing: 5) {
						Text("Output")
							.font(.caption.weight(.semibold))
							.foregroundStyle(.secondary)
						Text(previewText.isEmpty ? "—" : previewText)
							.frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
							.padding(.horizontal, 8)
							.padding(.vertical, 5)
							.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
					}
				}
				.padding(.vertical, 4)
			}
		}
	}

	private var wordRulesSection: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Word rules")
				.font(.headline)

			Picker("Rule type", selection: $activeSection) {
				ForEach(ModificationSection.allCases) { section in
					Text(section.title).tag(section)
				}
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.frame(maxWidth: 360)

			switch activeSection {
			case .removals:
				removalsSection
			case .remappings:
				remappingsSection
			}
		}
	}

	private var removalsSection: some View {
		GroupBox {
			VStack(alignment: .leading, spacing: 10) {
				HStack {
					Text("Remove matching words from every transcript.")
						.settingsCaption()
					Spacer()
					Toggle(
						"Enabled",
						isOn: Binding(
							get: { store.hexSettings.wordRemovalsEnabled },
							set: { store.send(.setWordRemovalsEnabled($0)) }
						)
					)
					.toggleStyle(.switch)
					.controlSize(.small)
				}

				Divider()
				removalsColumnHeaders

				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(Array(store.hexSettings.wordRemovals.enumerated()), id: \.element.id) { index, removal in
						RemovalRow(removal: removalBinding(for: removal)) {
							store.send(.removeWordRemoval(removal.id))
						}
						if index < store.hexSettings.wordRemovals.count - 1 {
							Divider().padding(.leading, Layout.dividerLeadingPadding)
						}
					}
				}

				Button {
					store.send(.addWordRemoval)
				} label: {
					Label("Add pattern", systemImage: "plus")
				}
				.controlSize(.small)
			}
			.padding(.vertical, 4)
		}
	}

	private var remappingsSection: some View {
		GroupBox {
			VStack(alignment: .leading, spacing: 10) {
				Text("Replace matching words in every transcript.")
					.settingsCaption()
				Divider()
				remappingsColumnHeaders

				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(Array(store.hexSettings.wordRemappings.enumerated()), id: \.element.id) { index, remapping in
						RemappingRow(remapping: remappingBinding(for: remapping)) {
							store.send(.removeWordRemapping(remapping.id))
						}
						if index < store.hexSettings.wordRemappings.count - 1 {
							Divider().padding(.leading, Layout.dividerLeadingPadding)
						}
					}
				}

				Button {
					store.send(.addWordRemapping)
				} label: {
					Label("Add replacement", systemImage: "plus")
				}
				.controlSize(.small)
			}
			.padding(.vertical, 4)
		}
	}

	private var outputFormattingSection: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Output formatting")
				.font(.headline)

			GroupBox {
				HStack(spacing: 20) {
					Toggle(
						"Lowercase output",
						isOn: Binding(
							get: { store.hexSettings.lowercaseTranscripts },
							set: { store.send(.setLowercaseTranscripts($0)) }
						)
					)
					.toggleStyle(.switch)

					Divider()
						.frame(height: 22)

					Toggle(
						"Remove punctuation",
						isOn: Binding(
							get: { store.hexSettings.removePunctuation },
							set: { store.send(.setRemovePunctuation($0)) }
						)
					)
					.toggleStyle(.switch)
					Spacer()
				}
				.padding(.vertical, 4)
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

	private func removalBinding(for removal: WordRemoval) -> Binding<WordRemoval> {
		return Binding(
			get: {
				store.hexSettings.wordRemovals.first { $0.id == removal.id } ?? removal
			},
			set: { store.send(.updateWordRemoval($0)) }
		)
	}

	private func remappingBinding(for remapping: WordRemapping) -> Binding<WordRemapping> {
		return Binding(
			get: {
				store.hexSettings.wordRemappings.first { $0.id == remapping.id } ?? remapping
			},
			set: { store.send(.updateWordRemapping($0)) }
		)
	}

	private var previewText: String {
		var output = store.remappingScratchpadText
		if store.hexSettings.wordRemovalsEnabled {
			output = WordRemovalApplier.apply(output, removals: store.hexSettings.wordRemovals)
		}
		output = WordRemappingApplier.apply(output, remappings: store.hexSettings.wordRemappings)
		output = TranscriptFormattingApplier.apply(
			output,
			lowercase: store.hexSettings.lowercaseTranscripts,
			removePunctuation: store.hexSettings.removePunctuation
		)
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
				.accessibilityLabel("Enable \(removal.pattern.isEmpty ? "removal" : removal.pattern)")

			TextField("Regex Pattern", text: $removal.pattern)
				.textFieldStyle(.roundedBorder)

			Button(role: .destructive, action: onDelete) {
				Image(systemName: "trash")
			}
			.buttonStyle(.borderless)
			.frame(width: Layout.deleteColumnWidth)
			.help("Delete removal")
		}
		.padding(.horizontal, Layout.rowHorizontalPadding)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity)
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
				.accessibilityLabel("Enable \(remapping.match.isEmpty ? "replacement" : remapping.match)")

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
			.help("Delete replacement")
		}
		.padding(.horizontal, Layout.rowHorizontalPadding)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity)
	}
}

private enum ModificationSection: String, CaseIterable, Identifiable {
	case removals
	case remappings

	var id: String { rawValue }

	var title: String {
		switch self {
		case .removals:
			return "Remove words"
		case .remappings:
			return "Replace words"
		}
	}
}

private enum Layout {
	static let toggleColumnWidth: CGFloat = 24
	static let deleteColumnWidth: CGFloat = 24
	static let arrowColumnWidth: CGFloat = 16
	static let rowHorizontalPadding: CGFloat = 10
	static let dividerLeadingPadding: CGFloat = toggleColumnWidth + rowHorizontalPadding + 8
}
