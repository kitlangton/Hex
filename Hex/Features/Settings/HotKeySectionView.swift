import ComposableArchitecture
import HexCore
import SwiftUI

struct HotKeySectionView: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Section("Hot Key") {
            let hotKey = store.hexSettings.hotkey
            let key = store.isSettingHotKey ? nil : hotKey.key
            let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers

            VStack(spacing: 12) {
                // Hot key view
                HStack {
                    Spacer()
                    HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
                        .animation(.spring(), value: key)
                        .animation(.spring(), value: modifiers)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.send(.startSettingHotKey)
                }
            }

            // Double-tap toggle (for key+modifier combinations)
            if hotKey.key != nil {
                Label {
                    Toggle("Use double-tap only", isOn: $store.hexSettings.useDoubleTapOnly)
                } icon: {
                    Image(systemName: "hand.tap")
                }
            }

            // Minimum key time (for modifier-only shortcuts)
            if store.hexSettings.hotkey.key == nil {
                Label {
                    Slider(value: $store.hexSettings.minimumKeyTime, in: 0.0 ... 2.0, step: 0.1) {
                        Text("Ignore below \(store.hexSettings.minimumKeyTime, specifier: "%.1f")s")
                    }
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
        
    }
}
