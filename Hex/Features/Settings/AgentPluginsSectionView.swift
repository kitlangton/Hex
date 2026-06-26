//
//  AgentPluginsSectionView.swift
//  Hex
//
//  Settings UI for the Agent Plugins integrations — the sidebar section wrapper plus
//  the per-integration install/uninstall cards.
//

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
						// While preparing/playing, swap the play glyph for a spinner so the
						// model download stays invisible instead of flashing a progress bar.
						if store.isPreviewingVoice {
							ProgressView()
								.controlSize(.small)
						} else {
							Image(systemName: "play.circle")
						}
					}
					.buttonStyle(.plain)
					.help("Preview the selected voice")
					.disabled(store.isPreviewingVoice)
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
				Text("Give each concurrent agent session its own consistent voice so you can tell projects apart by ear. Your first session keeps the voice above; others get distinct voices. Enabling this preloads the model.")
			} icon: {
				Image(systemName: "person.2.wave.2")
			}

		} header: {
			Text("Agent Plugins")
		}

		Section {
			// One row per registered integration. The set of integrations lives in
			// AgentIntegrationsClient.liveValue — this view is agnostic.
			ForEach(store.integrations) { integration in
				integrationRow(integration)
			}

			// Codex support is planned — shown disabled to mirror the competitor UI.
			Label {
				HStack {
					Text("Codex")
					Spacer()
					Text("Coming soon").settingsCaption()
				}
			} icon: {
				brandIcon("IntegrationCodex")
			}
			.disabled(true)
		} header: {
			Text("Integrations")
		} footer: {
			Text("Hex is sandboxed and can't write outside its container, so each integration needs a one-time install command. Re-run the install command if an app update changes the integration.")
				.settingsCaption()
		}
		.enableInjection()
	}

	/// One Integrations-section row for an AgentIntegration descriptor. No per-provider
	/// branching here — everything that varies lives in the descriptor.
	@ViewBuilder
	private func integrationRow(_ integration: AgentIntegration) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Label {
				Text(integration.displayName).font(.body.weight(.medium))
			} icon: {
				integrationIcon(integration.icon)
			}
			Text(integration.installCaption).settingsCaption()
			commandRow(integration.installCommand)

			DisclosureGroup("Remove integration") {
				VStack(alignment: .leading, spacing: 6) {
					Text(integration.uninstallCaption).settingsCaption()
					commandRow(integration.uninstallCommand)
				}
				.padding(.top, 4)
			}
			.font(.caption)
		}
	}

	/// Renders either a vendored brand asset or an SF Symbol, depending on what the
	/// integration's descriptor declares.
	@ViewBuilder
	private func integrationIcon(_ icon: AgentIntegrationIcon) -> some View {
		switch icon {
		case let .asset(name):
			brandIcon(name)
		case let .symbol(name):
			Image(systemName: name)
				.font(.system(size: 13, weight: .semibold))
				.frame(width: 16, height: 16)
		}
	}

	/// A bundled brand icon (favicons vendored under Assets.xcassets).
	@ViewBuilder
	private func brandIcon(_ assetName: String) -> some View {
		Image(assetName)
			.resizable()
			.aspectRatio(contentMode: .fit)
			.frame(width: 16, height: 16)
			.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
