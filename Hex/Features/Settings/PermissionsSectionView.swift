import ComposableArchitecture
import HexCore
import SwiftUI

struct PermissionsSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus

	var body: some View {
		Section {
			// Microphone
			HStack {
				Label("Microphone", systemImage: "mic.fill")
				Spacer()
				switch microphonePermission {
				case .granted:
					Label("Granted", systemImage: "checkmark.circle.fill")
						.foregroundColor(.green)
						.labelStyle(.iconOnly)
				case .denied:
					Button("Request Permission") {
						store.send(.requestMicrophone)
					}
					.buttonStyle(.borderedProminent)
					.tint(.blue)
				case .notDetermined:
					Button("Request Permission") {
						store.send(.requestMicrophone)
					}
					.buttonStyle(.bordered)
				}
			}

			// Accessibility
			HStack {
				Label("Accessibility", systemImage: "accessibility")
				Spacer()
				switch accessibilityPermission {
				case .granted:
					Label("Granted", systemImage: "checkmark.circle.fill")
						.foregroundColor(.green)
						.labelStyle(.iconOnly)
				case .denied:
					Button("Request Permission") {
						store.send(.requestAccessibility)
					}
					.buttonStyle(.borderedProminent)
					.tint(.blue)
				case .notDetermined:
					Button("Request Permission") {
						store.send(.requestAccessibility)
					}
					.buttonStyle(.bordered)
				}
			}

		} header: {
			Text("Permissions")
		} footer: {
			Text("Ensure Hex can access your microphone and system accessibility features.")
				.font(.footnote)
				.foregroundColor(.secondary)
		}
	}
}
