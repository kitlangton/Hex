import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

private func modelNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
	ModelPatternMatcher.namesMatch(lhs, rhs)
}

public struct ModelDownloadView: View {
	@ObserveInjection var inject

	@Bindable var store: StoreOf<ModelDownloadFeature>
	@State private var isModelLibraryPresented = false
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
			if selectedModelName == nil, downloadingModel == nil {
				NoModelChooser(
					models: parakeetModels,
					suggestedModel: suggestedParakeetIdentifier,
					isLoading: store.isLoadingModels,
					isFlashing: shouldFlash,
					onDownload: { store.send(.downloadModel($0.internalName)) },
					onBrowse: { isModelLibraryPresented = true },
					onRetry: { store.send(.fetchModels) }
				)
			} else {
				CurrentModelSummary(
					model: selectedModel,
					selectedModelName: selectedModelName,
					isInstalled: store.selectedModelIsDownloaded,
					isDownloadingAnything: store.isDownloading,
					downloadingModel: downloadingModel,
					downloadProgress: store.downloadProgress,
					onBrowse: { isModelLibraryPresented = true },
					onDownload: {
						if let name = selectedModelName {
							store.send(.downloadModel(name))
						}
					},
					onCancelDownload: { store.send(.cancelDownload) }
				)
			}
			if let err = store.downloadError,
			   err != store.modelBootstrapState.lastError
			{
				Text("Model Error: \(err)")
					.foregroundColor(.red)
					.font(.caption)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.sheet(isPresented: $isModelLibraryPresented) {
			ModelLibrarySheet(store: store)
		}
		.task {
			if store.availableModels.isEmpty {
				store.send(.fetchModels)
			}
		}
		.enableInjection()
	}

	private var selectedModel: CuratedModelInfo? {
		guard let selectedModelName else { return nil }
		return store.curatedModels.first { model in
			modelNamesMatch(model.internalName, selectedModelName)
		}
	}

	private var selectedModelName: String? {
		store.selectedModelNameForDisplay
	}

	private var downloadingModel: CuratedModelInfo? {
		guard let downloadingModelName = store.downloadingModelName else { return nil }
		return store.curatedModels.first { model in
			modelNamesMatch(model.internalName, downloadingModelName)
		}
	}

	private var parakeetModels: [CuratedModelInfo] {
		let models = store.curatedModels.filter(\.isParakeet)
		return models.filter { modelNamesMatch($0.internalName, suggestedParakeetIdentifier) } +
			models.filter { !modelNamesMatch($0.internalName, suggestedParakeetIdentifier) }
	}

	private var suggestedParakeetIdentifier: String {
		store.preferredParakeetIdentifier
	}
}

private struct NoModelChooser: View {
	let models: [CuratedModelInfo]
	let suggestedModel: String
	let isLoading: Bool
	let isFlashing: Bool
	let onDownload: (CuratedModelInfo) -> Void
	let onBrowse: () -> Void
	let onRetry: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				Image(systemName: "arrow.down.circle.fill")
					.font(.title3)
					.foregroundStyle(Color.accentColor)
					.frame(width: 28)
				VStack(alignment: .leading, spacing: 3) {
					Text("Choose a transcription model")
						.font(.body.weight(.medium))
					Text("Download a local model to start transcribing.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Button("View All Models…", action: onBrowse)
					.controlSize(.small)
			}

			if models.isEmpty {
				if isLoading {
					Text("Loading model choices…")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else {
					HStack {
						Text("Model choices couldn’t be loaded.")
							.font(.caption)
							.foregroundStyle(.secondary)
						Button("Retry", action: onRetry)
							.controlSize(.small)
					}
				}
			} else {
				HStack(spacing: 10) {
					ForEach(models) { model in
						NoModelCard(
							model: model,
							isRecommended: matches(model),
							isFlashing: isFlashing && matches(model),
							onDownload: { onDownload(model) }
						)
					}
				}
			}
		}
		.padding(10)
		.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(borderColor, lineWidth: isFlashing ? 3 : 1)
				.animation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true), value: isFlashing)
		)
	}

	private var borderColor: Color {
		if isFlashing { return Color.accentColor }
		return Color.primary.opacity(0.08)
	}

	private func matches(_ model: CuratedModelInfo) -> Bool {
		modelNamesMatch(model.internalName, suggestedModel)
	}
}

private struct NoModelCard: View {
	let model: CuratedModelInfo
	let isRecommended: Bool
	let isFlashing: Bool
	let onDownload: () -> Void

	var body: some View {
		Button(action: onDownload) {
			VStack(alignment: .leading, spacing: 8) {
				HStack(alignment: .top, spacing: 8) {
					Text(model.displayName)
						.font(.body.weight(.medium))
						.foregroundStyle(.primary)
					Spacer(minLength: 8)
					if isRecommended {
						Text("Suggested")
							.font(.caption2.weight(.medium))
							.foregroundStyle(Color.accentColor)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(Color.accentColor.opacity(0.12), in: Capsule())
					}
				}
				HStack(spacing: 6) {
					Text(model.size)
					Text("·")
					Text(model.storageSize)
					Spacer()
					Image(systemName: "arrow.down.circle")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}
			.padding(12)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Color(NSColor.windowBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(borderColor, lineWidth: isFlashing ? 3 : 1)
					.animation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true), value: isFlashing)
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
	}

	private var borderColor: Color {
		if isFlashing { return Color.accentColor }
		if isRecommended { return Color.accentColor.opacity(0.45) }
		return Color.primary.opacity(0.08)
	}
}

private struct CurrentModelSummary: View {
	let model: CuratedModelInfo?
	let selectedModelName: String?
	let isInstalled: Bool
	let isDownloadingAnything: Bool
	let downloadingModel: CuratedModelInfo?
	let downloadProgress: Double
	let onBrowse: () -> Void
	let onDownload: () -> Void
	let onCancelDownload: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: iconName)
				.font(.title3)
				.foregroundStyle(needsDownload ? Color.orange : Color.accentColor)
				.frame(width: 28)

			VStack(alignment: .leading, spacing: 5) {
				Text(title)
					.font(.body.weight(.medium))
				Text(subtitle)
					.font(.caption)
					.foregroundStyle(needsDownload ? Color.orange : Color.secondary)
				if let activeDownloadStatus {
					Text(activeDownloadStatus)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				if isDownloadingAnything {
					ProgressView(value: downloadProgress)
						.progressViewStyle(.linear)
				}
			}

			Spacer()

			if isDownloadingAnything {
				VStack(alignment: .trailing, spacing: 4) {
					Text("\(Int(downloadProgress * 100))%")
						.font(.caption)
						.foregroundStyle(.secondary)
						.monospacedDigit()
					Button("Cancel", role: .destructive, action: onCancelDownload)
						.controlSize(.small)
				}
			} else {
				HStack(spacing: 8) {
					if needsDownload {
						Button("Download", action: onDownload)
							.buttonStyle(.borderedProminent)
							.controlSize(.small)
					}
					Button("Browse Models…", action: onBrowse)
						.controlSize(.small)
				}
			}
		}
		.padding(10)
		.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
	}

	/// The selection references a model that isn't on disk (e.g. the scan came
	/// back empty after an update). Offer a direct download instead of
	/// pretending it's installed.
	private var needsDownload: Bool {
		selectedModelName != nil && !isInstalled && !isDownloadingAnything
	}

	private var title: String {
		if let model { return model.displayName }
		if let selectedModelName {
			return selectedModelName
				.replacingOccurrences(of: "-", with: " ")
				.replacingOccurrences(of: "_", with: " ")
				.capitalized
		}
		if let downloadingModel { return "Downloading \(downloadingModel.displayName)…" }
		return "Choose a transcription model"
	}

	private var subtitle: String {
		if needsDownload { return "Not downloaded — transcription won't work until you download it." }
		if let model { return "\(model.size) · \(model.storageSize)" }
		if selectedModelName != nil { return "Installed local model" }
		if let downloadingModel { return "\(downloadingModel.storageSize) will be stored locally on this Mac." }
		return "Download a local model to start transcribing."
	}

	private var activeDownloadStatus: String? {
		guard selectedModelName != nil, let downloadingModel else { return nil }
		return "Downloading \(downloadingModel.displayName)…"
	}

	private var iconName: String {
		if needsDownload { return "exclamationmark.triangle.fill" }
		if selectedModelName == nil { return "arrow.down.circle.fill" }
		return "waveform"
	}

}

private struct ModelLibrarySheet: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>
	@Environment(\.dismiss) private var dismiss
	@State private var pendingDelete: CuratedModelInfo?

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(alignment: .top) {
				VStack(alignment: .leading, spacing: 4) {
					Text("Model Library")
						.font(.title2.weight(.semibold))
					Text("Select an installed model to use it, or download another model for local transcription.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.defaultAction)
			}

			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					if let recommendedLibraryModel {
						modelSection(title: "Recommended", models: [recommendedLibraryModel], showsBadges: false)
					}
					if !otherLibraryModels.isEmpty {
						modelSection(title: "Other Models", models: otherLibraryModels, showsBadges: true)
					}
				}
			}

			Label("Models run locally on your Mac. Downloads are stored on this device.", systemImage: "lock.shield")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(18)
		.frame(minWidth: 680, minHeight: 420)
		.confirmationDialog(
			"Remove \(pendingDelete?.displayName ?? "model")?",
			isPresented: Binding(
				get: { pendingDelete != nil },
				set: { if !$0 { pendingDelete = nil } }
			),
			titleVisibility: .visible
		) {
			if let pendingDelete {
				Button("Remove Download", role: .destructive) {
					store.send(.deleteModel(pendingDelete.internalName))
					self.pendingDelete = nil
				}
			}
			Button("Cancel", role: .cancel) { pendingDelete = nil }
		} message: {
			if let pendingDelete {
				Text("This frees \(pendingDelete.storageSize) on this Mac. You can download it again anytime.")
			}
		}
	}

	private func select(_ model: CuratedModelInfo) {
		guard model.isDownloaded, !store.isDownloading else { return }
		store.send(.selectModel(model.internalName))
	}

	@ViewBuilder
	private func modelSection(title: String, models: [CuratedModelInfo], showsBadges: Bool) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
				.padding(.horizontal, 2)
			VStack(spacing: 0) {
				ForEach(models) { model in
					ModelLibraryRow(
						model: model,
						isSelected: model.isDownloaded && isSelected(model),
						isDownloading: isDownloading(model),
						// Only the active row receives live progress so the other
						// rows don't re-render on every tick.
						downloadProgress: isDownloading(model) ? store.downloadProgress : 0,
						isDisabled: store.isDownloading && !isDownloading(model),
						showsBadge: showsBadges && !model.isDownloaded,
						onSelect: { select(model) },
						onDownload: { store.send(.downloadModel(model.internalName)) },
						onCancelDownload: { store.send(.cancelDownload) },
						onShowInFinder: { store.send(.openModelLocation(model.internalName)) },
						onDelete: { pendingDelete = model }
					)
					if model.id != models.last?.id {
						Divider().padding(.leading, 54)
					}
				}
			}
			.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
		}
	}

	private var recommendedLibraryModel: CuratedModelInfo? {
		store.curatedModels.first { modelNamesMatch($0.internalName, suggestedParakeetIdentifier) } ?? store.curatedModels.first(where: \.isParakeet)
	}

	private var otherLibraryModels: [CuratedModelInfo] {
		guard let recommendedLibraryModel else { return Array(store.curatedModels) }
		return store.curatedModels.filter { $0.id != recommendedLibraryModel.id }
	}

	private func isSelected(_ model: CuratedModelInfo) -> Bool {
		let selected = store.hexSettings.selectedModel
		return modelNamesMatch(model.internalName, selected)
	}

	private func isDownloading(_ model: CuratedModelInfo) -> Bool {
		store.isDownloading && store.downloadingModelName == model.internalName
	}

	private var suggestedParakeetIdentifier: String {
		store.preferredParakeetIdentifier
	}
}

private struct ModelLibraryRow: View {
	let model: CuratedModelInfo
	let isSelected: Bool
	let isDownloading: Bool
	let downloadProgress: Double
	let isDisabled: Bool
	let showsBadge: Bool
	let onSelect: () -> Void
	let onDownload: () -> Void
	let onCancelDownload: () -> Void
	let onShowInFinder: () -> Void
	let onDelete: () -> Void

	var body: some View {
		HStack(spacing: 0) {
			Button(action: onSelect) {
				HStack(spacing: 12) {
					Image(systemName: leadingIcon)
						.foregroundStyle(leadingColor)
						.font(.body)
						.frame(width: 24)

					VStack(alignment: .leading, spacing: 4) {
						HStack(spacing: 7) {
							Text(model.displayName)
								.font(.body.weight(.medium))
							if showsBadge, let badge = model.badge {
								Text(badge)
									.font(.caption2.weight(.medium))
									.foregroundStyle(Color.accentColor)
									.padding(.horizontal, 6)
									.padding(.vertical, 2)
									.background(Color.accentColor.opacity(0.12), in: Capsule())
							}
						}
						HStack(spacing: 12) {
							Text(model.size)
								.font(.caption)
								.foregroundStyle(.secondary)
							HStack(spacing: 5) {
								Text("Accuracy").font(.caption2).foregroundStyle(.secondary)
								StarRatingView(model.accuracyStars)
							}
							HStack(spacing: 5) {
								Text("Speed").font(.caption2).foregroundStyle(.secondary)
								StarRatingView(model.speedStars)
							}
						}
					}

					Spacer()

					VStack(alignment: .trailing, spacing: 3) {
						Text(model.storageSize)
							.font(.caption)
							.foregroundStyle(.secondary)
						if let statusText {
							Text(statusText)
								.font(.caption2)
								.foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
						}
					}
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 10)
				.contentShape(.rect)
			}
			.buttonStyle(.plain)

			trailingControls
				.padding(.trailing, 12)
		}
		.disabled(isDisabled)
		.opacity(isDisabled ? 0.55 : 1)
		.background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
		.contextMenu {
			if isDownloading {
				Button("Cancel Download", role: .destructive, action: onCancelDownload)
				Button("Show in Finder", action: onShowInFinder)
			}
			if model.isDownloaded {
				managementMenuItems
			}
		}
	}

	/// Shared by the trailing ⋯ menu and the right-click context menu.
	@ViewBuilder
	private var managementMenuItems: some View {
		Button("Show in Finder", action: onShowInFinder)
		Divider()
		Button("Remove Download…", role: .destructive, action: onDelete)
	}

	@ViewBuilder
	private var trailingControls: some View {
		if isDownloading {
			HStack(spacing: 8) {
				ProgressView(value: downloadProgress)
					.progressViewStyle(.circular)
					.controlSize(.small)
				Text("\(Int(downloadProgress * 100))%")
					.font(.caption)
					.foregroundStyle(.secondary)
					.monospacedDigit()
				Button("Cancel", role: .destructive, action: onCancelDownload)
					.controlSize(.small)
			}
		} else if model.isDownloaded {
			Menu {
				managementMenuItems
			} label: {
				Image(systemName: "ellipsis.circle")
					.font(.body)
					.foregroundStyle(.secondary)
			}
			.menuStyle(.borderlessButton)
			.menuIndicator(.hidden)
			.fixedSize()
			.help("Show in Finder or remove this download")
		} else {
			Button("Download", action: onDownload)
				.controlSize(.small)
				.help("Download \(model.storageSize) and switch to this model")
		}
	}

	private var statusText: String? {
		if isDownloading { return "Downloading…" }
		if isSelected { return "In Use" }
		if model.isDownloaded { return "Installed" }
		return nil
	}

	private var leadingIcon: String {
		if isDownloading { return "arrow.down.circle.fill" }
		if isSelected { return "checkmark.circle.fill" }
		if model.isDownloaded { return "circle" }
		return "arrow.down.circle"
	}

	private var leadingColor: Color {
		if isDownloading || isSelected { return .accentColor }
		return .secondary
	}

}
