// MARK: – ConversationModelDownloadView.swift

// SwiftUI view for displaying and managing MoshiKit conversation model download.

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
        VStack(alignment: .leading, spacing: 12) {
            // Error banner
            if let error = store.downloadError {
                AutoDownloadBannerView(
                    title: "Download failed",
                    subtitle: error,
                    progress: nil,
                    style: .error
                )
            }

            // Model row
            ConversationModelRow(store: store)
        }
        .task {
            store.send(.task)
        }
        .enableInjection()
    }
}

// MARK: - Model Row

struct ConversationModelRow: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<ConversationModelDownloadFeature>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Model icon
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.purple)

            // Title and description
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.modelName)
                        .font(.headline)

                    Text("CONVERSATION")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text("Full-duplex voice AI powered by Kyutai")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            // Size and status
            HStack(spacing: 12) {
                Text(store.modelSize)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(width: 60, alignment: .trailing)

                // Download/Progress/Downloaded indicator
                statusIndicator
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.18))
        )
        .contentShape(.rect)
        .contextMenu {
            if store.isDownloading {
                Button("Cancel Download", role: .destructive) {
                    store.send(.cancelDownload)
                }
            }
            if store.isModelDownloaded {
                Button("Show in Finder") {
                    store.send(.openModelLocation)
                }
            }
        }
        .enableInjection()
    }

    @ViewBuilder
    private var statusIndicator: some View {
        ZStack {
            if store.isDownloading {
                ProgressView(value: store.downloadProgress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.purple)
                    .frame(width: 24, height: 24)
                    .help("Downloading... \(Int(store.downloadProgress * 100))%")
            } else if store.isModelDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 24, height: 24)
                    .help("Downloaded and ready")
            } else {
                Button {
                    store.send(.downloadModel)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.borderless)
                .help("Download model")
                .frame(width: 24, height: 24)
            }
        }
    }
}

// MARK: - Compact Status Badge

/// A compact status badge for use in the mode settings section
struct ConversationModelStatusBadge: View {
    @Shared(.conversationModelBootstrapState) var bootstrapState: ConversationModelBootstrapState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            if bootstrapState.isDownloading {
                Text("\(Int(bootstrapState.progress * 100))%")
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
        if bootstrapState.lastError != nil {
            return .red
        } else if bootstrapState.isDownloading {
            return .orange
        } else if bootstrapState.isModelReady {
            return .green
        } else {
            return .yellow
        }
    }

    private var statusText: String {
        if bootstrapState.lastError != nil {
            return "Error"
        } else if bootstrapState.isModelReady {
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
                    Text("Moshi Model")
                    Spacer()
                    statusBadge
                }
            } icon: {
                Image(systemName: "cpu")
            }

            // Progress/action row when downloading or not downloaded
            if store.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: store.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(.purple)

                    HStack {
                        Text("Downloading... \(Int(store.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Cancel") {
                            store.send(.cancelDownload)
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.leading, 24)
            } else if !store.isModelDownloaded {
                HStack {
                    Text(store.modelSize)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button {
                        store.send(.downloadModel)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.purple)
                }
                .padding(.leading, 24)
            }

            // Error message
            if let error = store.downloadError {
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

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            if store.isDownloading {
                Text("\(Int(store.downloadProgress * 100))%")
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
        if store.downloadError != nil {
            return .red
        } else if store.isDownloading {
            return .orange
        } else if store.isModelDownloaded {
            return .green
        } else {
            return .yellow
        }
    }

    private var statusText: String {
        if store.downloadError != nil {
            return "Error"
        } else if store.isModelDownloaded {
            return "Ready"
        } else {
            return "Not Downloaded"
        }
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
    .frame(width: 450)
}

#Preview("Model Row - Not Downloaded") {
    ConversationModelRow(
        store: Store(
            initialState: ConversationModelDownloadFeature.State()
        ) {
            ConversationModelDownloadFeature()
        }
    )
    .padding()
    .frame(width: 450)
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
