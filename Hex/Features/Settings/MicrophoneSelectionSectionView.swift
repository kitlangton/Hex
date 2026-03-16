import ComposableArchitecture
import Inject
import SwiftUI

struct MicrophoneSelectionSectionView: View {
	private static let systemDefaultTag = "__system_default__"

	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	private var selectedDeviceTag: Binding<String> {
		Binding(
			get: { store.hexSettings.selectedMicrophoneID ?? Self.systemDefaultTag },
			set: { newValue in
				store.hexSettings.selectedMicrophoneID = newValue == Self.systemDefaultTag ? nil : newValue
			}
		)
	}

	private var missingSelectedDeviceID: String? {
		guard let selectedID = store.hexSettings.selectedMicrophoneID,
		      !store.availableInputDevices.contains(where: { $0.id == selectedID })
		else {
			return nil
		}

		return selectedID
	}

	private var pickerIdentity: String {
		[
			store.defaultInputDeviceName ?? "",
			store.hexSettings.selectedMicrophoneID ?? Self.systemDefaultTag,
			store.availableInputDevices.map { "\($0.id):\($0.name)" }.joined(separator: "|")
		].joined(separator: "||")
	}

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
					Picker("Input Device", selection: selectedDeviceTag) {
						Text(systemLabel).tag(Self.systemDefaultTag)
						ForEach(store.availableInputDevices) { device in
							Text(device.name).tag(device.id)
						}
						if let missingSelectedDeviceID {
							Text("Unavailable Device").tag(missingSelectedDeviceID)
						}
					}
					.pickerStyle(.menu)
					.id(pickerIdentity)
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
			if missingSelectedDeviceID != nil {
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
