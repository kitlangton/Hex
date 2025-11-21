import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

struct LLMProviderSectionView: View {
    @Bindable var store: StoreOf<SettingsFeature>
    private let modelRegistry = LLMModelRegistry.shared

    private var preferredProviderBinding: Binding<String> {
        Binding(
            get: { store.hexSettings.preferredLLMProviderID ?? "" },
            set: { newValue in
                store.hexSettings.preferredLLMProviderID = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private var preferredModelBinding: Binding<String> {
        Binding(
            get: { store.hexSettings.preferredLLMModelID ?? "" },
            set: { newValue in
                store.hexSettings.preferredLLMModelID = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private var selectedProvider: LLMProvider? {
        if let preferredID = store.hexSettings.preferredLLMProviderID,
           let provider = store.textTransformations.providers.first(where: { $0.id == preferredID }) {
            return provider
        }
        return store.textTransformations.providers.first
    }

    private var modelsForSelectedProvider: [LLMProviderModelMetadata] {
        guard let provider = selectedProvider else { return [] }
        return modelRegistry.models(for: provider.type)
    }

    var body: some View {
        Section("LLM Providers") {
            if store.textTransformations.providers.isEmpty {
                Text("No providers configured. Open the configuration file to add Claude or Ollama entries.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Configuration File") {
                    NSWorkspace.shared.open(.textTransformationsURL)
                }
            } else {
                providerSummaries

                Button("Open Configuration File") {
                    NSWorkspace.shared.open(.textTransformationsURL)
                }
            }
        }
    }

    private var providerSummaries: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.textTransformations.providers, id: \.id) { provider in
                let capabilities = LLMProviderCapabilitiesResolver.capabilities(for: provider)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName ?? provider.id)
                            .font(.subheadline)
                        Text(provider.type.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    capabilityBadge(for: capabilities)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func capabilityBadge(for capabilities: LLMProviderCapabilities) -> some View {
        let supportsTools = capabilities.supportsToolCalling && capabilities.toolReliability != .none
        Text(supportsTools ? "Tools" : "Text-only")
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(supportsTools ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15))
            )
            .foregroundStyle(supportsTools ? Color.blue : Color.orange)
    }
}
