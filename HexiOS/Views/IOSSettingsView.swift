import ComposableArchitecture
import HexCore
import SwiftUI

struct IOSSettingsView: View {
  @Bindable var store: StoreOf<IOSSettingsFeature>

  var body: some View {
    NavigationStack {
      Form {
        Section("Transcription Model") {
          modelSection
        }

        Section("Language") {
          languageSection
        }

        Section("Sound Effects") {
          soundSection
        }

        Section("History") {
          Toggle("Save Transcription History", isOn: Binding(
            get: { store.hexSettings.saveTranscriptionHistory },
            set: { _ in store.send(.toggleHistory) }
          ))
        }

        Section("About") {
          LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
          LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
        }
      }
      .navigationTitle("Settings")
      .task { store.send(.task) }
    }
  }

  // MARK: - Model Section

  @ViewBuilder
  private var modelSection: some View {
    let models: [CuratedModelInfo] = Array(store.modelDownload.curatedModels)
    let selected = store.hexSettings.selectedModel

    ForEach(models) { model in
      modelRow(model: model, isSelected: selected == model.internalName)
    }

    downloadSection
  }

  private func modelRow(model: CuratedModelInfo, isSelected: Bool) -> some View {
    Button {
      store.send(.modelDownload(.selectModel(model.internalName)))
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Text(model.displayName)
              .foregroundStyle(.primary)
            if let badge = model.badge {
              Text(badge)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            }
          }
          HStack(spacing: 4) {
            Text(model.size)
            Text("·")
            Text(model.storageSize)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Spacer()

        if model.isDownloaded {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.caption)
        }

        if isSelected {
          Image(systemName: "checkmark")
            .foregroundStyle(Color.accentColor)
            .fontWeight(.semibold)
        }
      }
    }
  }

  @ViewBuilder
  private var downloadSection: some View {
    let md = store.modelDownload
    if !md.selectedModelIsDownloaded {
      if md.isDownloading {
        HStack {
          ProgressView(value: md.downloadProgress)
          Button("Cancel") {
            store.send(.modelDownload(.cancelDownload))
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
        }
      } else {
        Button {
          store.send(.modelDownload(.downloadSelectedModel))
        } label: {
          Label("Download Selected Model", systemImage: "arrow.down.circle")
        }
      }
    }

    if let error = md.downloadError {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  // MARK: - Language

  @ViewBuilder
  private var languageSection: some View {
    Picker("Output Language", selection: Binding(
      get: { store.hexSettings.outputLanguage },
      set: { store.send(.setLanguage($0)) }
    )) {
      Text("Auto").tag(nil as String?)
      ForEach(Self.loadLanguages()) { language in
        Text(language.name).tag(language.code as String?)
      }
    }
  }

  // MARK: - Sound

  @ViewBuilder
  private var soundSection: some View {
    Toggle("Sound Effects", isOn: Binding(
      get: { store.hexSettings.soundEffectsEnabled },
      set: { _ in store.send(.toggleSoundEffects) }
    ))

    if store.hexSettings.soundEffectsEnabled {
      HStack {
        Image(systemName: "speaker.fill")
          .foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { store.hexSettings.soundEffectsVolume },
            set: { store.send(.setSoundVolume($0)) }
          ),
          in: 0...HexSettings.baseSoundEffectsVolume
        )
        Image(systemName: "speaker.wave.3.fill")
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Helpers

  static func loadLanguages() -> [Language] {
    guard let url = Bundle.main.url(forResource: "languages", withExtension: "json") ??
      Bundle.main.url(forResource: "languages", withExtension: "json", subdirectory: "Data"),
      let data = try? Data(contentsOf: url),
      let list = try? JSONDecoder().decode(LanguageList.self, from: data)
    else { return [] }
    return list.languages
  }
}
