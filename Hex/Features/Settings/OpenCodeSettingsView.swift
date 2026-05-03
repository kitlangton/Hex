import ComposableArchitecture
import Inject
import SwiftUI
import HexCore

struct OpenCodeSettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		let configuration = store.hexSettings.openCodeExperimental
		let key = store.isSettingOpenCodeHotKey ? nil : configuration.hotkey.key
		let modifiers = store.isSettingOpenCodeHotKey ? store.currentOpenCodeModifiers : configuration.hotkey.modifiers

		Form {
			Section {
				Toggle(
					"Enable voice actions",
					isOn: Binding(
						get: { store.hexSettings.openCodeExperimental.isEnabled },
						set: { store.send(.setOpenCodeExperimentalEnabled($0)) }
					)
				)

				Text("Record a separate hold-to-talk command that Hex sends to a managed OpenCode runtime for tool-based computer control.")
					.settingsCaption()
			} header: {
				Text("Experimental")
			}

			Section("Shortcut") {
				HStack {
					Spacer()
					HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingOpenCodeHotKey)
						.contentShape(Rectangle())
						.onTapGesture {
							store.send(.startSettingOpenCodeHotKey)
						}
					Spacer()
				}

				Text("Modifier-only hold-to-talk shortcuts are allowed here. Keep it distinct from your regular dictation hotkey.")
					.settingsCaption()
			}

			Section("Runtime") {
				LabeledContent("Server") {
					TextField(
						OpenCodeExperimentalSettings.defaultServerURL,
						text: Binding(
							get: { store.hexSettings.openCodeExperimental.serverURL },
							set: { store.send(.setOpenCodeServerURL($0)) }
						)
					)
					.onSubmit {
						store.send(.loadOpenCodeModels)
					}
					.multilineTextAlignment(.trailing)
				}

				LabeledContent("Install Path") {
					TextField(
						OpenCodeExperimentalSettings.defaultLaunchPath,
						text: Binding(
							get: { store.hexSettings.openCodeExperimental.launchPath },
							set: { store.send(.setOpenCodeLaunchPath($0)) }
						)
					)
					.onSubmit {
						store.send(.checkOpenCodeInstallation)
						store.send(.loadOpenCodeModels)
					}
					.multilineTextAlignment(.trailing)
				}

				LabeledContent("Directory") {
					TextField(
						"Optional project directory",
						text: Binding(
							get: { store.hexSettings.openCodeExperimental.directory },
							set: { store.send(.setOpenCodeDirectory($0)) }
						)
					)
					.onSubmit {
						store.send(.loadOpenCodeModels)
					}
					.multilineTextAlignment(.trailing)
				}

				Text("For localhost targets, Hex launches and owns `opencode serve` from the install path on first use. Leave Directory blank to use Hex's managed OpenCode workspace inside the app container.")
					.settingsCaption()
			}

			Section("Model") {
				Picker(
					"Model",
					selection: Binding(
						get: { store.hexSettings.openCodeExperimental.model },
						set: { store.send(.setOpenCodeModel($0)) }
					)
				) {
					ForEach(store.openCodeModels) { model in
						Text(model.title).tag(model.value)
					}
				}

				if store.isLoadingOpenCodeModels {
					ProgressView("Loading models…")
				}

				if let error = store.openCodeModelLoadError {
					Text(error)
						.foregroundStyle(.secondary)
						.font(.caption)
				}
			}

			Section("Allowed Tools") {
				TextField(
					OpenCodeExperimentalSettings.defaultAllowedTools,
					text: Binding(
						get: { store.hexSettings.openCodeExperimental.allowedTools },
						set: { store.send(.setOpenCodeAllowedTools($0)) }
					),
					axis: .vertical
				)
				.lineLimit(2...4)

				Text("Comma or newline separated permission IDs. Custom tool IDs work if the OpenCode instance already loads them.")
					.settingsCaption()
			}

			Section("Instructions") {
				TextEditor(
					text: Binding(
						get: { store.hexSettings.openCodeExperimental.instructions },
						set: { store.send(.setOpenCodeInstructions($0)) }
					)
				)
				.frame(minHeight: 120)

				Text("Extra system instructions attached to each voice action request.")
					.settingsCaption()
			}
		}
		.formStyle(.grouped)
		.enableInjection()
	}
}
