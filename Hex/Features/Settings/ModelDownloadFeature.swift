// MARK: – ModelDownloadFeature.swift

// A full‐featured TCA reducer + SwiftUI view for managing on‑device ML models.
// The file is single‑purpose but split into logical sections for clarity.
// Dependencies: ComposableArchitecture, IdentifiedCollections, Dependencies, SwiftUI

import ComposableArchitecture
import Dependencies
import IdentifiedCollections
import SwiftUI
import Darwin

// ──────────────────────────────────────────────────────────────────────────

// MARK: – Data Models

// ──────────────────────────────────────────────────────────────────────────

public struct ModelInfo: Equatable, Identifiable {
	public let name: String
	public var isDownloaded: Bool

	public var id: String { name }
	public init(name: String, isDownloaded: Bool) {
		self.name = name
		self.isDownloaded = isDownloaded
	}
}

public struct CuratedModelInfo: Equatable, Identifiable, Codable {
	public let displayName: String
	public let internalName: String
	public let size: String
	public let accuracyStars: Int
	public let speedStars: Int
	public let storageSize: String
	public var isDownloaded: Bool
	public var id: String { internalName }

	public init(
		displayName: String,
		internalName: String,
		size: String,
		accuracyStars: Int,
		speedStars: Int,
		storageSize: String,
		isDownloaded: Bool
	) {
		self.displayName = displayName
		self.internalName = internalName
		self.size = size
		self.accuracyStars = accuracyStars
		self.speedStars = speedStars
		self.storageSize = storageSize
		self.isDownloaded = isDownloaded
	}

	// Codable (isDownloaded is set at runtime)
	private enum CodingKeys: String, CodingKey { case displayName, internalName, size, accuracyStars, speedStars, storageSize }
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		displayName = try c.decode(String.self, forKey: .displayName)
		internalName = try c.decode(String.self, forKey: .internalName)
		size = try c.decode(String.self, forKey: .size)
		accuracyStars = try c.decode(Int.self, forKey: .accuracyStars)
		speedStars = try c.decode(Int.self, forKey: .speedStars)
		storageSize = try c.decode(String.self, forKey: .storageSize)
		isDownloaded = false
	}
}

// Convenience helper for loading the bundled models.json once.
private enum CuratedModelLoader {
	static func load() -> [CuratedModelInfo] {
		guard let url = Bundle.main.url(forResource: "models", withExtension: "json") ??
			Bundle.main.url(forResource: "models", withExtension: "json", subdirectory: "Data")
		else {
			assertionFailure("models.json not found in bundle")
			return []
		}
		do { return try JSONDecoder().decode([CuratedModelInfo].self, from: Data(contentsOf: url)) }
		catch { assertionFailure("Failed to decode models.json – \(error)"); return [] }
	}
}

// ──────────────────────────────────────────────────────────────────────────

// MARK: – Domain

// ──────────────────────────────────────────────────────────────────────────

@Reducer
public struct ModelDownloadFeature {
	@ObservableState
	public struct State: Equatable {
		// Shared user settings
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

		// Remote data
		public var availableModels: IdentifiedArrayOf<ModelInfo> = []
		public var curatedModels: IdentifiedArrayOf<CuratedModelInfo> = []
		public var recommendedModel: String = ""

		// UI state
		public var showAllModels = false
		public var isDownloading = false
		public var downloadProgress: Double = 0
		public var downloadError: String?
		public var downloadingModelName: String?
		public var isAutoDownloadInProgress = false
        
        // Track which model generated a progress update to handle switching models
        public var activeDownloadID: UUID?

		// Convenience computed vars
		var selectedModel: String { hexSettings.selectedModel }
		var selectedModelIsDownloaded: Bool {
			availableModels[id: selectedModel]?.isDownloaded ?? false
		}

		var anyModelDownloaded: Bool {
			availableModels.contains(where: { $0.isDownloaded })
		}
	}

	// MARK: Actions

	public enum Action: BindableAction {
		case binding(BindingAction<State>)
		// Requests
		case fetchModels
		case selectModel(String)
		case toggleModelDisplay
		case downloadSelectedModel
		case autoDownloadIfNeeded
		// Effects
        case modelsLoaded(recommended: String, available: [ModelInfo])
        case downloadProgress(Double)
        case downloadCompleted(Result<String, Error>)
        case cancelDownload

		case deleteSelectedModel
		case openModelLocation
	}

	// MARK: Dependencies

	@Dependency(\.transcription) var transcription
	@Dependency(\.continuousClock) var clock

	public init() {}

	// MARK: Reducer

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce(reduce)
    }


    // MARK: - Helpers (pattern matching)
    private func matches(_ pattern: String, _ text: String) -> Bool {
        if pattern.contains("*") || pattern.contains("?") {
            return fnmatch(pattern, text, 0) == 0
        }
        return pattern == text
    }

	private func resolvePattern(_ pattern: String, from available: [ModelInfo]) -> String? {
		// No glob characters: return as-is
		if !(pattern.contains("*") || pattern.contains("?")) { return pattern }

		// All matches
		let matches = available.filter { fnmatch(pattern, $0.name, 0) == 0 }
        guard !matches.isEmpty else { return nil }

        // Prefer already-downloaded matches
        let downloaded = matches.filter { $0.isDownloaded }
        if !downloaded.isEmpty {
            // Prefer non-turbo if both exist, otherwise turbo
            if let nonTurbo = downloaded.first(where: { !$0.name.localizedCaseInsensitiveContains("turbo") }) {
                return nonTurbo.name
            }
            return downloaded.first!.name
        }

        // If none downloaded yet, prefer non-turbo first
		if let nonTurbo = matches.first(where: { !$0.name.localizedCaseInsensitiveContains("turbo") }) {
			return nonTurbo.name
		}
		return matches.first!.name
	}

	private func curatedDisplayName(for model: String, curated: IdentifiedArrayOf<CuratedModelInfo>) -> String {
		if let match = curated.first(where: { matches($0.internalName, model) }) {
			return match.displayName
		}
		return model
			.replacingOccurrences(of: "-", with: " ")
			.replacingOccurrences(of: "_", with: " ")
			.capitalized
	}

	private func updateBootstrapState(_ state: inout State) {
		let model = state.hexSettings.selectedModel
		guard !model.isEmpty else { return }
		let displayName = curatedDisplayName(for: model, curated: state.curatedModels)
		state.$modelBootstrapState.withLock { bootstrap in
			bootstrap.modelIdentifier = model
			bootstrap.modelDisplayName = displayName
			bootstrap.isModelReady = state.selectedModelIsDownloaded
			if state.selectedModelIsDownloaded {
				bootstrap.lastError = nil
				bootstrap.isAutoDownloading = false
				bootstrap.progress = 1
			}
		}
	}

    private func reduce(state: inout State, action: Action) -> Effect<Action> {
        switch action {
		// MARK: – UI bindings

		case .binding:
			return .none

		case .toggleModelDisplay:
			state.showAllModels.toggle()
			return .none

		case let .selectModel(model):
			// If the curated item is a glob (e.g., "distil*large-v3"),
			// resolve it to a concrete available model so both tabs stay in sync
			let resolved = resolvePattern(model, from: Array(state.availableModels)) ?? model
			state.$hexSettings.withLock { $0.selectedModel = resolved }
			updateBootstrapState(&state)
			return .none

		// MARK: – Fetch Models

		case .fetchModels:
			return .run { send in
				do {
					let recommended = try await transcription.getRecommendedModels().default
					let names = try await transcription.getAvailableModels()
					let infos = try await withThrowingTaskGroup(of: ModelInfo.self) { group -> [ModelInfo] in
						for name in names {
							group.addTask {
								ModelInfo(
									name: name,
									isDownloaded: await transcription.isModelDownloaded(name)
								)
							}
						}
						return try await group.reduce(into: []) { $0.append($1) }
					}
					await send(.modelsLoaded(recommended: recommended, available: infos))
				} catch {
					await send(.modelsLoaded(recommended: "", available: []))
				}
			}

		case let .modelsLoaded(recommended, available):
			// Prefer Parakeet as recommended if present
			let parakeet = "parakeet-tdt-0.6b-v3-coreml"
			let availablePlus = available + (available.contains(where: { $0.name == parakeet }) ? [] : [ModelInfo(name: parakeet, isDownloaded: false)])

			state.recommendedModel = availablePlus.contains(where: { $0.name == parakeet }) ? parakeet : recommended
			state.availableModels = IdentifiedArrayOf(uniqueElements: availablePlus)

            // If the selected model is a pattern, resolve it now to the first available match
            if state.hexSettings.selectedModel.contains("*") || state.hexSettings.selectedModel.contains("?") {
                if let resolved = resolvePattern(state.hexSettings.selectedModel, from: available) {
                    state.$hexSettings.withLock { $0.selectedModel = resolved }
                }
            }

            // Merge curated + download status with pattern support
			var curated = CuratedModelLoader.load()
			for idx in curated.indices {
				let internalName = curated[idx].internalName
				if let match = available.first(where: { matches(internalName, $0.name) }) {
					curated[idx].isDownloaded = match.isDownloaded
				} else {
					curated[idx].isDownloaded = false
				}
			}
			state.curatedModels = IdentifiedArrayOf(uniqueElements: curated)
			updateBootstrapState(&state)
			if !state.anyModelDownloaded && !state.hexSettings.hasCompletedModelBootstrap {
				let preferred = state.recommendedModel.isEmpty ? state.hexSettings.selectedModel : state.recommendedModel
				if !preferred.isEmpty {
					state.$hexSettings.withLock { $0.selectedModel = preferred }
					updateBootstrapState(&state)
				}
			}
			let shouldAutoDownload = !state.anyModelDownloaded && !state.isDownloading && !state.hexSettings.hasCompletedModelBootstrap
			return shouldAutoDownload ? .send(.autoDownloadIfNeeded) : .none

		// MARK: – Download

		case .autoDownloadIfNeeded:
			guard !state.isDownloading else { return .none }
			guard !state.hexSettings.hasCompletedModelBootstrap else { return .none }
			let selected = state.hexSettings.selectedModel
			let targetModel: String
			if !selected.isEmpty, state.availableModels[id: selected] != nil {
				targetModel = selected
			} else if !state.recommendedModel.isEmpty,
					 state.availableModels[id: state.recommendedModel] != nil
			{
				targetModel = state.recommendedModel
				state.$hexSettings.withLock { $0.selectedModel = targetModel }
			} else if let fallback = state.availableModels.first?.id {
				targetModel = fallback
				state.$hexSettings.withLock { $0.selectedModel = targetModel }
			} else {
				return .none
			}
			if state.availableModels[id: targetModel]?.isDownloaded == true {
				return .none
			}
			state.isAutoDownloadInProgress = true
			let displayName = curatedDisplayName(for: targetModel, curated: state.curatedModels)
			state.$modelBootstrapState.withLock {
				$0.isModelReady = false
				$0.isAutoDownloading = true
				$0.progress = 0
				$0.lastError = nil
				$0.modelIdentifier = targetModel
				$0.modelDisplayName = displayName
			}
			return .send(.downloadSelectedModel)

		case .downloadSelectedModel:
			guard !state.hexSettings.selectedModel.isEmpty else { return .none }
			state.downloadError = nil
			state.isDownloading = true
			state.downloadingModelName = state.hexSettings.selectedModel
            state.activeDownloadID = UUID()
            let downloadID = state.activeDownloadID!
            return .run { [state] send in
                do {
                    // Assume downloadModel returns AsyncThrowingStream<Double, Error>
                    try await transcription.downloadModel(state.selectedModel) { progress in
                        Task { await send(.downloadProgress(progress.fractionCompleted)) }
                    }
                    await send(.downloadCompleted(.success(state.selectedModel)))
                } catch {
                    await send(.downloadCompleted(.failure(error)))
                }
            }
            .cancellable(id: downloadID)

		case let .downloadProgress(progress):
			state.downloadProgress = progress
			if state.isAutoDownloadInProgress {
				state.$modelBootstrapState.withLock { $0.progress = progress }
			}
			return .none

		case let .downloadCompleted(result):
			state.isDownloading = false
			state.downloadingModelName = nil
			state.activeDownloadID = nil
			var failureMessage: String?
			switch result {
			case let .success(name):
				state.availableModels[id: name]?.isDownloaded = true
				if let idx = state.curatedModels.firstIndex(where: { $0.internalName == name }) {
					state.curatedModels[idx].isDownloaded = true
				}
				state.$hexSettings.withLock { settings in
					settings.hasCompletedModelBootstrap = true
				}
			case let .failure(err):
				// Enrich the error so users see which URL/host failed
				let ns = err as NSError
				var message = ns.localizedDescription
				if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
					if let host = url.host { message += " (\(host))" }
				} else if let str = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
						let u = URL(string: str), let host = u.host {
					message += " (\(host))"
				}
				state.downloadError = message
				failureMessage = message
			}
			if state.isAutoDownloadInProgress {
				state.$modelBootstrapState.withLock { bootstrap in
					bootstrap.isAutoDownloading = false
					bootstrap.isModelReady = failureMessage == nil && state.selectedModelIsDownloaded
					bootstrap.progress = failureMessage == nil ? 1 : 0
					bootstrap.lastError = failureMessage
				}
				state.isAutoDownloadInProgress = false
			}
			updateBootstrapState(&state)
			return .none

		case .cancelDownload:
			guard let id = state.activeDownloadID else { return .none }
			state.isDownloading = false
			state.downloadingModelName = nil
			state.activeDownloadID = nil
			if state.isAutoDownloadInProgress {
				state.isAutoDownloadInProgress = false
				state.$modelBootstrapState.withLock {
					$0.isAutoDownloading = false
					$0.progress = 0
					$0.isModelReady = false
					$0.lastError = "Download cancelled"
				}
			}
			return .cancel(id: id)

		case .deleteSelectedModel:
			guard !state.selectedModel.isEmpty else { return .none }
			state.$modelBootstrapState.withLock { $0.isModelReady = false }
			return .run { [state] send in
				do {
					try await transcription.deleteModel(state.selectedModel)
					await send(.fetchModels)
				} catch {
					await send(.downloadCompleted(.failure(error)))
				}
			}

		case .openModelLocation:
			return openModelLocationEffect()
		}
	}

	// MARK: Helpers

	private func openModelLocationEffect() -> Effect<Action> {
		.run { _ in
			let fm = FileManager.default
			let base = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			.appendingPathComponent("com.kitlangton.Hex/models", isDirectory: true)

			if !fm.fileExists(atPath: base.path) {
				try fm.createDirectory(at: base, withIntermediateDirectories: true)
			}
			NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: base.path)
		}
	}
}

// ──────────────────────────────────────────────────────────────────────────

// MARK: – SwiftUI Views

// ──────────────────────────────────────────────────────────────────────────

private struct StarRatingView: View {
	let filled: Int
	let max: Int

	init(_ filled: Int, max: Int = 5) {
		self.filled = filled
		self.max = max
	}

	var body: some View {
		HStack(spacing: 3) {
			ForEach(0 ..< max, id: \.self) { i in
				Image(systemName: i < filled ? "circle.fill" : "circle")
					.font(.system(size: 7))
					.foregroundColor(i < filled ? .blue : .gray.opacity(0.5))
			}
		}
	}
}

public struct ModelDownloadView: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>

	public init(store: StoreOf<ModelDownloadFeature>) {
		self.store = store
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			SimpleHeader()
			if store.isAutoDownloadInProgress {
				AutoDownloadBannerView(
					title: "Setting up \(autoDownloadDisplayName)",
					subtitle: autoDownloadSubtitle,
					progress: downloadProgressClamped,
					style: .info
				)
			} else if !store.modelBootstrapState.isModelReady,
						let message = store.modelBootstrapState.lastError
			{
				AutoDownloadBannerView(
					title: "Automatic download failed",
					subtitle: message,
					progress: nil,
					style: .error
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
	}

	private var autoDownloadDisplayName: String {
		let candidate = store.modelBootstrapState.modelDisplayName ?? store.hexSettings.selectedModel
		return candidate.isEmpty ? "voice model" : candidate
	}

	private var downloadProgressClamped: Double {
		max(0, min(store.downloadProgress, 1))
	}

	private var autoDownloadSubtitle: String {
		let progress = downloadProgressClamped
		if progress >= 0.999 {
			return "Finalizing download…"
		}
		let percent = Int((progress * 100).rounded())
		return "\(percent)% downloaded"
	}
}

// MARK: – Subviews

private struct SimpleHeader: View {
    var body: some View {
        HStack {
            Text("Transcription Model")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
    }
}

// Removed the dropdown picker — selection is now by clicking a row.

// MARK: – Compact Primary Card

private struct PrimaryModelCard: View {
    @Bindable var store: StoreOf<ModelDownloadFeature>

    private var primary: CuratedModelInfo? {
        // Prefer Parakeet if present; otherwise currently selected
        if let p = store.curatedModels.first(where: { $0.internalName.hasPrefix("parakeet-") }) { return p }
        return store.curatedModels.first(where: { $0.internalName == store.hexSettings.selectedModel })
            ?? store.curatedModels.first
    }

    var body: some View {
        if let model = primary {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName)
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            Label(model.internalName.hasPrefix("parakeet-") ? "Multilingual" : "English only",
                                  systemImage: model.internalName.hasPrefix("parakeet-") ? "globe" : "character.cursor.ibeam")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.storageSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.isDownloaded {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    }
                }

                HStack(spacing: 12) {
                    StarRatingView( model.accuracyStars )
                    Text("Accuracy").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    StarRatingView( model.speedStars )
                    Text("Speed").font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button(model.isDownloaded ? "Use" : "Download") {
                        store.send(.selectModel(model.internalName))
                        if !model.isDownloaded { store.send(.downloadSelectedModel) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    if model.isDownloaded {
                        Button("Delete", role: .destructive) { store.send(.deleteSelectedModel) }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                }
            }
            .padding(14)
            .background( RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)) )
            .overlay( RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2)) )
        } else {
            Text("No models found.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CuratedList: View {
    @Bindable var store: StoreOf<ModelDownloadFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.curatedModels) { model in
                CuratedRow(store: store, model: model)
            }
        }
    }
}

private struct CuratedRow: View {
    @Bindable var store: StoreOf<ModelDownloadFeature>
    let model: CuratedModelInfo

    var isSelected: Bool {
        let selected = store.hexSettings.selectedModel
        if model.internalName.contains("*") || model.internalName.contains("?") {
            return fnmatch(model.internalName, selected, 0) == 0
        }
        // Also consider the inverse: selected may be a concrete name while the curated item is a prefix-like value
        if selected.contains("*") || selected.contains("?") {
            return fnmatch(selected, model.internalName, 0) == 0
        }
        return model.internalName == selected
    }

    var isRecommended: Bool {
        store.recommendedModel == model.internalName
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
                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor)
                                )
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
                                store.send(.selectModel(model.internalName))
                                store.send(.downloadSelectedModel)
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
    }
}

// Removed multilingual/English badge — all curated entries here are multilingual.

private struct FooterView: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>

	var body: some View {
		if store.isDownloading, store.downloadingModelName == store.hexSettings.selectedModel {
			VStack(alignment: .leading) {
				Text("Downloading model...")
					.font(.caption)
				ProgressView(value: store.downloadProgress)
					.tint(.blue)
			}
		} else {
			HStack {
				if let selected = store.curatedModels.first(where: { $0.internalName == store.hexSettings.selectedModel }) {
					Text("Selected: \(selected.displayName)")
						.font(.caption)
				}
				Spacer()
				if store.anyModelDownloaded {
					Button("Show Models Folder") {
						store.send(.openModelLocation)
					}
					.font(.caption)
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				}
				if store.selectedModelIsDownloaded {
					Button("Delete", role: .destructive) {
						store.send(.deleteSelectedModel)
					}
					.font(.caption)
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				} else if !store.selectedModel.isEmpty {
					Button("Download") {
						store.send(.downloadSelectedModel)
					}
					.font(.caption)
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
				}
			}
			.enableInjection()
		}
	}
}
