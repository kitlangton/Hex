import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Settings for the optional, downstream transcript-refinement stage.
struct RefinementSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var geminiAPIKey = ""
	@State private var openRouterAPIKey = ""
	@State private var isShowingOpenRouterModelPicker = false

	var body: some View {
		Section {
			let refinedHotkey = store.hexSettings.refinedHotkey ?? .init(key: nil, modifiers: [])
			let refinedKey = store.isSettingRefinedHotKey ? nil : refinedHotkey.key
			let refinedModifiers = store.isSettingRefinedHotKey ? store.currentRefinedModifiers : refinedHotkey.modifiers

			VStack(alignment: .leading, spacing: 8) {
				Label("Refinement Instructions", systemImage: "sparkles")
					.font(.headline)
				TextEditor(text: $store.hexSettings.refinementInstructions)
					.font(.body)
					.multilineTextAlignment(.leading)
					.frame(maxWidth: .infinity, minHeight: 130, maxHeight: 180, alignment: .topLeading)
					.padding(8)
					.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
				Text("For example: “Return exactly three bullet points: one English, one French, and one German.”")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			Label {
				Picker("Provider", selection: $store.hexSettings.refinementProvider) {
					Text("Apple Intelligence").tag(RefinementProvider.apple)
					Text("Gemini Flash").tag(RefinementProvider.gemini)
					Text("OpenRouter").tag(RefinementProvider.openRouter)
				}
			} icon: {
				Image(systemName: "cpu")
			}

				if store.hexSettings.refinementProvider == .apple {
					if #unavailable(macOS 26.0) {
						Text("Apple Intelligence refinement requires macOS 26 or later. Until then, Hex keeps the processed transcript unchanged.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				if store.hexSettings.refinementProvider == .gemini {
					SecureField("Gemini API Key", text: $geminiAPIKey)
						.onSubmit(persistGeminiAPIKey)
					Text("Stored securely in Keychain. Without a key, Hex pastes the processed transcript unchanged.")
						.font(.caption)
						.foregroundStyle(.secondary)
					Text("Gemini sends the completed, locally transformed transcript text to Google. Audio is never sent.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				if store.hexSettings.refinementProvider == .openRouter {
					SecureField("OpenRouter API Key", text: $openRouterAPIKey)
						.onSubmit(persistOpenRouterAPIKey)
					Button {
						persistOpenRouterAPIKey()
						isShowingOpenRouterModelPicker = true
					} label: {
						LabeledContent("Default Model") {
							Text(store.hexSettings.openRouterModelID ?? "Select a model")
								.foregroundStyle(store.hexSettings.openRouterModelID == nil ? .secondary : .primary)
						}
					}
					.disabled(openRouterAPIKey.isEmpty)
					Text("Your key is stored securely in Keychain. Choose any text model from the cached OpenRouter catalog.")
						.font(.caption)
						.foregroundStyle(.secondary)
					Text("OpenRouter sends the completed, locally transformed transcript text to the selected model. Audio is never sent.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			VStack(alignment: .leading, spacing: 14) {
				RefinedHotKeyIntroduction(
					hasConflict: store.hexSettings.refinedHotkey?.conflicts(with: store.hexSettings.hotkey) ?? false
				)

				HStack {
					Spacer()
					HotKeyView(modifiers: refinedModifiers, key: refinedKey, isActive: store.isSettingRefinedHotKey)
					Spacer()
				}
				.contentShape(Rectangle())
				.onTapGesture { store.send(.startSettingRefinedHotKey) }
			}
			.listRowSeparator(.hidden)

			if !store.isSettingRefinedHotKey, refinedHotkey.key == nil, !refinedHotkey.modifiers.isEmpty {
				ModifierSideControls(modifiers: refinedHotkey.modifiers) { kind, side in
					store.send(.setRefinedModifierSide(kind, side))
				}
				.listRowSeparator(.hidden, edges: .top)
			}

			Label {
				Toggle("Enable double-tap lock", isOn: $store.hexSettings.refinedDoubleTapLockEnabled)
			} icon: {
				Image(systemName: "hand.tap")
			}

			if store.hexSettings.refinedDoubleTapLockEnabled {
				Label {
					Toggle("Use double-tap only", isOn: $store.hexSettings.refinedUseDoubleTapOnly)
				} icon: {
					Image(systemName: "hand.tap.fill")
				}
			}

			if refinedHotkey.key == nil, !(store.hexSettings.refinedDoubleTapLockEnabled && store.hexSettings.refinedUseDoubleTapOnly) {
				Label {
					Slider(value: $store.hexSettings.refinedMinimumKeyTime, in: 0 ... 2, step: 0.1) {
						Text("Ignore below \(store.hexSettings.refinedMinimumKeyTime, specifier: "%.1f")s")
					}
				} icon: {
					Image(systemName: "clock")
				}
			}

			Label {
				Toggle("Include selected text", isOn: $store.hexSettings.includeSelectedTextInRefinement)
			} icon: {
				Image(systemName: "text.cursor")
			}
		} header: {
			Text("Transcription Refinement")
		} footer: {
			Text("Rewrite or clean up your transcriptions and/or selected text with custom prompts")
		}
		.task {
			geminiAPIKey = GeminiAPIKeyStore.read() ?? ""
			openRouterAPIKey = OpenRouterAPIKeyStore.read() ?? ""
		}
		.onChange(of: store.hexSettings.refinementProvider) { oldProvider, _ in
			if oldProvider == .gemini { persistGeminiAPIKey() }
			if oldProvider == .openRouter { persistOpenRouterAPIKey() }
		}
		.onDisappear {
			persistGeminiAPIKey()
			persistOpenRouterAPIKey()
		}
		.sheet(isPresented: $isShowingOpenRouterModelPicker) {
			OpenRouterModelPickerView(
				selectedModelID: $store.hexSettings.openRouterModelID,
				apiKey: openRouterAPIKey
			)
		}
		.enableInjection()
	}

	private func persistGeminiAPIKey() {
		persistAPIKey(geminiAPIKey, providerName: "Gemini", save: GeminiAPIKeyStore.save, delete: GeminiAPIKeyStore.delete)
	}

	private func persistOpenRouterAPIKey() {
		persistAPIKey(openRouterAPIKey, providerName: "OpenRouter", save: OpenRouterAPIKeyStore.save, delete: OpenRouterAPIKeyStore.delete)
	}

	private func persistAPIKey(
		_ key: String,
		providerName: String,
		save: (String) throws -> Void,
		delete: () throws -> Void
	) {
		do {
			if key.isEmpty {
				try delete()
			} else {
				try save(key)
			}
		} catch {
			HexLog.settings.error("Could not save \(providerName, privacy: .public) API key: \(error.localizedDescription, privacy: .private)")
		}
	}
}

private struct RefinedHotKeyIntroduction: View {
	let hasConflict: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Label("Refined Transcription Hotkey", systemImage: "keyboard")
				.font(.headline)
			Text("Records normally, then always runs refinement using the instructions above.")
				.font(.caption)
				.foregroundStyle(.secondary)
			if hasConflict {
				Text("Choose a non-overlapping shortcut. A modifier-only shortcut cannot share a prefix with the regular shortcut.")
					.font(.caption)
					.foregroundStyle(.orange)
			}
		}
	}
}
