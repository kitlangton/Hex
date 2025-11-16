import Inject
import SwiftUI

struct AutoDownloadBannerView: View {
	@ObserveInjection var inject
	enum Style {
		case info
		case error
	}

	var title: String
	var subtitle: String?
	var progress: Double?
	var style: Style = .info

	private var normalizedProgress: Double? {
		progress.map { min(max($0, 0), 1) }
	}

	private var accentColor: Color {
		switch style {
		case .info:
			return .accentColor
		case .error:
			return .red
		}
	}

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: iconName)
				.font(.system(size: 16, weight: .semibold))
				.foregroundStyle(accentColor)

			VStack(alignment: .leading, spacing: 6) {
				Text(title)
					.font(.system(size: 12, weight: .semibold))
					.foregroundColor(.primary)

				if let subtitle {
					Text(subtitle)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
				}

				if let normalizedProgress {
					ProgressView(value: normalizedProgress)
						.progressViewStyle(.linear)
				}
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(
			RoundedRectangle(cornerRadius: 10)
				.fill(.thinMaterial)
		)
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(accentColor.opacity(style == .error ? 0.4 : 0.25), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
		.enableInjection()
	}

	private var iconName: String {
		switch style {
		case .info:
			return "arrow.down.circle.fill"
		case .error:
			return "exclamationmark.triangle.fill"
		}
	}
}

#Preview {
	VStack(spacing: 12) {
		AutoDownloadBannerView(
			title: "Preparing Parakeet",
			subtitle: "42% downloaded",
			progress: 0.42
		)

		AutoDownloadBannerView(
			title: "Model download failed",
			subtitle: "Check your connection and retry",
			progress: nil,
			style: .error
		)
	}
	.padding()
}
