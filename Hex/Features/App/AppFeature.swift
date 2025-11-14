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
    case transformations
    case history
    case about
  }

  @ObservableState
  struct State {
    var transcription: TranscriptionFeature.State = .init()
    var settings: SettingsFeature.State = .init()
    var history: HistoryFeature.State = .init()
    var activeTab: ActiveTab = .settings
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case setActiveTab(ActiveTab)
    case task
    case pasteLastTranscript
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
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
        
      case .task:
        return .merge(
          startPasteLastTranscriptMonitoring(),
          ensureSelectedModelReadiness()
        )
        
      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = transcriptionHistory.history.first?.text else {
          return .none
        }
        return .run { _ in
          await pasteboard.paste(lastTranscript)
        }
        
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
      }
    }
  }
  
  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if user is setting a hotkey
        if isSettingPasteLastTranscriptHotkey {
          return false
        }

        // Check if this matches the paste last transcript hotkey
        guard let pasteHotkey = hexSettings.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers == pasteHotkey.modifiers else {
          return false
        }

        // Trigger paste action - use MainActor to avoid escaping send
        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true // Intercept the key event
      }
    }
  }

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { _ in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else { return }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.isAutoDownloading = false
          state.progress = 1
        } else if !state.isAutoDownloading {
          state.progress = 0
        }
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
          store.send(.setActiveTab(.transformations))
        } label: {
          Label("Transformations", systemImage: "wand.and.stars")
        }.buttonStyle(.plain)
          .tag(AppFeature.ActiveTab.transformations)

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
      case .transformations:
        TextTransformationSectionView(store: store.scope(state: \.settings.textTransformation, action: \.settings.textTransformation))
          .navigationTitle("Text Transformations")
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
      }
    }
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}
