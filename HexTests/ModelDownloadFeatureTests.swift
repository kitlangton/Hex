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
