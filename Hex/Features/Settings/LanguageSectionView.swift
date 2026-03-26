import SwiftUI
import Inject
#if canImport(ComposableArchitecture)
	import ComposableArchitecture
#endif

struct LanguageSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
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
		.enableInjection()
	}
}
