import SwiftUI
import Inject
#if canImport(ComposableArchitecture)
	import ComposableArchitecture
#endif

struct LanguageSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Picker(
					"Output Language",
					selection: Binding(
						get: { store.hexSettings.outputLanguage },
						set: { store.send(.setOutputLanguage($0)) }
					)
				) {
					ForEach(store.languages, id: \.id) { language in
						Text(language.name).tag(language.code as String?)
					}
				}
				.pickerStyle(.menu)
			} icon: {
				Image(systemName: "globe")
			}

			Label {
				VStack(alignment: .leading, spacing: 4) {
					TextField(
						"e.g. use all lowercase, no trailing period",
						text: Binding(
							get: { store.hexSettings.whisperPrompt ?? "" },
							set: { store.send(.setWhisperPrompt($0)) }
						)
					)
					Text("Guides the model's output style. Whisper will try to match the tone and formatting of this prompt.")
						.settingsCaption()
				}
			} icon: {
				Image(systemName: "text.quote")
			}
		} header: {
			Text("Transcription")
		}
		.enableInjection()
	}
}
