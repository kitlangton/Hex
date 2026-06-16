import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Standalone tab wrapper so "Agent Plugins" can appear as its own sidebar section.
struct AgentPluginsSettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Form {
			AgentPluginsSectionView(store: store)
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
		.enableInjection()
	}
}

struct AgentPluginsSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle(
					"Enable Agent Plugins",
					isOn: Binding(
						get: { store.hexSettings.agentPluginsEnabled },
						set: { store.send(.toggleAgentPluginsEnabled($0)) }
					)
				)
				Text("Pop a voice window when an installed agent finishes a turn or asks a question, so you can speak your reply.")
			} icon: {
				Image(systemName: "waveform.badge.mic")
			}

			Label {
				HStack {
					Picker(
						"Read-Aloud Voice",
						selection: Binding(
							get: { String?.some(KokoroVoice.voiceName(fromIdentifier: store.hexSettings.agentVoiceIdentifier)) },
							set: { store.send(.setAgentVoice($0)) }
						)
					) {
						ForEach(KokoroVoice.voices, id: \.self) { name in
							Text(KokoroVoice.label(forVoiceName: name)).tag(String?.some(name))
						}
					}
					Button {
						store.send(.previewAgentVoice)
					} label: {
						Image(systemName: "play.circle")
					}
					.buttonStyle(.plain)
					.help("Preview the selected voice")
					.disabled(store.kokoroDownloadProgress != nil)
				}
				if let progress = store.kokoroDownloadProgress {
					HStack(spacing: 8) {
						ProgressView(value: progress)
							.progressViewStyle(.linear)
						Text("Downloading Kokoro model… \(Int(progress * 100))%")
							.font(.caption)
							.foregroundStyle(.secondary)
							.fixedSize()
					}
				}
				Text("Kokoro voice used when the agent window reads output aloud. The model (~300 MB) downloads on first use.")
			} icon: {
				Image(systemName: "speaker.wave.2")
			}

			Label {
				Toggle(
					"Distinct Voice per Project",
					isOn: Binding(
						get: { store.hexSettings.agentDistinctSessionVoices },
						set: { store.send(.setAgentDistinctSessionVoices($0)) }
					)
				)
				Text("Give each concurrent Claude session its own consistent voice so you can tell projects apart by ear. Your first session keeps the voice above; others get distinct voices. Enabling this preloads the model.")
			} icon: {
				Image(systemName: "person.2.wave.2")
			}

			AgentWindowHotkeyRow(store: store)
		} header: {
			Text("Agent Plugins")
		}

		Section {
			pluginRow(
				name: "Claude Code",
				systemImage: "chevron.left.forwardslash.chevron.right",
				installed: store.agentPluginInstalled,
				install: { store.send(.installAgentPlugin) },
				uninstall: { store.send(.uninstallAgentPlugin) }
			)

			// Codex support is planned — shown disabled to mirror the competitor UI.
			Label {
				HStack {
					Text("Codex")
					Spacer()
					Text("Coming soon").settingsCaption()
				}
			} icon: {
				Image(systemName: "cpu")
			}
			.disabled(true)
		} header: {
			Text("Integrations")
		} footer: {
			Text("Installing writes a hook to ~/.claude so Claude Code can open Hex. Uninstalling removes it.")
				.settingsCaption()
		}
		.enableInjection()
	}

	@ViewBuilder
	private func pluginRow(
		name: String,
		systemImage: String,
		installed: Bool,
		install: @escaping () -> Void,
		uninstall: @escaping () -> Void
	) -> some View {
		Label {
			HStack {
				Text(name)
				Spacer()
				if installed {
					Text("Installed").settingsCaption()
					Button("Uninstall", role: .destructive, action: uninstall)
				} else {
					Button("Install", action: install)
						.buttonStyle(.borderedProminent)
				}
			}
		} icon: {
			Image(systemName: systemImage)
		}
	}
}

private struct AgentWindowHotkeyRow: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		let hotkey = store.hexSettings.agentWindowHotkey

		VStack(alignment: .leading, spacing: 12) {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("Summon Agent Window")
						.font(.subheadline.weight(.semibold))
					Text("Assign a shortcut (modifier + key) to open the agent window from anywhere and talk to Claude.")
						.settingsCaption()
				}
			} icon: {
				Image(systemName: "bubble.left.and.text.bubble.right")
			}

			let key = store.isSettingAgentWindowHotkey ? nil : hotkey?.key
			let modifiers = store.isSettingAgentWindowHotkey ? store.currentAgentWindowModifiers : (hotkey?.modifiers ?? .init(modifiers: []))

			HStack {
				Spacer()
				ZStack {
					HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingAgentWindowHotkey)

					if !store.isSettingAgentWindowHotkey, hotkey == nil {
						Text("Not set")
							.settingsCaption()
					}
				}
				.contentShape(Rectangle())
				.onTapGesture {
					store.send(.startSettingAgentWindowHotkey)
				}
				Spacer()
			}

			if store.isSettingAgentWindowHotkey {
				Text("Use at least one modifier (⌘, ⌥, ⇧, ⌃) plus a key.")
					.settingsCaption()
			} else if hotkey != nil {
				Button {
					store.send(.clearAgentWindowHotkey)
				} label: {
					Label("Clear shortcut", systemImage: "xmark.circle")
				}
				.buttonStyle(.borderless)
				.font(.caption)
				.foregroundStyle(.secondary)
			}
		}
		.enableInjection()
	}
}
