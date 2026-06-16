import AppKit
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
			VStack(alignment: .leading, spacing: 10) {
				Label("Claude Code", systemImage: "chevron.left.forwardslash.chevron.right")
					.font(.body.weight(.medium))
				Text("Run this once in a terminal to register the Hex hooks with Claude Code:")
					.settingsCaption()
				commandRow(store.agentInstallCommand)

				DisclosureGroup("Remove integration") {
					VStack(alignment: .leading, spacing: 6) {
						Text("Run this to remove the hooks, then restart your claude sessions:")
							.settingsCaption()
						commandRow(store.agentUninstallCommand)
					}
					.padding(.top, 4)
				}
				.font(.caption)
			}

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
			Text("Hex is sandboxed and can't edit ~/.claude itself, so you run a one-time command. Re-run the install command if an app update changes the integration.")
				.settingsCaption()
		}
		.enableInjection()
	}

	/// A monospaced, selectable command with a Copy button.
	@ViewBuilder
	private func commandRow(_ command: String) -> some View {
		HStack(spacing: 8) {
			Text(command.isEmpty ? "Preparing…" : command)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
				.lineLimit(1)
				.truncationMode(.middle)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(6)
				.background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.15)))
			Button {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(command, forType: .string)
			} label: {
				Image(systemName: "doc.on.doc")
			}
			.buttonStyle(.bordered)
			.disabled(command.isEmpty)
			.help("Copy to clipboard")
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
