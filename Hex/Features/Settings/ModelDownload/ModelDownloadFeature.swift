// MARK: – ModelDownloadFeature.swift

// A full‐featured TCA reducer for managing on‑device ML models.
// Dependencies: ComposableArchitecture, IdentifiedCollections, Dependencies

import AppKit
import ComposableArchitecture
import Darwin
import Dependencies
import HexCore
import IdentifiedCollections

// ──────────────────────────────────────────────────────────────────────────

// MARK: – Data Models

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
		catch { assertionFailure("Failed to decode models.json – \(error)"); return [] }
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
			// Ensure our curated Parakeet options are visible even if WhisperKit doesn't list them
			var availablePlus = available
			for model in ParakeetModel.allCases.reversed() {
				if !availablePlus.contains(where: { $0.name == model.identifier }) {
					availablePlus.insert(ModelInfo(name: model.identifier, isDownloaded: false), at: 0)
				}
			}

			if availablePlus.contains(where: { $0.name == state.preferredParakeetIdentifier }) {
				state.recommendedModel = state.preferredParakeetIdentifier
			} else {
				state.recommendedModel = recommended
			}
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
			return .none

		// MARK: – Download

		case .downloadSelectedModel:
			guard !state.hexSettings.selectedModel.isEmpty else { return .none }
			state.downloadError = nil
			state.isDownloading = true
			let selected = state.hexSettings.selectedModel
			state.downloadingModelName = selected
			state.activeDownloadID = UUID()
			let downloadID = state.activeDownloadID!
			let displayName = curatedDisplayName(for: selected, curated: state.curatedModels)
			state.$modelBootstrapState.withLock {
				$0.modelIdentifier = selected
				$0.modelDisplayName = displayName
				$0.isModelReady = false
				$0.progress = 0
				$0.lastError = nil
			}
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
			if state.downloadingModelName == state.hexSettings.selectedModel {
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
				state.downloadError = nil
			case let .failure(err):
				let ns = err as NSError
				var message = ns.localizedDescription
				if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
				   let host = url.host
				{
					message += " (\(host))"
				} else if let str = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
				          let u = URL(string: str), let host = u.host
				{
					message += " (\(host))"
				}
				state.downloadError = message
				failureMessage = message
			}
			state.$modelBootstrapState.withLock { bootstrap in
				if let failureMessage {
					bootstrap.isModelReady = false
					bootstrap.lastError = failureMessage
					bootstrap.progress = 0
				} else {
					bootstrap.isModelReady = true
					bootstrap.lastError = nil
					bootstrap.progress = 1
				}
			}
			updateBootstrapState(&state)
			return .none

		case .cancelDownload:
			guard let id = state.activeDownloadID else { return .none }
			state.isDownloading = false
			state.downloadingModelName = nil
			state.activeDownloadID = nil
			state.$modelBootstrapState.withLock {
				$0.progress = 0
				$0.isModelReady = false
				$0.lastError = "Download cancelled"
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

extension ModelDownloadFeature.State {
	struct RecommendationBadge: Equatable {
		let text: String
		let isPrimary: Bool
	}

	var recommendationBadges: [String: RecommendationBadge] {
		var badges: [String: RecommendationBadge] = [:]
		for model in ParakeetModel.allCases {
			badges[model.identifier] = RecommendationBadge(
				text: model.recommendationLabel,
				isPrimary: model.isEnglishOnly ? prefersEnglishParakeet : !prefersEnglishParakeet
			)
		}
		return badges
	}

	var preferredParakeetIdentifier: String {
		(prefersEnglishParakeet ? ParakeetModel.englishV2 : ParakeetModel.multilingualV3).identifier
	}

	private var prefersEnglishParakeet: Bool {
		guard let language = hexSettings.outputLanguage?.lowercased(), !language.isEmpty else {
			return false
		}
		return language.hasPrefix("en")
	}
}
