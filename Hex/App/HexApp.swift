import ComposableArchitecture
import Inject
import Sparkle
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
    var body: some Scene {
        MenuBarExtra {
            MenuBarCopyLastTranscriptButton()
            MenuBarRefineSelectedTextButton()

            Button("Settings…") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")

            CheckForUpdatesView()
			
			Divider()
			
			Button("Quit Hex") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			if let image = NSImage(named: "HexIcon").map({
				let ratio = $0.size.height / $0.size.width
				$0.size.height = 18
				$0.size.width = 18 / ratio
				return $0
			}) {
				Image(nsImage: image)
			} else {
				Image(systemName: "hexagon")
			}
		}
		.commands {
			CommandGroup(after: .appInfo) {
				CheckForUpdatesView()

				Button("Settings…") {
					appDelegate.presentSettingsView()
				}.keyboardShortcut(",")
			}

			CommandGroup(replacing: .help) {}
		}
	}
}
