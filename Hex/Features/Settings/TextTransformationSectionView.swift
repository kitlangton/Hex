import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct TextTransformationSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<TextTransformationFeature>
	
	var body: some View {
		VStack(spacing: 0) {
			// Header with toggle
			HStack {
				Toggle("Enable Transformations", isOn: Binding(
					get: { store.hexSettings.textTransformationPipeline.isEnabled },
					set: { _ in store.send(.togglePipeline) }
				))
				.toggleStyle(.switch)
				.font(.title3)
				
				Spacer()
			}
			.padding()
			
			Divider()
			
			Group {
				// Preview section
				VStack(alignment: .leading, spacing: 12) {
					Text("Preview")
						.font(.headline)
					
					VStack(alignment: .leading, spacing: 8) {
						Text("Input")
							.font(.caption)
							.foregroundStyle(.secondary)
						
						TextField("Test text", text: $store.previewText, axis: .vertical)
							.textFieldStyle(.plain)
							.padding(10)
							.background(Color(nsColor: .textBackgroundColor))
							.cornerRadius(6)
							.lineLimit(3...5)
							.onChange(of: store.previewText) { _, _ in
								store.send(.updatePreview)
							}
					}
					
					VStack(alignment: .leading, spacing: 8) {
						HStack {
							Text("Output")
								.font(.caption)
								.foregroundStyle(.secondary)
							
							if store.isPreviewLoading {
								ProgressView()
									.scaleEffect(0.6)
									.frame(width: 16, height: 16)
							}
						}
						
						Text(store.previewResult.isEmpty ? store.previewText : store.previewResult)
							.font(.body.monospaced())
							.foregroundStyle(store.previewResult.isEmpty ? .secondary : .primary)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(10)
							.background(Color(nsColor: .textBackgroundColor).opacity(0.5))
							.cornerRadius(6)
							.lineLimit(3...5)
					}
				}
				.padding()
				
				Divider()
				
				// Transformations list
				if store.hexSettings.textTransformationPipeline.transformations.isEmpty {
					VStack(spacing: 12) {
						Image(systemName: "wand.and.stars")
							.font(.system(size: 48))
							.foregroundStyle(.secondary)
						Text("No transformations yet")
							.font(.title3)
							.foregroundStyle(.secondary)
						Text("Add your first transformation below")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					List {
						ForEach(Array(store.hexSettings.textTransformationPipeline.transformations.enumerated()), id: \.element.id) { index, transformation in
							TransformationRow(
								transformation: transformation,
								index: index + 1,
								onToggle: { store.send(.toggleTransformation(transformation.id)) },
								onEdit: {
									switch transformation.type {
									case .replaceText:
										store.send(.startEditingReplacement(transformation.id))
									case .addPrefix:
										store.send(.startEditingPrefix(transformation.id))
									case .addSuffix:
										store.send(.startEditingSuffix(transformation.id))
									default:
										break
									}
								},
								onDelete: { store.send(.deleteTransformation(transformation.id)) }
							)
							.listRowInsets(EdgeInsets())
						}
						.onMove { from, to in
							if let fromIndex = from.first {
								store.send(.moveTransformation(from: fromIndex, to: to))
							}
						}
					}
					.listStyle(.plain)
				}
				
				Divider()
				
				// Add button
				HStack {
					Menu {
						Section("Text Case") {
							Button("UPPERCASE") { store.send(.addTransformation(.uppercase)) }
							Button("lowercase") { store.send(.addTransformation(.lowercase)) }
							Button("Title Case") { store.send(.addTransformation(.capitalize)) }
							Button("Capitalize first") { store.send(.addTransformation(.capitalizeFirst)) }
							Button("sPoNgEbOb cAsE") { store.send(.addTransformation(.spongebobCase)) }
						}
						
						Section("Whitespace") {
							Button("Trim whitespace") { store.send(.addTransformation(.trimWhitespace)) }
							Button("Remove extra spaces") { store.send(.addTransformation(.removeExtraSpaces)) }
						}
						
						Section("Custom") {
							Button("Replace Text...") { store.send(.startEditingReplacement(nil)) }
							Button("Add Prefix...") { store.send(.startEditingPrefix(nil)) }
							Button("Add Suffix...") { store.send(.startEditingSuffix(nil)) }
						}
					} label: {
						Label("Add Transformation", systemImage: "plus.circle.fill")
							.font(.body)
					}
					.menuStyle(.button)
					.buttonStyle(.borderedProminent)
					
					Spacer()
					
					if !store.hexSettings.textTransformationPipeline.transformations.isEmpty {
						Text("\(store.hexSettings.textTransformationPipeline.transformations.count) transformation\(store.hexSettings.textTransformationPipeline.transformations.count == 1 ? "" : "s")")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.padding()
			}
			.disabled(!store.hexSettings.textTransformationPipeline.isEnabled)
			.opacity(store.hexSettings.textTransformationPipeline.isEnabled ? 1 : 0.5)
		}
		.sheet(item: $store.editingReplacement) { config in
			ReplaceTextSheet(config: config, store: store)
		}
		.sheet(item: Binding(
			get: { store.editingPrefix.map { EditingString(value: $0) } },
			set: { store.editingPrefix = $0?.value }
		)) { editingString in
			PrefixSheet(prefix: editingString.value, store: store)
		}
		.sheet(item: Binding(
			get: { store.editingSuffix.map { EditingString(value: $0) } },
			set: { store.editingSuffix = $0?.value }
		)) { editingString in
			SuffixSheet(suffix: editingString.value, store: store)
		}
		.task {
			await store.send(.updatePreview).finish()
		}
		.enableInjection()
	}
}

struct EditingString: Identifiable {
	let id = UUID()
	var value: String
}

struct TransformationRow: View {
	let transformation: Transformation
	let index: Int
	let onToggle: () -> Void
	let onEdit: () -> Void
	let onDelete: () -> Void
	
	var canEdit: Bool {
		switch transformation.type {
		case .replaceText, .addPrefix, .addSuffix:
			return true
		default:
			return false
		}
	}
	
	var body: some View {
		HStack(spacing: 12) {
			// Drag handle
			Image(systemName: "line.3.horizontal")
				.font(.body)
				.foregroundStyle(.tertiary)
				.frame(width: 20)
			
			// Index
			Text("\(index)")
				.font(.caption.monospacedDigit())
				.foregroundStyle(.secondary)
				.frame(width: 20, alignment: .trailing)
			
			// Checkbox
			Toggle(isOn: Binding(get: { transformation.isEnabled }, set: { _ in onToggle() })) {
				EmptyView()
			}
			.toggleStyle(.checkbox)
			
			// Name
			Text(transformation.name)
				.font(.body)
				.foregroundStyle(transformation.isEnabled ? .primary : .secondary)
			
			Spacer()
			
			// Edit button
			if canEdit {
				Button(action: onEdit) {
					Image(systemName: "pencil.circle.fill")
						.font(.body)
				}
				.buttonStyle(.plain)
				.foregroundStyle(.secondary)
				.help("Edit")
			}
			
			// Delete button
			Button(action: onDelete) {
				Image(systemName: "trash.circle.fill")
					.font(.body)
			}
			.buttonStyle(.plain)
			.foregroundStyle(.red.opacity(0.8))
			.help("Delete")
		}
		.padding(.horizontal)
		.padding(.vertical, 10)
		.contentShape(Rectangle())
	}
}

struct ReplaceTextSheet: View {
	@State var config: ReplaceTextConfig
	let store: StoreOf<TextTransformationFeature>
	@Environment(\.dismiss) var dismiss
	
	var body: some View {
		VStack(spacing: 20) {
			Text("Replace Text")
				.font(.title2)
			
			Form {
				TextField("Find", text: $config.pattern)
					.textFieldStyle(.roundedBorder)
				
				TextField("Replace with", text: $config.replacement)
					.textFieldStyle(.roundedBorder)
				
				Toggle("Case Sensitive", isOn: $config.caseSensitive)
				Toggle("Use Regex", isOn: $config.useRegex)
			}
			.formStyle(.grouped)
			
			HStack {
				Button("Cancel") {
					dismiss()
					store.send(.cancelEditing)
				}
				.keyboardShortcut(.cancelAction)
				
				Spacer()
				
				Button("Save") {
					dismiss()
					store.send(.saveReplacement(config))
				}
				.keyboardShortcut(.defaultAction)
				.disabled(config.pattern.isEmpty)
			}
			.padding(.horizontal)
		}
		.padding()
		.frame(width: 450, height: 280)
	}
}

struct PrefixSheet: View {
	@State var prefix: String
	let store: StoreOf<TextTransformationFeature>
	@Environment(\.dismiss) var dismiss
	
	var body: some View {
		VStack(spacing: 20) {
			Text("Add Prefix")
				.font(.title2)
			
			VStack(alignment: .leading, spacing: 8) {
				Text("Prefix text")
					.font(.caption)
					.foregroundStyle(.secondary)
				
				TextField("Prefix", text: $prefix, axis: .vertical)
					.textFieldStyle(.plain)
					.padding(8)
					.background(Color(nsColor: .textBackgroundColor))
					.cornerRadius(6)
					.lineLimit(3...8)
			}
			.padding(.horizontal)
			
			HStack {
				Button("Cancel") {
					dismiss()
					store.send(.cancelEditing)
				}
				.keyboardShortcut(.cancelAction)
				
				Spacer()
				
				Button("Save") {
					dismiss()
					store.send(.savePrefix(nil, prefix))
				}
				.keyboardShortcut(.defaultAction)
			}
			.padding(.horizontal)
		}
		.padding()
		.frame(width: 450, height: 220)
	}
}

struct SuffixSheet: View {
	@State var suffix: String
	let store: StoreOf<TextTransformationFeature>
	@Environment(\.dismiss) var dismiss
	
	var body: some View {
		VStack(spacing: 20) {
			Text("Add Suffix")
				.font(.title2)
			
			VStack(alignment: .leading, spacing: 8) {
				Text("Suffix text")
					.font(.caption)
					.foregroundStyle(.secondary)
				
				TextField("Suffix", text: $suffix, axis: .vertical)
					.textFieldStyle(.plain)
					.padding(8)
					.background(Color(nsColor: .textBackgroundColor))
					.cornerRadius(6)
					.lineLimit(3...8)
			}
			.padding(.horizontal)
			
			HStack {
				Button("Cancel") {
					dismiss()
					store.send(.cancelEditing)
				}
				.keyboardShortcut(.cancelAction)
				
				Spacer()
				
				Button("Save") {
					dismiss()
					store.send(.saveSuffix(nil, suffix))
				}
				.keyboardShortcut(.defaultAction)
			}
			.padding(.horizontal)
		}
		.padding()
		.frame(width: 450, height: 220)
	}
}
