import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct CoachSettingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<CoachFeature>

	var body: some View {
		Section {
			Label {
				Toggle("Pronunciation Coach", isOn: Binding(
					get: { store.hexSettings.coach.enabled },
					set: { store.send(.setEnabled($0)) }
				))
				Text("After each long dictation, send the audio to a cloud LLM for pronunciation feedback.")
					.settingsCaption()
			} icon: {
				Image(systemName: "ear.and.waveform")
			}

			if store.hexSettings.coach.enabled {
				providerRow
				apiKeyRow
				thresholdRow
				autoShowRow
				promptTemplateRow
				retentionRow
				historyManagementRow
			}
		} header: {
			Text("Pronunciation Coach")
		} footer: {
			privacyFooter
		}
		.enableInjection()
	}

	// MARK: - Provider

	private var providerRow: some View {
		Label {
			HStack {
				Text("Provider")
				Spacer()
				Picker("", selection: Binding(
					get: { store.hexSettings.coach.provider },
					set: { store.send(.setProvider($0)) }
				)) {
					Text("Gemini 3.1 Flash Lite").tag(CoachProvider.gemini)
					Text("OpenAI gpt-4o (preview)").tag(CoachProvider.openai)
				}
				.pickerStyle(.menu)
				.frame(width: 220)
			}
		} icon: {
			Image(systemName: "cloud")
		}
	}

	// MARK: - API Key

	@ViewBuilder
	private var apiKeyRow: some View {
		let provider = store.hexSettings.coach.provider
		let last4 = store.apiKeyLast4[provider]

		Label {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Text("API Key")
					Spacer()
					if let last4 {
						Text("•••• \(last4)")
							.font(.system(.body, design: .monospaced))
							.foregroundStyle(.secondary)
					} else {
						Text("Not set")
							.settingsCaption()
					}
				}

				HStack(spacing: 8) {
					SecureField(
						"Paste your \(provider.displayName) API key",
						text: Binding(
							get: { store.apiKeyInputs[provider] ?? "" },
							set: { store.send(.setApiKeyInput(provider: provider, value: $0)) }
						)
					)
					.textFieldStyle(.roundedBorder)

					Button("Save") {
						store.send(.saveApiKey(provider: provider))
					}
					.disabled((store.apiKeyInputs[provider]?.isEmpty ?? true))

					if last4 != nil {
						Button("Remove", role: .destructive) {
							store.send(.removeApiKey(provider: provider))
						}
					}
				}

				HStack(spacing: 8) {
					Button {
						store.send(.testApiKey)
					} label: {
						Label("Test key", systemImage: "play.circle")
					}
					.disabled(last4 == nil || store.apiKeyTestState == .testing)

					switch store.apiKeyTestState {
					case .idle:
						EmptyView()
					case .testing:
						ProgressView().controlSize(.small)
						Text("Testing…").settingsCaption()
					case .passed:
						Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
						Text("Key works.").settingsCaption()
					case let .failed(message):
						Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
						Text(message)
							.settingsCaption()
							.lineLimit(2)
					}
				}
			}
		} icon: {
			Image(systemName: "key.fill")
		}
	}

	// MARK: - Threshold

	private var thresholdRow: some View {
		Label {
			VStack(alignment: .leading, spacing: 4) {
				HStack {
					Text("Trigger after")
					Spacer()
					Text("\(store.hexSettings.coach.thresholdSec)s")
						.foregroundStyle(.secondary)
						.font(.system(.body, design: .monospaced))
				}
				Slider(
					value: Binding(
						get: { Double(store.hexSettings.coach.thresholdSec) },
						set: { store.send(.setThresholdSec(Int($0))) }
					),
					in: 3...120,
					step: 1
				)
				Text("Recordings shorter than this won't be sent to the provider.")
					.settingsCaption()
			}
		} icon: {
			Image(systemName: "stopwatch")
		}
	}

	// MARK: - Auto-show popover

	private var autoShowRow: some View {
		Label {
			Toggle(
				"Automatically open coach window",
				isOn: Binding(
					get: { store.hexSettings.coach.autoShowPopover },
					set: { store.send(.setAutoShowPopover($0)) }
				)
			)
			Text("Pops the coach window open as soon as the LLM starts responding, so you can watch feedback stream in.")
				.settingsCaption()
		} icon: {
			Image(systemName: "rectangle.on.rectangle")
		}
	}

	// MARK: - Prompt template

	private var promptTemplateRow: some View {
		let usingCustom = !(store.hexSettings.coach.customPromptTemplate ?? "").isEmpty

		return Label {
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text("Coach prompt")
					if usingCustom {
						Text("Custom")
							.font(.caption2.weight(.semibold))
							.foregroundStyle(.orange)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(Capsule().fill(Color.orange.opacity(0.15)))
					} else {
						Text("Default")
							.font(.caption2.weight(.semibold))
							.foregroundStyle(.secondary)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(Capsule().fill(Color.secondary.opacity(0.12)))
					}
					Spacer()
					if usingCustom {
						Button("Reset to default", role: .destructive) {
							store.send(.resetPromptTemplate)
						}
						.font(.caption)
					}
				}

				TextEditor(text: Binding(
					get: {
						store.hexSettings.coach.customPromptTemplate ?? GeminiProvider.defaultPromptTemplate
					},
					set: { value in
						let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
						// If the user's edit ends up identical to the default, clear the override.
						if trimmed == GeminiProvider.defaultPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines) {
							store.send(.setCustomPromptTemplate(nil))
						} else {
							store.send(.setCustomPromptTemplate(value))
						}
					}
				))
				.font(.system(.callout, design: .monospaced))
				.frame(minHeight: 220, maxHeight: 400)
				.overlay(
					RoundedRectangle(cornerRadius: 6)
						.stroke(Color.secondary.opacity(0.25), lineWidth: 1)
				)

				Text(GeminiProvider.placeholderHelp)
					.settingsCaption()

				Text("If you keep the default headers (Score / Summary / Native phrasing / Issues / Wins) the popover renders structured cards. With a custom format, the popover falls back to rendering your response as Markdown verbatim.")
					.settingsCaption()
			}
		} icon: {
			Image(systemName: "doc.text.below.ecg")
		}
	}

	// MARK: - Retention

	private var retentionRow: some View {
		Label {
			Toggle(
				"Delete audio after analysis",
				isOn: Binding(
					get: { store.hexSettings.coach.deleteAudioAfterAnalysis },
					set: { store.send(.setDeleteAudioAfterAnalysis($0)) }
				)
			)
			Text("After a successful coach session, the recording is removed from your history.")
				.settingsCaption()
		} icon: {
			Image(systemName: "trash")
		}
	}

	// MARK: - History management

	private var historyManagementRow: some View {
		Label {
			HStack {
				Text("Feedback history")
				Spacer()
				Text("\(store.feedbackHistory.items.count) session\(store.feedbackHistory.items.count == 1 ? "" : "s")")
					.settingsCaption()
				Button("Show…") {
					NSApp.sendAction(#selector(HexAppDelegate.showCoachPopover(_:)), to: nil, from: nil)
				}
				.disabled(store.feedbackHistory.items.isEmpty)
				Button("Clear", role: .destructive) {
					store.send(.clearFeedbackHistory)
				}
				.disabled(store.feedbackHistory.items.isEmpty)
			}
		} icon: {
			Image(systemName: "list.bullet.rectangle")
		}
	}

	// MARK: - Privacy

	private var privacyFooter: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Privacy")
				.font(.footnote.weight(.semibold))
			Text("When the coach is on, recordings longer than your trigger threshold are uploaded to the LLM provider you choose, along with the transcript Hex produced on-device and your native-language / target-accent settings. Nothing else (clipboard contents, mic audio outside an active recording, other transcripts) is sent. Your API key is stored in the macOS Keychain. The coach can be turned off at any time.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		.padding(.top, 4)
	}
}

extension CoachProvider {
	var displayName: String {
		switch self {
		case .gemini: return "Gemini"
		case .openai: return "OpenAI"
		}
	}
}
