import ComposableArchitecture
import Inject
import Sparkle
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
  
	var body: some Scene {
		MenuBarExtra {
			CheckForUpdatesView()

			Button("Settings...") {
				appDelegate.presentSettingsView()
			}.keyboardShortcut(",")
			
			Divider()
			
			Button("Quit") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			Image("HexIcon")
				.resizable()
				.aspectRatio(contentMode: .fit)
				.frame(width: 18, height: 18)
		}


		WindowGroup {}.defaultLaunchBehavior(.suppressed)
			.commands {
				CommandGroup(after: .appInfo) {
					CheckForUpdatesView()

					Button("Settings...") {
						appDelegate.presentSettingsView()
					}.keyboardShortcut(",")
				}
			}
	}
}
