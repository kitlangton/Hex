import ComposableArchitecture
import SwiftUI

struct AdvancedSectionView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: 8) {
          Button {
            store.send(.exportLogsButtonTapped)
          } label: {
            HStack {
              if store.isExportingLogs {
                ProgressView()
                  .scaleEffect(0.7)
              }
              Text(store.isExportingLogs ? "Exporting Logs…" : "Export Logs")
            }
          }
          .disabled(store.isExportingLogs)

          Text("Saves the last 30 minutes of Hex diagnostics so you can share them with support.")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let status = store.logExportStatus {
            statusView(status)
          }
        }
      } icon: {
        Image(systemName: "terminal")
      }
    } header: {
      Text("Advanced")
    }
  }

  @ViewBuilder
  private func statusView(_ status: SettingsFeature.State.LogExportStatus) -> some View {
    switch status {
    case let .success(path):
      Text("Saved to \(path)")
        .font(.caption)
        .foregroundStyle(.green)
    case let .failure(message):
      Text(message)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }
}
