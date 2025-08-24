//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import ComposableArchitecture
import Dependencies
import SwiftUI

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable {
    case settings
    case history
    case about
  }

  @ObservableState
  struct State {
    var transcription: TranscriptionFeature.State = .init()
    var settings: SettingsFeature.State = .init()
    var history: HistoryFeature.State = .init()
    var activeTab: ActiveTab = .settings
    var hasCheckedForModel = false
    var isDownloadingInitialModel = false
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case setActiveTab(ActiveTab)
    case onAppear
    case checkAndDownloadInitialModel
    case initialModelDownloadComplete
  }

  @Dependency(\.transcription) var transcription
  
  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case .transcription:
        return .none
      case .settings:
        return .none
      case .history(.navigateToSettings):
        state.activeTab = .settings
        return .none
      case .history:
        return .none
      case let .setActiveTab(tab):
        state.activeTab = tab
        return .none
        
      case .onAppear:
        guard !state.hasCheckedForModel else { return .none }
        state.hasCheckedForModel = true
        return .send(.checkAndDownloadInitialModel)
        
      case .checkAndDownloadInitialModel:
        @Shared(.hexSettings) var hexSettings: HexSettings
        let currentSelectedModel = hexSettings.selectedModel
        
        return .run { send in
          // First check if the currently selected model is already downloaded
          let hasSelectedModel = await transcription.isModelDownloaded(currentSelectedModel)
          
          if hasSelectedModel {
            print("[AppFeature] Selected model already downloaded, no action needed")
            return
          }
          
          // Check if ANY model is downloaded
          let availableModels = try? await transcription.getAvailableModels()
          var hasAnyModel = false
          if let models = availableModels {
            for model in models {
              if await transcription.isModelDownloaded(model) {
                hasAnyModel = true
                break
              }
            }
          }
          
          if !hasAnyModel {
            // No models downloaded, download the recommended one
            do {
              // Get the system-recommended model
              let recommendedModel = try await transcription.getRecommendedModels().default
              print("[AppFeature] No models found, downloading recommended model for first-time setup: \(recommendedModel)")
              
              // Update settings to use recommended model
              await MainActor.run {
                $hexSettings.withLock { $0.selectedModel = recommendedModel }
              }
              
              // Download the recommended model
              try await transcription.downloadModel(recommendedModel) { progress in
                // We could show progress if desired, but keeping it silent for now
                print("[AppFeature] Initial model download progress: \(progress.fractionCompleted)")
              }
              await send(.initialModelDownloadComplete)
            } catch {
              print("[AppFeature] Failed to download initial model: \(error)")
            }
          }
        }
        
      case .initialModelDownloadComplete:
        state.isDownloadingInitialModel = false
        print("[AppFeature] Initial model download complete")
        return .none
      }
    }
  }
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.activeTab) {
        Button {
          store.send(.setActiveTab(.settings))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }.buttonStyle(.plain)
          .tag(AppFeature.ActiveTab.settings)

        Button {
          store.send(.setActiveTab(.history))
        } label: {
          Label("History", systemImage: "clock")
        }.buttonStyle(.plain)
          .tag(AppFeature.ActiveTab.history)
          
        Button {
          store.send(.setActiveTab(.about))
        } label: {
          Label("About", systemImage: "info.circle")
        }.buttonStyle(.plain)
          .tag(AppFeature.ActiveTab.about)
      }
    } detail: {
      switch store.state.activeTab {
      case .settings:
        SettingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Settings")
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
      }
    }
    .enableInjection()
    .onAppear {
      store.send(.onAppear)
    }
  }
}
