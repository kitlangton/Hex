import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct CuratedRow: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<ModelDownloadFeature>
	let model: CuratedModelInfo

	var isSelected: Bool {
		let selected = store.hexSettings.selectedModel
		return ModelPatternMatcher.matches(model.internalName, selected)
			|| ModelPatternMatcher.matches(selected, model.internalName)
	}

	var body: some View {
		Button(action: { store.send(.selectModel(model.internalName)) }) {
			HStack(alignment: .center, spacing: 12) {
				// Radio selector
				Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
					.foregroundStyle(isSelected ? .blue : .secondary)

				// Title and ratings
				VStack(alignment: .leading, spacing: 6) {
					HStack(spacing: 6) {
						Text(model.displayName)
							.font(.headline)
						if !model.isDownloaded, let badge = model.badge {
							Text(badge)
								.font(.caption2)
								.fontWeight(.semibold)
								.foregroundStyle(.white)
								.padding(.horizontal, 6)
								.padding(.vertical, 2)
								.background(Color.accentColor)
								.clipShape(RoundedRectangle(cornerRadius: 4))
						}
					}
					HStack(spacing: 16) {
						HStack(spacing: 6) {
							StarRatingView(model.accuracyStars)
							Text("Accuracy").font(.caption2).foregroundStyle(.secondary)
						}
						HStack(spacing: 6) {
							StarRatingView(model.speedStars)
							Text("Speed").font(.caption2).foregroundStyle(.secondary)
						}
					}
				}

				Spacer(minLength: 12)

				// Trailing size and action/progress icons, aligned to the right
				HStack(spacing: 12) {
					Text(model.storageSize)
						.foregroundStyle(.secondary)
						.font(.subheadline)
						.frame(width: 72, alignment: .trailing)

					// Download/Progress/Downloaded at far right
					ZStack {
						if store.isDownloading, store.downloadingModelName == model.internalName {
							ProgressView(value: store.downloadProgress)
								.progressViewStyle(.circular)
								.controlSize(.small)
								.tint(.blue)
								.frame(width: 24, height: 24)
								.help("Downloading… \(Int(store.downloadProgress * 100))%")
						} else if model.isDownloaded {
							Image(systemName: "checkmark.circle.fill")
								.foregroundStyle(.green)
								.frame(width: 24, height: 24)
								.help("Downloaded")
						} else {
							Button {
								store.send(.downloadModel(model.internalName))
							} label: {
								Image(systemName: "arrow.down.circle")
							}
							.buttonStyle(.borderless)
							.help("Download")
							.frame(width: 24, height: 24)
						}
					}
				}
			}
			.padding(10)
			.background(
				RoundedRectangle(cornerRadius: 10)
					.fill(isSelected ? Color.blue.opacity(0.08) : Color(NSColor.controlBackgroundColor))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 10)
					.stroke(isSelected ? Color.blue.opacity(0.35) : Color.gray.opacity(0.18))
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		// Keep context menu as an alternative path
		.contextMenu {
			if store.isDownloading, store.downloadingModelName == model.internalName {
				Button("Cancel Download", role: .destructive) { store.send(.cancelDownload) }
			}
			if model.isDownloaded || (store.isDownloading && store.downloadingModelName == model.internalName) {
				Button("Show in Finder") { store.send(.openModelLocation) }
			}
			if model.isDownloaded {
				Divider()
				Button("Delete", role: .destructive) {
					store.send(.selectModel(model.internalName))
					store.send(.deleteSelectedModel)
				}
			}
		}
		.enableInjection()
	}
}
