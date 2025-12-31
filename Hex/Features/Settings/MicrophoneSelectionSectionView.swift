import ComposableArchitecture
import Inject
import SwiftUI

struct MicrophoneSelectionSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			// Input device picker
			HStack {
				Label {
					let systemLabel: String = {
						if let name = store.defaultInputDeviceName, !name.isEmpty {
							return "System Default (\(name))"
						}
						return "System Default"
					}()
					Picker("Input Device", selection: $store.hexSettings.selectedMicrophoneID) {
						Text(systemLabel).tag(nil as String?)
						ForEach(store.availableInputDevices) { device in
							Text(device.name).tag(device.id as String?)
						}
					}
					.pickerStyle(.menu)
					.id(store.availableInputDevices.map(\.id).joined(separator: "|"))
				} icon: {
					Image(systemName: "mic.circle")
				}

				Button(action: {
					store.send(.loadAvailableInputDevices)
				}) {
					Image(systemName: "arrow.clockwise")
				}
				.buttonStyle(.borderless)
				.help("Refresh available input devices")
			}

			// Show fallback note for selected device not connected
			if let selectedID = store.hexSettings.selectedMicrophoneID,
			   !store.availableInputDevices.contains(where: { $0.id == selectedID })
			{
				Text("Selected device not connected. System default will be used.")
					.settingsCaption()
			}
		} header: {
			Text("Microphone Selection")
		} footer: {
			Text("Override the system default microphone with a specific input device. This setting will persist across sessions.")
				.font(.footnote)
				.foregroundColor(.secondary)
		}
		.enableInjection()
	}
}
