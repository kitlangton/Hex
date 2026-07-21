import ComposableArchitecture
import HexCore
import XCTest

@testable import Hex

@MainActor
final class ModelDownloadFeatureTests: XCTestCase {
  func testPersistedModelDisplaysWhileAvailabilityLoads() {
    let state = makeState(selectedModel: ParakeetModel.englishV2.identifier)

    XCTAssertTrue(state.availableModels.isEmpty)
    XCTAssertEqual(state.selectedModelNameForDisplay, ParakeetModel.englishV2.identifier)
  }

  func testSuggestedParakeetFollowsOutputLanguage() {
    var state = makeState(selectedModel: "")
    XCTAssertEqual(state.preferredParakeetIdentifier, ParakeetModel.englishV2.identifier)

    state.$hexSettings.withLock { $0.outputLanguage = "en" }
    XCTAssertEqual(state.preferredParakeetIdentifier, ParakeetModel.englishV2.identifier)

    state.$hexSettings.withLock { $0.outputLanguage = "fr" }
    XCTAssertEqual(state.preferredParakeetIdentifier, ParakeetModel.multilingualV3.identifier)
  }

  func testFailedModelRefreshPreservesInstalledSelection() async {
    var state = makeState(selectedModel: "installed-model")
    state.availableModels = [ModelInfo(name: "installed-model", isDownloaded: true)]

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    } withDependencies: {
      $0.transcription.getRecommendedModels = { throw TestError() }
      $0.transcription.getAvailableModels = { [] }
    }

    await store.send(.fetchModels) {
      $0.isLoadingModels = true
    }
    await store.receive(\.modelsLoadFailed) {
      $0.isLoadingModels = false
    }

    XCTAssertEqual(store.state.hexSettings.selectedModel, "installed-model")
    XCTAssertTrue(store.state.availableModels[id: "installed-model"]?.isDownloaded == true)
  }

  func testStaleDownloadUpdatesAreIgnored() async {
    let currentID = UUID()
    var state = makeState(selectedModel: "installed-model")
    state.isDownloading = true
    state.downloadingModelName = "new-model"
    state.activeDownloadID = currentID
    state.downloadProgress = 0.25

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }

    await store.send(.downloadProgress(id: UUID(), progress: 0.9))
    await store.send(.downloadCompleted(id: UUID(), result: .success("other-model")))

    XCTAssertEqual(store.state.activeDownloadID, currentID)
    XCTAssertEqual(store.state.downloadProgress, 0.25)
    XCTAssertEqual(store.state.hexSettings.selectedModel, "installed-model")
  }

  func testModelsLoadedNeverClearsSelectionWhenNothingDetected() async {
    // Regression: 0.8.0 cleared selectedModel to "" when an availability scan
    // came back empty (e.g. after FluidAudio moved its cache directory),
    // permanently breaking transcription with no visible error.
    var state = makeState(selectedModel: ParakeetModel.englishV2.identifier)
    state.availableModels = []

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }
    store.exhaustivity = .off

    await store.send(.modelsLoaded(recommended: "", available: []))

    XCTAssertEqual(store.state.hexSettings.selectedModel, ParakeetModel.englishV2.identifier)
  }

  func testSelectedModelIsDownloadedMatchesPatterns() {
    var state = makeState(selectedModel: "distil*large-v3")
    state.availableModels = [
      ModelInfo(name: "distil-whisper_distil-large-v3", isDownloaded: true)
    ]
    XCTAssertTrue(state.selectedModelIsDownloaded)

    state.availableModels = [
      ModelInfo(name: "distil-whisper_distil-large-v3", isDownloaded: false)
    ]
    XCTAssertFalse(state.selectedModelIsDownloaded)

    var emptyState = makeState(selectedModel: "")
    emptyState.availableModels = [ModelInfo(name: "some-model", isDownloaded: true)]
    XCTAssertFalse(emptyState.selectedModelIsDownloaded)
  }

  func testDeletingAnotherModelDoesNotChangeSelection() async {
    var state = makeState(selectedModel: "selected-model")
    state.availableModels = [
      ModelInfo(name: "selected-model", isDownloaded: true),
      ModelInfo(name: "other-model", isDownloaded: true),
    ]

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    } withDependencies: {
      $0.transcription.deleteModel = { _ in
        try await Task.sleep(for: .seconds(60))
      }
    }

    await store.send(.deleteModel("other-model"))
    XCTAssertEqual(store.state.hexSettings.selectedModel, "selected-model")
    await store.skipInFlightEffects()
  }

  // MARK: – Apple Speech (SpeechAnalyzer) row

  func testFilterForPlatformDropsAppleSpeechOnOlderOS() {
    let models = [makeAppleSpeechCuratedInfo(), makeParakeetCuratedInfo()]

    let filtered = CuratedModelLoader.filterForPlatform(models, osSupportsAppleSpeech: false)
    XCTAssertFalse(filtered.contains(where: \.isAppleSpeech))
    XCTAssertTrue(filtered.contains(where: \.isParakeet))

    let kept = CuratedModelLoader.filterForPlatform(models, osSupportsAppleSpeech: true)
    XCTAssertTrue(kept.contains(where: \.isAppleSpeech))
  }

  func testModelsLoadedDropsAppleRowWhenEngineUnsupported() async {
    // The engine advertises itself by injecting its identifier into the
    // available list; when absent (old hardware, Xcode 16 build), the curated
    // row must disappear.
    let state = makeState(selectedModel: ParakeetModel.multilingualV3.identifier)

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }
    store.exhaustivity = .off

    await store.send(.modelsLoaded(
      recommended: "",
      available: [ModelInfo(name: ParakeetModel.multilingualV3.identifier, isDownloaded: true)]
    ))

    XCTAssertFalse(store.state.curatedModels.contains(where: \.isAppleSpeech))
  }

  func testModelsLoadedKeepsAppleRowAndMergesInstalledState() async throws {
    // Requires the bundled apple row, which CuratedModelLoader filters out on
    // hosts older than macOS 26.
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("Apple Speech curated row only exists on macOS 26+")
    }
    let state = makeState(selectedModel: ParakeetModel.multilingualV3.identifier)

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }
    store.exhaustivity = .off

    await store.send(.modelsLoaded(
      recommended: "",
      available: [ModelInfo(name: AppleSpeechModel.system.identifier, isDownloaded: true)]
    ))

    let appleRow = store.state.curatedModels.first(where: \.isAppleSpeech)
    XCTAssertNotNil(appleRow)
    XCTAssertTrue(appleRow?.isDownloaded == true)
  }

  func testAppleSelectionSurvivesMissingLocaleAssets() async throws {
    // When Apple Speech is selected and its row is present, "not downloaded"
    // only means the current language's locale pack is missing — the engine
    // selection must not silently switch to another installed model.
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("Apple Speech curated row only exists on macOS 26+")
    }
    let state = makeState(selectedModel: AppleSpeechModel.system.identifier)

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }
    store.exhaustivity = .off

    await store.send(.modelsLoaded(
      recommended: "",
      available: [
        ModelInfo(name: AppleSpeechModel.system.identifier, isDownloaded: false),
        ModelInfo(name: ParakeetModel.multilingualV3.identifier, isDownloaded: true),
      ]
    ))

    XCTAssertEqual(store.state.hexSettings.selectedModel, AppleSpeechModel.system.identifier)
  }

  func testAppleSelectionAutoSwitchesWhenEngineAbsent() async {
    // OS downgrade / unsupported hardware: the persisted apple selection heals
    // to an installed local model via the existing fallback logic.
    let state = makeState(selectedModel: AppleSpeechModel.system.identifier)

    let store = TestStore(initialState: state) {
      ModelDownloadFeature()
    }
    store.exhaustivity = .off

    await store.send(.modelsLoaded(
      recommended: "",
      available: [ModelInfo(name: ParakeetModel.multilingualV3.identifier, isDownloaded: true)]
    ))

    XCTAssertEqual(store.state.hexSettings.selectedModel, ParakeetModel.multilingualV3.identifier)
  }

  private func makeAppleSpeechCuratedInfo(isDownloaded: Bool = false) -> CuratedModelInfo {
    CuratedModelInfo(
      displayName: "Apple Speech",
      internalName: AppleSpeechModel.system.identifier,
      size: "Multilingual",
      accuracyStars: 4,
      speedStars: 5,
      storageSize: "Managed by macOS",
      isDownloaded: isDownloaded
    )
  }

  private func makeParakeetCuratedInfo() -> CuratedModelInfo {
    CuratedModelInfo(
      displayName: "Parakeet TDT v3",
      internalName: ParakeetModel.multilingualV3.identifier,
      size: "Multilingual",
      accuracyStars: 5,
      speedStars: 5,
      storageSize: "650MB",
      isDownloaded: false
    )
  }

  private func makeState(selectedModel: String) -> ModelDownloadFeature.State {
    var settings = HexSettings()
    settings.selectedModel = selectedModel
    settings.hasCompletedModelBootstrap = true
    return ModelDownloadFeature.State(
      hexSettings: Shared(value: settings),
      modelBootstrapState: Shared(value: .init(isModelReady: true))
    )
  }
}

private struct TestError: Error {}
