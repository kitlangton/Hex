// MARK: – ConversationModelDownloadView.swift

// SwiftUI view for displaying and managing conversation model downloads.
// Shows both Moshi and PersonaPlex models with selection and download controls.

import ComposableArchitecture
import Inject
import SwiftUI

// MARK: - Main View

public struct ConversationModelDownloadView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<ConversationModelDownloadFeature>

    public init(store: StoreOf<ConversationModelDownloadFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            Text("Conversation Models")
                .font(.headline)
                .foregroundStyle(.secondary)

            // Model list
            VStack(spacing: 12) {
                ForEach(ConversationModelType.allCases) { modelType in
                    ConversationModelRowView(
                        modelType: modelType,
                        downloadState: store.modelDownloadStates[modelType] ?? .init(),
                        isSelected: store.selectedModelType == modelType,
                        onSelect: { store.send(.selectModel(modelType)) },
                        onDownload: { store.send(.downloadModel(modelType)) },
                        onCancel: { store.send(.cancelDownload(modelType)) },
                        onOpenLocation: { store.send(.openModelLocation(modelType)) }
                    )
                }
            }
        }
        .task {
            store.send(.task)
        }
        .enableInjection()
    }
}

// MARK: - Model Row

struct ConversationModelRowView: View {
    @ObserveInjection var inject

    let modelType: ConversationModelType
    let downloadState: ConversationModelDownloadFeature.State.ModelDownloadState
    let isSelected: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onOpenLocation: () -> Void

    @State private var isVoicePresetsExpanded = false

    private var modelColor: Color {
        switch modelType {
        case .moshi: return .purple
        case .personaPlex: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(alignment: .center, spacing: 12) {
                // Selection radio button
                Button {
                    if downloadState.isModelDownloaded {
                        onSelect()
                    }
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? modelColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!downloadState.isModelDownloaded)
                .help(downloadState.isModelDownloaded ? "Select this model" : "Download model first")

                // Model icon
                Image(systemName: modelType.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(modelColor)
                    .frame(width: 36)

                // Title and description
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(modelType.displayName)
                            .font(.headline)

                        if isSelected && downloadState.isModelDownloaded {
                            Text("ACTIVE")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(modelColor)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(modelType.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Error message
                    if let error = downloadState.downloadError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer(minLength: 12)

                // Size and status
                HStack(spacing: 12) {
                    Text(modelType.estimatedSize)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .frame(width: 80, alignment: .trailing)

                    // Download/Progress/Downloaded indicator
                    statusIndicator
                }
            }
            .padding(12)

            // Voice presets section (PersonaPlex only)
            if modelType.supportsVoicePresets && downloadState.isModelDownloaded {
                VoicePresetsSection(
                    isExpanded: $isVoicePresetsExpanded,
                    modelColor: modelColor
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? modelColor.opacity(0.5) : Color.gray.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(.rect)
        .contextMenu {
            if downloadState.isDownloading {
                Button("Cancel Download", role: .destructive) {
                    onCancel()
                }
            }
            if downloadState.isModelDownloaded {
                Button("Show in Finder") {
                    onOpenLocation()
                }
            }
        }
        .enableInjection()
    }

    @ViewBuilder
    private var statusIndicator: some View {
        ZStack {
            if downloadState.isDownloading {
                VStack(spacing: 2) {
                    ProgressView(value: downloadState.downloadProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(modelColor)
                        .frame(width: 24, height: 24)

                    Text("\(Int(downloadState.downloadProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("Downloading... \(Int(downloadState.downloadProgress * 100))%")
            } else if downloadState.isModelDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 24, height: 24)
                    .help("Downloaded and ready")
            } else {
                Button {
                    onDownload()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(modelColor)
                }
                .buttonStyle(.borderless)
                .help("Download model")
                .frame(width: 24, height: 24)
            }
        }
    }
}

// MARK: - Voice Presets Section

struct VoicePresetsSection: View {
    @Binding var isExpanded: Bool
    let modelColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toggle button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("18 Voice Presets")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Presets grid
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Group by style
                    ForEach(VoicePreset.Style.allCases, id: \.self) { style in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(style.displayName)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.tertiary)

                            // Gender rows
                            ForEach(VoicePreset.Gender.allCases, id: \.self) { gender in
                                HStack(spacing: 6) {
                                    Text(gender.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 50, alignment: .leading)

                                    ForEach(presetsFor(style: style, gender: gender)) { preset in
                                        VoicePresetChip(preset: preset, modelColor: modelColor)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor).opacity(0.5))
                )
            }
        }
    }

    private func presetsFor(style: VoicePreset.Style, gender: VoicePreset.Gender) -> [VoicePreset] {
        VoicePreset.allPresets.filter { $0.style == style && $0.gender == gender }
    }
}

// MARK: - Voice Preset Chip

struct VoicePresetChip: View {
    let preset: VoicePreset
    let modelColor: Color

    var body: some View {
        Text(preset.id)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(modelColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(modelColor.opacity(0.1))
            )
            .help(preset.name)
    }
}

// MARK: - Compact Status Badge

/// A compact status badge for use in the mode settings section
struct ConversationModelStatusBadge: View {
    @Shared(.conversationModelBootstrapState) var bootstrapState: ConversationModelBootstrapState
    let modelType: ConversationModelType?

    init(modelType: ConversationModelType? = nil) {
        self.modelType = modelType
    }

    private var effectiveModelType: ConversationModelType {
        modelType ?? bootstrapState.selectedModelType
    }

    private var state: ConversationModelDownloadState {
        bootstrapState.state(for: effectiveModelType)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            if state.isDownloading {
                Text("\(Int(state.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.1))
        )
    }

    private var statusColor: Color {
        if state.lastError != nil {
            return .red
        } else if state.isDownloading {
            return .orange
        } else if state.isModelReady {
            return .green
        } else {
            return .yellow
        }
    }

    private var statusText: String {
        if state.lastError != nil {
            return "Error"
        } else if state.isModelReady {
            return "Ready"
        } else {
            return "Not Downloaded"
        }
    }
}

// MARK: - Inline Model Section

/// An inline view for conversation model download, suitable for embedding in settings
struct ConversationModelInlineView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<ConversationModelDownloadFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            Label {
                HStack {
                    Text("\(store.selectedModelType.displayName) Model")
                    Spacer()
                    ConversationModelStatusBadge(modelType: store.selectedModelType)
                }
            } icon: {
                Image(systemName: "cpu")
            }

            let downloadState = store.modelDownloadStates[store.selectedModelType] ?? .init()

            // Progress/action row when downloading or not downloaded
            if downloadState.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: downloadState.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(store.selectedModelType == .moshi ? .purple : .blue)

                    HStack {
                        Text("Downloading... \(Int(downloadState.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Cancel") {
                            store.send(.cancelDownload(store.selectedModelType))
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.leading, 24)
            } else if !downloadState.isModelDownloaded {
                HStack {
                    Text(store.selectedModelType.estimatedSize)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button {
                        store.send(.downloadModel(store.selectedModelType))
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(store.selectedModelType == .moshi ? .purple : .blue)
                }
                .padding(.leading, 24)
            }

            // Error message
            if let error = downloadState.downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 24)
            }
        }
        .task {
            store.send(.task)
        }
        .enableInjection()
    }
}

// MARK: - Previews

#Preview("Download View") {
    ConversationModelDownloadView(
        store: Store(
            initialState: ConversationModelDownloadFeature.State()
        ) {
            ConversationModelDownloadFeature()
        }
    )
    .padding()
    .frame(width: 500)
}

#Preview("Model Row - Moshi Not Downloaded") {
    ConversationModelRowView(
        modelType: .moshi,
        downloadState: .init(),
        isSelected: false,
        onSelect: {},
        onDownload: {},
        onCancel: {},
        onOpenLocation: {}
    )
    .padding()
    .frame(width: 500)
}

#Preview("Model Row - PersonaPlex Downloaded") {
    ConversationModelRowView(
        modelType: .personaPlex,
        downloadState: .init(isModelDownloaded: true),
        isSelected: true,
        onSelect: {},
        onDownload: {},
        onCancel: {},
        onOpenLocation: {}
    )
    .padding()
    .frame(width: 500)
}

#Preview("Inline View") {
    Form {
        ConversationModelInlineView(
            store: Store(
                initialState: ConversationModelDownloadFeature.State()
            ) {
                ConversationModelDownloadFeature()
            }
        )
    }
    .formStyle(.grouped)
    .frame(width: 450)
}
