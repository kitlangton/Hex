import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

private func modelNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
	ModelPatternMatcher.matches(lhs, rhs) || ModelPatternMatcher.matches(rhs, lhs)
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
			if selectedModel == nil, downloadingModel == nil {
				NoModelChooser(
					models: parakeetModels,
					suggestedModel: suggestedParakeetIdentifier,
					isFlashing: shouldFlash,
					onDownload: { store.send(.downloadModel($0.internalName)) },
					onBrowse: { isModelLibraryPresented = true }
				)
			} else {
				CurrentModelSummary(
					model: selectedModel,
					downloadingModel: downloadingModel,
					downloadProgress: store.downloadProgress,
					onBrowse: { isModelLibraryPresented = true },
					onCancelDownload: { store.send(.cancelDownload) }
				)
			}
			if let err = store.downloadError {
				Text("Download Error: \(err)")
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
		store.curatedModels.first { model in
			model.isDownloaded && modelNamesMatch(model.internalName, store.hexSettings.selectedModel)
		}
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
	let isFlashing: Bool
	let onDownload: (CuratedModelInfo) -> Void
	let onBrowse: () -> Void

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
				Text("Loading model choices…")
					.font(.caption)
					.foregroundStyle(.secondary)
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
	let downloadingModel: CuratedModelInfo?
	let downloadProgress: Double
	let onBrowse: () -> Void
	let onCancelDownload: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: iconName)
				.font(.title3)
				.foregroundStyle(Color.accentColor)
				.frame(width: 28)

			VStack(alignment: .leading, spacing: 5) {
				Text(title)
					.font(.body.weight(.medium))
				Text(subtitle)
					.font(.caption)
					.foregroundStyle(.secondary)
				if let activeDownloadStatus {
					Text(activeDownloadStatus)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				if downloadingModel != nil {
					ProgressView(value: downloadProgress)
						.progressViewStyle(.linear)
				}
			}

			Spacer()

			if downloadingModel != nil {
				VStack(alignment: .trailing, spacing: 4) {
					Text("\(Int(downloadProgress * 100))%")
						.font(.caption)
						.foregroundStyle(.secondary)
					Button("Cancel", role: .destructive, action: onCancelDownload)
						.controlSize(.small)
				}
			} else {
				Button("Browse Models…", action: onBrowse)
					.controlSize(.small)
			}
		}
		.padding(10)
		.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
	}

	private var title: String {
		if let model { return model.displayName }
		if let downloadingModel { return "Downloading \(downloadingModel.displayName)…" }
		return "Choose a transcription model"
	}

	private var subtitle: String {
		if let model { return "\(model.size) · \(model.storageSize)" }
		if let downloadingModel { return "\(downloadingModel.storageSize) will be stored locally on this Mac." }
		return "Download a local model to start transcribing."
	}

	private var activeDownloadStatus: String? {
		guard model != nil, let downloadingModel else { return nil }
		return "Downloading \(downloadingModel.displayName)…"
	}

	private var iconName: String {
		if model == nil { return "arrow.down.circle.fill" }
		return "waveform"
	}

}

private struct ModelLibrarySheet: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>
	@Environment(\.dismiss) private var dismiss
	@State private var pendingDownload: CuratedModelInfo?

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
			"Download \(pendingDownload?.displayName ?? "model")?",
			isPresented: Binding(
				get: { pendingDownload != nil },
				set: { if !$0 { pendingDownload = nil } }
			),
			titleVisibility: .visible
		) {
			if let pendingDownload {
				Button("Download and Use") {
					download(pendingDownload)
					self.pendingDownload = nil
				}
			}
			Button("Cancel", role: .cancel) { pendingDownload = nil }
		} message: {
			if let pendingDownload {
				Text("\(pendingDownload.storageSize) will be stored locally on this Mac.")
			}
		}
	}

	private func select(_ model: CuratedModelInfo) {
		guard !store.isDownloading || isDownloading(model) else { return }
		guard model.isDownloaded else {
			if !isDownloading(model) { pendingDownload = model }
			return
		}
		store.send(.selectModel(model.internalName))
	}

	private func download(_ model: CuratedModelInfo) {
		store.send(.downloadModel(model.internalName))
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
						downloadProgress: store.downloadProgress,
						isDisabled: store.isDownloading && !isDownloading(model),
						showsBadge: showsBadges && !model.isDownloaded,
						onSelect: { select(model) },
						onCancelDownload: { store.send(.cancelDownload) },
						onShowInFinder: {
							store.send(.selectModel(model.internalName))
							store.send(.openModelLocation)
						},
						onDelete: {
							store.send(.selectModel(model.internalName))
							store.send(.deleteSelectedModel)
						}
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
	let onCancelDownload: () -> Void
	let onShowInFinder: () -> Void
	let onDelete: () -> Void

	var body: some View {
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
						if isDownloading {
							HStack(spacing: 5) {
								ProgressView(value: downloadProgress)
									.progressViewStyle(.circular)
									.controlSize(.small)
								Text("\(Int(downloadProgress * 100))%")
								Button("Cancel", role: .destructive, action: onCancelDownload)
									.buttonStyle(.plain)
							}
							.font(.caption)
							.foregroundStyle(.secondary)
						}
					}
				}

				Spacer()

				Text(model.storageSize)
					.font(.caption)
					.foregroundStyle(.secondary)
					.frame(width: 56, alignment: .trailing)

			}
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.disabled(isDisabled)
		.opacity(isDisabled ? 0.55 : 1)
		.background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
		.contextMenu {
			if isDownloading {
				Button("Cancel Download", role: .destructive, action: onCancelDownload)
			}
			if model.isDownloaded || isDownloading {
				Button("Show in Finder", action: onShowInFinder)
			}
			if model.isDownloaded {
				Divider()
				Button("Delete", role: .destructive, action: onDelete)
			}
		}
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
