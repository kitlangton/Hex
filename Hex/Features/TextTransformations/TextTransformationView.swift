import AppKit
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct TextTransformationView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<TextTransformationFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: 20) {
		// Header
		VStack(alignment: .leading, spacing: 12) {
				Text("Modes")
					.font(.title2.bold())
				Text("Configure modes by editing the JSON file")
					.font(.callout)
					.foregroundStyle(.secondary)

			HStack(spacing: 12) {
				Button {
					NSWorkspace.shared.open(.textTransformationsURL)
					} label: {
						Label("Open in Editor", systemImage: "pencil")
					}

				Button {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(URL.textTransformationsURL.path, forType: .string)
				} label: {
					Label("Copy Path", systemImage: "doc.on.doc")
				}

				Button {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(Self.llmInstructions, forType: .string)
				} label: {
					Label("Copy LLM Instructions", systemImage: "text.badge.plus")
				}
			}

			InstructionCard(text: Self.llmInstructions)

				// Error banner
				if let error = store.configFileError {
					HStack(spacing: 8) {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
						Text(error)
							.font(.callout)
					}
					.padding(10)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
				}
			}
			.padding()

			// Modes list
			if store.textTransformations.modes.isEmpty {
				ContentUnavailableView(
					"No Modes",
					systemImage: "wand.and.stars",
					description: Text("Create modes by editing the configuration file")
				)
			} else {
				List {
					ForEach(store.textTransformations.modes) { mode in
						ModeRow(mode: mode, providers: store.textTransformations.providers)
					}
				}
				.listStyle(.inset(alternatesRowBackgrounds: true))
			}
		}
		.task {
			await store.send(.startWatchingConfigFile).finish()
		}
		.enableInjection()
	}
}

private struct InstructionCard: View {
	let text: String

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("LLM Editing Guide")
				.font(.headline)
			Text(text)
				.font(.caption)
		}
		.padding(12)
		.background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor)))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.stroke(Color.primary.opacity(0.1))
		)
	}
}

	extension TextTransformationView {
	static let llmInstructions: String = {
		"""
Configuration lives at:
\(URL.textTransformationsURL.path)

Schema essentials:
- `schemaVersion` must stay 4.
	- `providers` supports both `claude_code` (Claude Desktop CLI) and `ollama` entries.
	  • `claude_code` entries auto-detect the Claude Code CLI under `~/.claude/local/...` (plus PATH/Homebrew/NVM). We never fall back to `/Applications/Claude.app`, so install/enable Claude Code or set `binaryPath` when discovery fails. `workingDirectory` stays optional.
	  • `ollama` entries point to the `ollama` CLI binary (auto-detected when omitted) and set `defaultModel` to a tag such as `llama3.1:8b`.
  • Text-only providers (currently all Ollama models) ignore `tooling` blocks even if configured, so prefer prompts that don't rely on MCP.
- Add `tooling.enabledToolGroups` when Claude should call Hex's MCP tools, and include a short `instructions` note so future editors understand why tools are enabled.
  • Current tool groups:
    – `app-control`: launch or focus apps via bundle ID and open URLs (`openApplication`, `openURL`)
    – `app-discovery`: list installed apps + bundle identifiers via `listApplications`
    – `context`: fetch selected text or the clipboard without disturbing the user (`getSelectedText`, `getClipboardText`)
- `modes` is an ordered list with flexible matching:
  • `voicePrefix`: Trigger by saying prefix (e.g., "hex, what's 2+2?")
  • `appliesToBundleIdentifiers`: Match by app bundle ID
  • Precedence: prefix+bundle > prefix alone > bundle alone > general fallback
- Matching is case-insensitive and multiple bundle IDs are allowed (Messages uses `com.apple.MobileSMS`, older builds use `com.apple.iChat`).
- Each `pipeline` contains ordered `transformations`; `.llm` steps require a `providerID` and a `promptTemplate` that includes `{{input}}`.
- `autoSendCommand` (optional): Keyboard shortcut to simulate after pasting text
  • Format: `{"key": "return", "modifiers": [{"kind": "command"}]}`
  • Common use: Auto-send messages (Enter, Cmd+Enter, Shift+Enter)
  • Key field is optional for modifier-only commands
  • Example: `{"key": "return"}` sends plain Enter after paste
- Use `"providerID": "hex-preferred-provider"` to honor the user-selected provider/model in Settings; Hex falls back to explicit IDs if preferences are unset.
- Voice prefix input is automatically stripped before processing (e.g., "hex, calculate 10+5" → "calculate 10+5").
- When a transformation issues an obvious action (opening/focusing apps or URLs), instruct the LLM to return an empty string unless the user explicitly asked for a textual response so Hex doesn't paste filler text.

When editing via an LLM:
1. Always load the file, modify JSON structurally, and write it back intact.
2. Preserve existing IDs unless you intentionally add a new mode/transformation.
3. Favor adding bundle IDs (e.g., both `com.apple.MobileSMS` and `com.apple.iChat`) instead of renaming modes.
4. Prompts should be concise, privacy-safe, and explicit about output format; if a mode expects tool usage, mention which tool group(s) it relies on and what each tool does (e.g., "use the app-control tools to open Safari, app-discovery:listApplications to find bundle IDs, and context:getSelectedText to read highlighted text").
5. For voice-activated commands, set `voicePrefix` (e.g., "hex") and ensure the prompt instructs Claude to output only the answer.

This guide can be handed to an assistant with the request: "Edit the Hex text transformation config per the user's instructions."
"""
	}()
}

struct ModeRow: View {
	let mode: TransformationMode
	let providers: [LLMProvider]

	private struct ProviderSummary: Identifiable {
		let id: String
		let name: String
		let supportsTools: Bool
		let toolReliability: LLMProviderCapabilities.ToolReliability
		let isPlaceholder: Bool
	
		var badgeTitle: String {
			supportsTools ? "Tools" : "Text-only"
		}
	}
	
	private var providerIDsInMode: [String] {
		var seen = Set<String>()
		var ordered: [String] = []
		for transformation in mode.pipeline.transformations where transformation.isEnabled {
			if case let .llm(config) = transformation.type {
				if seen.insert(config.providerID).inserted {
					ordered.append(config.providerID)
				}
			}
		}
		return ordered
	}

	// Extract unique tool groups from all LLM transformations in this mode
	private var enabledToolGroups: [HexToolGroup]? {
		let toolGroups = Set(providerIDsInMode.compactMap { providerID in
			guard let provider = providers.first(where: { $0.id == providerID }) else { return [] as [HexToolGroup] }
			let capabilities = LLMProviderCapabilitiesResolver.capabilities(for: provider)
			guard capabilities.supportsToolCalling, capabilities.toolReliability != .none else { return [] }
			return provider.tooling?.enabledToolGroups ?? []
		}.flatMap { $0 })
		
		return toolGroups.isEmpty ? nil : Array(toolGroups).sorted(by: { $0.rawValue < $1.rawValue })
	}

	private var providerSummaries: [ProviderSummary] {
		providerIDsInMode.compactMap { providerID in
			if let provider = providers.first(where: { $0.id == providerID }) {
				let capabilities = LLMProviderCapabilitiesResolver.capabilities(for: provider)
				return ProviderSummary(
					id: providerID,
					name: provider.displayName ?? providerID,
					supportsTools: capabilities.supportsToolCalling && capabilities.toolReliability != .none,
					toolReliability: capabilities.toolReliability,
					isPlaceholder: false
				)
			} else if providerID == LLMProvider.preferredProviderIdentifier {
				return ProviderSummary(
					id: providerID,
					name: "Preferred Provider (Settings)",
					supportsTools: false,
					toolReliability: .experimental,
					isPlaceholder: true
				)
			}
			return nil
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
			Text(mode.name)
				.font(.headline)

			Spacer()

			Text("\(mode.pipeline.transformations.count) transformation\(mode.pipeline.transformations.count == 1 ? "" : "s")")
				.font(.caption)
				.foregroundStyle(.secondary)
		}

		AppTargetsView(bundleIDs: mode.appliesToBundleIdentifiers)
		VoicePrefixView(prefixes: mode.voicePrefixes)

		if !providerSummaries.isEmpty {
			HStack(spacing: 6) {
				Image(systemName: "bolt.horizontal.circle")
					.foregroundStyle(.secondary)
					.font(.caption)
				Text("LLM Providers:")
					.font(.caption)
					.foregroundStyle(.secondary)
				ForEach(providerSummaries) { summary in
					HStack(spacing: 4) {
						Text(summary.name)
							.font(.caption)
							.foregroundStyle(.primary)
						Text(summary.badgeTitle)
							.font(.caption2)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(RoundedRectangle(cornerRadius: 4).fill(summary.supportsTools ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2)))
							.foregroundStyle(summary.supportsTools ? Color.blue : Color.orange)
					}
				}
			}
		}
			
		// MCP Tools indicator
		if let toolGroups = enabledToolGroups, !toolGroups.isEmpty {
			HStack(spacing: 6) {
				Image(systemName: "wrench.and.screwdriver.fill")
					.foregroundStyle(.secondary)
					.font(.caption)
					Text("MCP Tools:")
						.font(.caption)
						.foregroundStyle(.secondary)
					ForEach(toolGroups, id: \.self) { group in
						Text(group.rawValue)
							.font(.caption)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.2)))
							.foregroundStyle(.blue)
					}
				}
			}
		
		// Auto-send keyboard command indicator
		if let autoSend = mode.autoSendCommand {
			HStack(spacing: 6) {
				Image(systemName: "paperplane.fill")
					.foregroundStyle(.secondary)
					.font(.caption)
				Text("Auto-send:")
					.font(.caption)
					.foregroundStyle(.secondary)
				Text(autoSend.displayName)
					.font(.caption)
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.2)))
					.foregroundStyle(.purple)
			}
		}

			// Transformations preview
			if !mode.pipeline.transformations.isEmpty {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(Array(mode.pipeline.transformations.prefix(3).enumerated()), id: \.element.id) { index, transformation in
						HStack(alignment: .top, spacing: 6) {
							Text("\(index + 1).")
								.font(.caption.monospacedDigit())
								.foregroundStyle(.tertiary)
							HStack(spacing: 4) {
								Text(transformation.name)
									.font(.caption)
									.foregroundStyle(transformation.isEnabled ? .secondary : .tertiary)
									.lineLimit(nil)
									.fixedSize(horizontal: false, vertical: true)
								if !transformation.isEnabled {
									Text("(disabled)")
										.font(.caption)
										.foregroundStyle(.tertiary)
								}
							}
						}
					}
					if mode.pipeline.transformations.count > 3 {
						Text("   +\(mode.pipeline.transformations.count - 3) more...")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
				}
			}
		}
		.padding(.vertical, 4)
	}

}

private struct AppTargetsView: View {
	let bundleIDs: [String]

	var body: some View {
		if bundleIDs.isEmpty {
			Text("Applies to first matching app (no filters)")
				.font(.caption)
				.foregroundStyle(.secondary)
		} else {
			HStack(spacing: 6) {
				Text("Applies to:")
					.font(.caption)
					.foregroundStyle(.secondary)

				ForEach(bundleIDs.prefix(3), id: \.self) { bundleID in
					Text(appName(for: bundleID))
						.font(.caption)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)))
				}

				if bundleIDs.count > 3 {
					Text("+\(bundleIDs.count - 3) more")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	private func appName(for bundleID: String) -> String {
		if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
			return url.deletingPathExtension().lastPathComponent
		}
		return bundleID
	}
}

private struct VoicePrefixView: View {
	let prefixes: [String]

	var body: some View {
		if prefixes.isEmpty {
			EmptyView()
		} else {
			HStack(spacing: 6) {
				Image(systemName: "waveform.circle")
					.font(.caption)
					.foregroundStyle(.secondary)
				Text("Voice Prefixes:")
					.font(.caption)
					.foregroundStyle(.secondary)
				ForEach(prefixes.prefix(4), id: \.self) { prefix in
					Text(prefix)
						.font(.caption)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.2)))
				}
				if prefixes.count > 4 {
					Text("+\(prefixes.count - 4) more")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}
	}
}
