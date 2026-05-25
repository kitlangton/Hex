import AppKit
import ComposableArchitecture
import HexCore
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
		// HexAppDelegate creates the menu-bar status item and popover directly.
		// We expose only an empty Settings scene so SwiftUI has a Scene to drive.
		Settings { EmptyView() }
	}
}
