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
			VStack(alignment: .leading, spacing: 8) {
				Text("Refinement Instructions")
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

				Picker("Provider", selection: $store.hexSettings.refinementProvider) {
					Text("Apple Intelligence").tag(RefinementProvider.apple)
					Text("Gemini Flash").tag(RefinementProvider.gemini)
					Text("OpenRouter").tag(RefinementProvider.openRouter)
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
			RefinedHotKeyConfiguration(store: store)
		} header: {
			Label("Transcription Refinement", systemImage: "sparkles")
		} footer: {
			Text("These instructions apply only to the refined-transcription hotkey, after transcription and your configured text transforms complete.")
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

private struct RefinedHotKeyConfiguration: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		let hotkey = store.hexSettings.refinedHotkey ?? .init(key: nil, modifiers: [])
		let key = store.isSettingRefinedHotKey ? nil : hotkey.key
		let modifiers = store.isSettingRefinedHotKey ? store.currentRefinedModifiers : hotkey.modifiers

		VStack(alignment: .leading, spacing: 8) {
			Text("Refined Transcription Hotkey")
				.font(.headline)
			Text("Records normally, then always runs refinement using the instructions above.")
				.font(.caption)
				.foregroundStyle(.secondary)
			if let refinedHotkey = store.hexSettings.refinedHotkey,
			   refinedHotkey.conflicts(with: store.hexSettings.hotkey) {
				Text("Choose a non-overlapping shortcut. A modifier-only shortcut cannot share a prefix with the regular shortcut.")
					.font(.caption)
					.foregroundStyle(.orange)
			}
			HStack {
				Spacer()
				HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingRefinedHotKey)
				Spacer()
			}
			.contentShape(Rectangle())
			.onTapGesture { store.send(.startSettingRefinedHotKey) }

			if !store.isSettingRefinedHotKey, hotkey.key == nil, !hotkey.modifiers.isEmpty {
				ModifierSideControls(modifiers: hotkey.modifiers) { kind, side in
					store.send(.setRefinedModifierSide(kind, side))
				}
			}

			Toggle("Enable double-tap lock", isOn: $store.hexSettings.refinedDoubleTapLockEnabled)
			if store.hexSettings.refinedDoubleTapLockEnabled {
				Toggle("Use double-tap only", isOn: $store.hexSettings.refinedUseDoubleTapOnly)
			}
			if hotkey.key == nil, !(store.hexSettings.refinedDoubleTapLockEnabled && store.hexSettings.refinedUseDoubleTapOnly) {
				Slider(value: $store.hexSettings.refinedMinimumKeyTime, in: 0 ... 2, step: 0.1) {
					Text("Ignore below \(store.hexSettings.refinedMinimumKeyTime, specifier: "%.1f")s")
				}
			}
			Toggle("Include selected text", isOn: $store.hexSettings.includeSelectedTextInRefinement)

		}
	}
}
