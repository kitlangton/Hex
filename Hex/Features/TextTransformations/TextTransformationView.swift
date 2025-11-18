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
				Text("Text Transformation Modes")
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
			if store.textTransformations.stacks.isEmpty {
				ContentUnavailableView(
					"No Modes",
					systemImage: "wand.and.stars",
					description: Text("Create modes by editing the configuration file")
				)
			} else {
				List {
					ForEach(store.textTransformations.stacks) { mode in
						ModeRow(mode: mode)
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
Configuration lives at:\n\(URL.textTransformationsURL.path)\n\nSchema essentials:\n- `schemaVersion` must stay 3.\n- `providers` currently supports only `claude_code` (binary path + default model).\n- `stacks` is an ordered list with flexible matching:\n  • `voicePrefix`: Trigger by saying prefix (e.g., "hex, what's 2+2?")\n  • `appliesToBundleIdentifiers`: Match by app bundle ID\n  • Precedence: prefix+bundle > prefix alone > bundle alone > general fallback\n- Matching is case-insensitive and multiple bundle IDs are allowed (Messages uses `com.apple.MobileSMS`, older builds use `com.apple.iChat`).\n- Each `pipeline` contains ordered `transformations`; `.llm` steps require a `providerID` and a `promptTemplate` that includes `{{input}}`.\n- Voice prefix input is automatically stripped before processing (e.g., "hex, calculate 10+5" → "calculate 10+5").\n\nWhen editing via an LLM:\n1. Always load the file, modify JSON structurally, and write it back intact.\n2. Preserve existing IDs unless you intentionally add a new stack/transformation.\n3. Favor adding bundle IDs (e.g., both `com.apple.MobileSMS` and `com.apple.iChat`) instead of renaming stacks.\n4. Prompts should be concise, privacy-safe, and explicit about output format.\n5. For voice-activated commands, set `voicePrefix` (e.g., "hex") and ensure prompt instructs to output only the answer.\n\nThis guide can be handed to an assistant with the request: "Edit the Hex text transformation config per the user's instructions."
"""
	}()
}

struct ModeRow: View {
	let mode: TransformationStack

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

			// Transformations preview
			if !mode.pipeline.transformations.isEmpty {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(Array(mode.pipeline.transformations.prefix(3).enumerated()), id: \.element.id) { index, transformation in
						HStack(spacing: 6) {
							Text("\(index + 1).")
								.font(.caption.monospacedDigit())
								.foregroundStyle(.tertiary)
							Text(transformation.name)
								.font(.caption)
								.foregroundStyle(transformation.isEnabled ? .secondary : .tertiary)
							if !transformation.isEnabled {
								Text("(disabled)")
									.font(.caption)
									.foregroundStyle(.tertiary)
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
