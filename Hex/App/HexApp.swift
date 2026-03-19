import ComposableArchitecture
import HexCore
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
	@Shared(.hexSettings) var hexSettings: HexSettings

	private var menuBarSuffix: String {
		switch hexSettings.refinementMode {
		case .raw:
			return ""
		case .summarized:
			return "S"
		case .refined:
			return switch hexSettings.refinementTone {
			case .natural: "N"
			case .professional: "P"
			case .casual: "C"
			case .concise: "X"
			case .friendly: "F"
			}
		}
	}

    var body: some Scene {
        MenuBarExtra {
            CheckForUpdatesView()

            // Copy last transcript to clipboard
            MenuBarCopyLastTranscriptButton()

            Button("Settings...") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")

			Divider()

			Button("Quit") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			let image: NSImage = {
				let ratio = $0.size.height / $0.size.width
				$0.size.height = 18
				$0.size.width = 18 / ratio
				return $0
			}(NSImage(named: "HexIcon")!)

			HStack(spacing: 2) {
				Image(nsImage: image)
				if hexSettings.refinementMode != .raw {
					Text(menuBarSuffix)
						.font(.system(size: 10, weight: .bold, design: .rounded))
				}
			}
		}


		WindowGroup {}.defaultLaunchBehavior(.suppressed)
			.commands {
				CommandGroup(after: .appInfo) {
					CheckForUpdatesView()

					Button("Settings...") {
						appDelegate.presentSettingsView()
					}.keyboardShortcut(",")
				}

				CommandGroup(replacing: .help) {}
			}
	}
}
