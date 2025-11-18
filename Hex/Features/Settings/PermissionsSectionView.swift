import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct PermissionsSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus
	let inputMonitoringPermission: PermissionStatus

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
				
			// Accessibility + Keyboard
			permissionCard(
				title: "Accessibility",
				icon: "accessibility",
				status: combinedAccessibilityStatus,
				action: {
					store.send(.requestAccessibility)
					store.send(.requestInputMonitoring)
				}
			)
		}

		if store.hotkeyPermissionState.inputMonitoring != .granted {
			VStack(alignment: .leading, spacing: 6) {
				Label {
					Text("Input Monitoring is required so Hex can listen for your hotkey.")
						.font(.callout)
						.foregroundStyle(.primary)
				} icon: {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundStyle(.yellow)
				}

				Button {
					store.send(.requestInputMonitoring)
				} label: {
					Text("Open Input Monitoring Settings")
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
			}
			.padding(12)
			.background(Color(nsColor: .controlBackgroundColor))
			.clipShape(RoundedRectangle(cornerRadius: 10))
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
				.lineLimit(1)
				.truncationMode(.tail)
				.layoutPriority(1)
			
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

	private var combinedAccessibilityStatus: PermissionStatus {
		if accessibilityPermission == .granted && inputMonitoringPermission == .granted {
			return .granted
		}
		if accessibilityPermission == .denied || inputMonitoringPermission == .denied {
			return .denied
		}
		return .notDetermined
	}
}
