import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct PermissionsSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus

	var body: some View {
		Section {
			HStack(spacing: 12) {
				// Microphone
				permissionCard(
					title: "Microphone",
					icon: "mic.fill",
					status: microphonePermission,
					action: { store.send(.requestMicrophone) }
				)
				
				// Accessibility
				permissionCard(
					title: "Accessibility",
					icon: "accessibility",
					status: accessibilityPermission,
					action: { store.send(.requestAccessibility) }
				)
			}

		} header: {
			Text("Permissions")
		}
		.enableInjection()
	}
	
	@ViewBuilder
	private func permissionCard(
		title: String,
		icon: String,
		status: PermissionStatus,
		action: @escaping () -> Void
	) -> some View {
		HStack(spacing: 8) {
			Image(systemName: icon)
				.font(.body)
				.foregroundStyle(.secondary)
				.frame(width: 16)
			
			Text(title)
				.font(.body.weight(.medium))
			
			Spacer()
			
			switch status {
			case .granted:
				Image(systemName: "checkmark.circle.fill")
					.foregroundStyle(.green)
					.font(.body)
			case .denied, .notDetermined:
				Button("Grant") {
					action()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity)
		.background(Color(nsColor: .controlBackgroundColor))
		.clipShape(RoundedRectangle(cornerRadius: 8))
	}
}
