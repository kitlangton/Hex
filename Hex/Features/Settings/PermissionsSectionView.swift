import ComposableArchitecture
import SwiftUI

struct PermissionsSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			// Microphone
			HStack {
				Label("Microphone", systemImage: "mic.fill")
				Spacer()
				switch store.microphonePermission {
				case .granted:
					Label("Granted", systemImage: "checkmark.circle.fill")
						.foregroundColor(.green)
						.labelStyle(.iconOnly)
				case .denied:
					Button("Request Permission") {
						store.send(.requestMicrophonePermission)
					}
					.buttonStyle(.borderedProminent)
					.tint(.blue)
				case .notDetermined:
					Button("Request Permission") {
						store.send(.requestMicrophonePermission)
					}
					.buttonStyle(.bordered)
				}
			}

			// Accessibility
			HStack {
				Label("Accessibility", systemImage: "accessibility")
				Spacer()
				switch store.accessibilityPermission {
				case .granted:
					Label("Granted", systemImage: "checkmark.circle.fill")
						.foregroundColor(.green)
						.labelStyle(.iconOnly)
				case .denied:
					Button("Request Permission") {
						store.send(.requestAccessibilityPermission)
					}
					.buttonStyle(.borderedProminent)
					.tint(.blue)
				case .notDetermined:
					Button("Request Permission") {
						store.send(.requestAccessibilityPermission)
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
