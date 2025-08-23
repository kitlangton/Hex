// MARK: – ModelDownloadFeature.swift

// A full‐featured TCA reducer + SwiftUI view for managing on‑device ML models.
// The file is single‑purpose but split into logical sections for clarity.
// Dependencies: ComposableArchitecture, IdentifiedCollections, Dependencies, SwiftUI

import ComposableArchitecture
import Dependencies
import IdentifiedCollections
import SwiftUI

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
		// Effects
		case modelsLoaded(recommended: String, available: [ModelInfo])
		case downloadProgress(id: UUID, progress: Double)
		case downloadCompleted(Result<String, Error>)

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


	private func reduce(state: inout State, action: Action) -> Effect<Action> {
		switch action {
		// MARK: – UI bindings

		case .binding:
			return .none

		case .toggleModelDisplay:
			state.showAllModels.toggle()
			return .none

		case let .selectModel(model):
			state.$hexSettings.withLock { $0.selectedModel = model }
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
			state.recommendedModel = recommended
			state.availableModels = IdentifiedArrayOf(uniqueElements: available)
			// Merge curated + download status
			var curated = CuratedModelLoader.load()
			for idx in curated.indices {
				curated[idx].isDownloaded = available.first(where: { $0.name == curated[idx].internalName })?.isDownloaded ?? false
			}
			state.curatedModels = IdentifiedArrayOf(uniqueElements: curated)
			return .none

		// MARK: – Download

		case .downloadSelectedModel:
			guard !state.selectedModel.isEmpty else { return .none }
			state.downloadError = nil
			state.isDownloading = true
			state.downloadingModelName = state.selectedModel
			let downloadID = UUID()
			state.activeDownloadID = downloadID
			state.downloadProgress = 0
			return .run { [state, downloadID] send in
				do {
					// Assume downloadModel returns AsyncThrowingStream<Double, Error>
					try await transcription.downloadModel(state.selectedModel) { progress in
						Task { await send(.downloadProgress(id: downloadID, progress: progress.fractionCompleted)) }
					}
					await send(.downloadCompleted(.success(state.selectedModel)))
				} catch {
					await send(.downloadCompleted(.failure(error)))
				}
			}

		case let .downloadProgress(id, progress):
			guard state.activeDownloadID == id else { return .none }
			state.downloadProgress = progress
			return .none

		case let .downloadCompleted(result):
			state.isDownloading = false
			state.downloadingModelName = nil
			state.activeDownloadID = nil
			switch result {
			case let .success(name):
				state.availableModels[id: name]?.isDownloaded = true
				if let idx = state.curatedModels.firstIndex(where: { $0.internalName == name }) {
					state.curatedModels[idx].isDownloaded = true
				}
			case let .failure(err):
				state.downloadError = err.localizedDescription
			}
			return .none

		case .deleteSelectedModel:
			guard !state.selectedModel.isEmpty else { return .none }
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
			HeaderView(store: store)
			Group {
				if store.showAllModels {
					AllModelsPicker(store: store)
				} else {
					CuratedList(store: store)
				}
			}
			if let err = store.downloadError {
				Text("Download Error: \(err)")
					.foregroundColor(.red)
					.font(.caption)
			}
			FooterView(store: store)
		}
		.task {
			if store.availableModels.isEmpty {
				store.send(.fetchModels)
			}
		}
		.onAppear {
			store.send(.fetchModels)
		}
	}
}

// MARK: – Subviews

private struct HeaderView: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>

	var body: some View {
		HStack {
			Text(store.showAllModels ? "Showing all models" : "Showing recommended models")
				.font(.caption)
				.foregroundColor(.secondary)
			Spacer()
			Button(
				store.showAllModels ? "Show Recommended" : "Show All Models"
			) {
				store.send(.toggleModelDisplay)
			}
			.font(.caption)
		}
	}
}

private struct AllModelsPicker: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>

	var body: some View {
		Picker(
			"Selected Model",
			selection: Binding(
				get: { store.hexSettings.selectedModel },
				set: { store.send(.selectModel($0)) }
			)
		) {
			ForEach(store.availableModels) { info in
				HStack {
					Text(
						info.name == store.recommendedModel
							? "\(info.name) (Recommended)"
							: info.name
					)
					Spacer()
					if info.isDownloaded {
						Image(systemName: "checkmark.circle.fill")
							.foregroundColor(.green)
					}
				}
				.tag(info.name)
			}
		}
		.pickerStyle(.menu)
	}
}

private struct CuratedList: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Header
			HStack(alignment: .bottom) {
				Text("Model")
					.frame(minWidth: 80, alignment: .leading)
					.font(.caption.bold())
				Spacer()
				Text("Accuracy")
					.frame(minWidth: 80, alignment: .leading)
					.font(.caption.bold())
				Spacer()
				Text("Speed")
					.frame(minWidth: 80, alignment: .leading)
					.font(.caption.bold())
				Spacer()
				Text("Size")
					.frame(minWidth: 70, alignment: .leading)
					.font(.caption.bold())
			}
			.padding(.horizontal, 8)

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
		model.internalName == store.hexSettings.selectedModel
	}

	var body: some View {
		Button(
			action: { store.send(.selectModel(model.internalName)) }
		) {
			HStack {
				HStack {
					Text(model.displayName)
						.font(.headline)
					if model.isDownloaded {
						Image(systemName: "checkmark.circle.fill")
							.foregroundColor(.green)
					}
					if isSelected {
						Image(systemName: "checkmark")
							.foregroundColor(.blue)
					}
				}
				.frame(minWidth: 80, alignment: .leading)
				Spacer()
				StarRatingView(model.accuracyStars)
					.frame(minWidth: 80, alignment: .leading)
				Spacer()
				StarRatingView(model.speedStars)
					.frame(minWidth: 80, alignment: .leading)
				Spacer()
				Text(model.storageSize)
					.foregroundColor(.secondary)
					.frame(minWidth: 70, alignment: .leading)
			}
			.padding(8)
			.background(
				RoundedRectangle(cornerRadius: 8)
					.fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
			)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(
						isSelected
							? Color.blue.opacity(0.3)
							: Color.gray.opacity(0.2)
					)
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
	}
}

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
