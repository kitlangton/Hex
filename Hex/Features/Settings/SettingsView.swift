import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
	@Bindable var store: StoreOf<SettingsFeature>
	@State var viewModel = CheckForUpdatesViewModel.shared
	@State private var showingChangelog = false

	var body: some View {
		Form {
			// --- Permissions Section ---
			Section {
				// Microphone
				HStack {
					Label("Microphone", systemImage: "mic.fill")
					Spacer()
					switch store.microphonePermission {
					case .granted:
						Label("Granted", systemImage: "checkmark.circle.fill")
							.foregroundColor(.green)
							.labelStyle(.iconOnly)
					case .denied:
						Button("Request Permission") {
							store.send(.requestMicrophonePermission)
						}
						.buttonStyle(.borderedProminent)
						.tint(.blue)
					case .notDetermined:
						Button("Request Permission") {
							store.send(.requestMicrophonePermission)
						}
						.buttonStyle(.bordered)
					}
				}

				// Accessibility
				HStack {
					Label("Accessibility", systemImage: "accessibility")
					Spacer()
					switch store.accessibilityPermission {
					case .granted:
						Label("Granted", systemImage: "checkmark.circle.fill")
							.foregroundColor(.green)
							.labelStyle(.iconOnly)
					case .denied:
						Button("Request Permission") {
							store.send(.requestAccessibilityPermission)
						}
						.buttonStyle(.borderedProminent)
						.tint(.blue)
					case .notDetermined:
						Button("Request Permission") {
							store.send(.requestAccessibilityPermission)
						}
						.buttonStyle(.bordered)
					}
				}

			} header: {
				Text("Permissions")
			} footer: {
				Text("Ensure Hex can access your microphone and system accessibility features.")
					.font(.footnote)
					.foregroundColor(.secondary)
			}

			// --- Transcription Model Section ---
			Section("Transcription Model") {
				ModelDownloadView(store: store.scope(state: \.modelDownload, action: \.modelDownload)
				)
			}

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

			// --- Hot Key Section ---
			Section("Hot Key") {
				let hotKey = store.hexSettings.hotkey
				let key = store.isSettingHotKey ? nil : hotKey.key
				let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers
				HStack{
					Spacer()
					HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
						.animation(.spring(), value: key)
						.animation(.spring(), value: modifiers)
					Spacer()
				}.contentShape(Rectangle())
				.onTapGesture {
					store.send(.startSettingHotKey)
				}
                if store.hexSettings.hotkey.key == nil {
                    Label {
                        Slider(value: $store.hexSettings.minimumKeyTime, in: 0.0...2.0, step: 0.1) {
                            Text("Ignore below \(store.hexSettings.minimumKeyTime, specifier: "%.1f")s")
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
			}

			// --- Sound Section ---
			Section {
				Label {
					Toggle("Sound Effects", isOn: $store.hexSettings.soundEffectsEnabled)
				} icon: {
					Image(systemName: "speaker.wave.2.fill")
				}
			} header: {
				Text("Sound")
			}

			// --- General Section ---
			Section {
				Label {
					Toggle("Open on Login",
					       isOn: Binding(
					       	get: { store.hexSettings.openOnLogin },
					       	set: { store.send(.toggleOpenOnLogin($0)) }
					       ))
				} icon: {
					Image(systemName: "arrow.right.circle")
				}

				Label {
					Toggle("Show Dock Icon", isOn: $store.hexSettings.showDockIcon)
				} icon: {
					Image(systemName: "dock.rectangle")
				}

				Label {
					Toggle("Use clipboard to insert", isOn: $store.hexSettings.useClipboardPaste)
					Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
				} icon: {
					Image(systemName: "doc.on.doc.fill")
				}

				Label {
					Toggle(
						"Prevent System Sleep while Recording",
						isOn: Binding(
							get: { store.hexSettings.preventSystemSleep },
							set: { store.send(.togglePreventSystemSleep($0)) }
						))
				} icon: {
					Image(systemName: "zzz")
				}
                
                Label {
                    Toggle(
                        "Pause Media while Recording",
                        isOn: Binding(
                            get: { store.hexSettings.pauseMediaOnRecord },
                            set: { store.send(.togglePauseMediaOnRecord($0)) }
                        ))
                } icon: {
                    Image(systemName: "pause")
                }
			} header: {
				Text("General")
			}

			// --- About Section ---
			Section("About") {
				HStack {
					Label("Version", systemImage: "info.circle")
					Spacer()
					Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
					Button("Check for Updates") {
						viewModel.checkForUpdates()
					}
					.buttonStyle(.bordered)
				}
				HStack {
					Label("Changelog", systemImage: "doc.text")
					Spacer()
					Button("Show Changelog") {
						showingChangelog.toggle()
					}
					.buttonStyle(.bordered)
					.sheet(isPresented: $showingChangelog, onDismiss: {
						showingChangelog = false
					}) {
						ChangelogView()
					}
				}
				HStack {
					Label("Hex is open source", systemImage: "apple.terminal.on.rectangle")
					Spacer()
					Link("Visit our GitHub", destination: URL(string: "https://github.com/kitlangton/Hex/")!)
				}
			}
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
	}
}
