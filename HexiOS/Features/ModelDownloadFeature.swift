// MARK: – ModelDownloadFeature.swift (iOS)

import ComposableArchitecture
import Dependencies
import Foundation
import HexCore
import IdentifiedCollections

// MARK: – Data Models

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

  public var badge: String? {
    if internalName == "parakeet-tdt-0.6b-v2-coreml" {
      return "BEST FOR ENGLISH"
    } else if internalName == "parakeet-tdt-0.6b-v3-coreml" {
      return "BEST FOR MULTILINGUAL"
    }
    return nil
  }

  public init(
    displayName: String, internalName: String, size: String,
    accuracyStars: Int, speedStars: Int, storageSize: String, isDownloaded: Bool
  ) {
    self.displayName = displayName
    self.internalName = internalName
    self.size = size
    self.accuracyStars = accuracyStars
    self.speedStars = speedStars
    self.storageSize = storageSize
    self.isDownloaded = isDownloaded
  }

  private enum CodingKeys: String, CodingKey {
    case displayName, internalName, size, accuracyStars, speedStars, storageSize
  }
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

// MARK: – Domain

@Reducer
public struct ModelDownloadFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    public var availableModels: IdentifiedArrayOf<ModelInfo> = []
    public var curatedModels: IdentifiedArrayOf<CuratedModelInfo> = []
    public var recommendedModel: String = ""
    public var showAllModels = false
    public var isDownloading = false
    public var downloadProgress: Double = 0
    public var downloadError: String?
    public var downloadingModelName: String?
    public var activeDownloadID: UUID?

    var selectedModel: String { hexSettings.selectedModel }
    var selectedModelIsDownloaded: Bool {
      availableModels[id: selectedModel]?.isDownloaded ?? false
    }
    var anyModelDownloaded: Bool {
      availableModels.contains(where: { $0.isDownloaded })
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case fetchModels
    case selectModel(String)
    case toggleModelDisplay
    case downloadSelectedModel
    case modelsLoaded(recommended: String, available: [ModelInfo])
    case downloadProgress(Double)
    case downloadCompleted(Result<String, Error>)
    case cancelDownload
    case deleteSelectedModel
    case openModelLocation
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.continuousClock) var clock

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce(reduce)
  }

  private func resolvePattern(_ pattern: String, from available: [ModelInfo]) -> String? {
    ModelPatternMatcher.resolvePattern(pattern, from: available.map { ($0.name, $0.isDownloaded) })
  }

  private func curatedDisplayName(for model: String, curated: IdentifiedArrayOf<CuratedModelInfo>) -> String {
    if let match = curated.first(where: { ModelPatternMatcher.matches($0.internalName, model) }) {
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
    case .binding:
      return .none

    case .toggleModelDisplay:
      state.showAllModels.toggle()
      return .none

    case let .selectModel(model):
      let resolved = resolvePattern(model, from: Array(state.availableModels)) ?? model
      state.$hexSettings.withLock { $0.selectedModel = resolved }
      updateBootstrapState(&state)
      return .none

    case .fetchModels:
      return .run { send in
        do {
          let recommended = try await transcription.getRecommendedModels().default
          let names = try await transcription.getAvailableModels()
          let infos = try await withThrowingTaskGroup(of: ModelInfo.self) { group -> [ModelInfo] in
            for name in names {
              group.addTask {
                ModelInfo(name: name, isDownloaded: await transcription.isModelDownloaded(name))
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

      if state.hexSettings.selectedModel.contains("*") || state.hexSettings.selectedModel.contains("?") {
        if let resolved = resolvePattern(state.hexSettings.selectedModel, from: available) {
          state.$hexSettings.withLock { $0.selectedModel = resolved }
        }
      }

      var curated = CuratedModelLoader.load()
      for idx in curated.indices {
        let internalName = curated[idx].internalName
        if let match = available.first(where: { ModelPatternMatcher.matches(internalName, $0.name) }) {
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
        state.$hexSettings.withLock { $0.hasCompletedModelBootstrap = true }
        state.downloadError = nil
      case let .failure(err):
        let ns = err as NSError
        var message = ns.localizedDescription
        if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL, let host = url.host {
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
      // No-op on iOS — no Finder
      return .none
    }
  }
}

extension ModelDownloadFeature.State {
  var preferredParakeetIdentifier: String {
    (prefersEnglishParakeet ? ParakeetModel.englishV2 : ParakeetModel.multilingualV3).identifier
  }

  private var prefersEnglishParakeet: Bool {
    guard let language = hexSettings.outputLanguage?.lowercased(), !language.isEmpty else { return false }
    return language.hasPrefix("en")
  }
}
