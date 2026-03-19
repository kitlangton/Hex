import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct RefinementSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			// Mode picker
			HStack(alignment: .center) {
				HStack(spacing: 4) {
					Text("Mode")
					Text("Experimental")
						.font(.system(size: 9, weight: .semibold))
						.foregroundStyle(.white)
						.padding(.horizontal, 5)
						.padding(.vertical, 2)
						.background(Capsule().fill(.purple.opacity(0.7)))
				}
				Spacer()
				Picker("", selection: $store.hexSettings.refinementMode) {
					Label("Raw", systemImage: "text.quote")
						.tag(RefinementMode.raw)
					Label("Refined", systemImage: "text.badge.checkmark")
						.tag(RefinementMode.refined)
					Label("Summarized", systemImage: "list.bullet")
						.tag(RefinementMode.summarized)
				}
				.pickerStyle(.menu)
				.onChange(of: store.hexSettings.refinementMode) { _, newMode in
					if newMode == .summarized {
						let tone = store.hexSettings.refinementTone
						if tone == .casual || tone == .friendly {
							store.$hexSettings.withLock { $0.refinementTone = .natural }
						}
					}
				}
			}

			if store.hexSettings.refinementMode != .raw {
				// Tone picker
				HStack(alignment: .center) {
					Text("Tone")
					Spacer()
					Picker("", selection: $store.hexSettings.refinementTone) {
						Text("Natural").tag(RefinementTone.natural)
						Text("Professional").tag(RefinementTone.professional)
						if store.hexSettings.refinementMode == .refined {
							Text("Casual").tag(RefinementTone.casual)
						}
						Text("Concise").tag(RefinementTone.concise)
						if store.hexSettings.refinementMode == .refined {
							Text("Friendly").tag(RefinementTone.friendly)
						}
					}
					.pickerStyle(.menu)
				}

				// Cycle tone hotkey
				VStack(spacing: 12) {
					let hotkey = store.hexSettings.cycleToneHotkey
					let isCapturing = store.isSettingCycleToneHotkey
					let displayKey = isCapturing ? nil : hotkey?.key
					let displayMods = isCapturing ? store.currentCycleToneModifiers : (hotkey?.modifiers ?? .init(modifiers: []))

					HStack {
						Text("Cycle Tone Hotkey")
						Spacer()
						if hotkey != nil && !isCapturing {
							Button {
								store.send(.clearCycleToneHotkey)
							} label: {
								Image(systemName: "xmark.circle.fill")
									.foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
						}
					}

					HStack {
						Spacer()
						HotKeyView(modifiers: displayMods, key: displayKey, isActive: isCapturing)
							.animation(.spring(), value: displayKey)
							.animation(.spring(), value: displayMods)
						Spacer()
					}
					.contentShape(Rectangle())
					.onTapGesture {
						store.send(.startSettingCycleToneHotkey)
					}
				}

				// Refine selection hotkey
				VStack(spacing: 12) {
					let hotkey = store.hexSettings.refineSelectionHotkey
					let isCapturing = store.isSettingRefineSelectionHotkey
					let displayKey = isCapturing ? nil : hotkey?.key
					let displayMods = isCapturing ? store.currentRefineSelectionModifiers : (hotkey?.modifiers ?? .init(modifiers: []))

					HStack {
						Text("Refine Selection Hotkey")
						Spacer()
						if hotkey != nil && !isCapturing {
							Button {
								store.send(.clearRefineSelectionHotkey)
							} label: {
								Image(systemName: "xmark.circle.fill")
									.foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
						}
					}

					HStack {
						Spacer()
						HotKeyView(modifiers: displayMods, key: displayKey, isActive: isCapturing)
							.animation(.spring(), value: displayKey)
							.animation(.spring(), value: displayMods)
						Spacer()
					}
					.contentShape(Rectangle())
					.onTapGesture {
						store.send(.startSettingRefineSelectionHotkey)
					}

					Text("Select text in any app and press this hotkey to refine or summarize the selection in place.")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
				}

				// Provider picker
				HStack(alignment: .center) {
					Text("Provider")
					Spacer()
					Picker("", selection: $store.hexSettings.refinementProvider) {
						Label("Apple Intelligence", systemImage: "apple.logo")
							.tag(RefinementProvider.apple)
						Label("Gemini Flash", systemImage: "bolt.fill")
							.tag(RefinementProvider.gemini)
					}
					.pickerStyle(.menu)
				}

				if store.hexSettings.refinementProvider == .gemini {
					SecureField("Gemini API Key", text: Binding(
						get: { store.hexSettings.geminiAPIKey ?? "" },
						set: { store.send(.setGeminiAPIKey($0.isEmpty ? nil : $0)) }
					))
					.textFieldStyle(.roundedBorder)

					if store.hexSettings.geminiAPIKey == nil || store.hexSettings.geminiAPIKey?.isEmpty == true {
						HStack(spacing: 4) {
							Image(systemName: "exclamationmark.triangle.fill")
								.foregroundStyle(.yellow)
								.font(.system(size: 11))
							Text("API key required. Without it, dictation will fall back to raw text.")
								.font(.system(size: 11))
								.foregroundStyle(.secondary)
						}
					}
				}
			}
		} header: {
			Label("Transcription Refinement", systemImage: "sparkles")
		}
		.enableInjection()
	}
}
