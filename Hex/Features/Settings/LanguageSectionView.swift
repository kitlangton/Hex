import SwiftUI
#if canImport(ComposableArchitecture)
	import ComposableArchitecture
#endif

struct LanguageSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Label {
			Picker("Output Language", selection: $store.hexSettings.outputLanguage) {
				ForEach(store.languages, id: \.id) { language in
					Text(language.name).tag(language.code)
				}
			}
			.pickerStyle(.menu)
		} icon: {
			Image(systemName: "globe")
		}
	}
}
