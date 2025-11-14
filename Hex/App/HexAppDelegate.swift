import ComposableArchitecture
import SwiftUI

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	var statusItem: NSStatusItem!

	@Dependency(\.soundEffects) var soundEffect
	@Shared(.hexSettings) var hexSettings: HexSettings

	func applicationDidFinishLaunching(_: Notification) {
		// Ensure Parakeet/FluidAudio caches live under Application Support, not ~/.cache
		configureLocalCaches()
		if isTesting {
			print("TESTING")
			return
		}

		Task {
			await soundEffect.preloadSounds()
		}
		print("HexAppDelegate did finish launching")

		// Set activation policy first
		updateAppMode()

		// Add notification observer
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: NSNotification.Name("UpdateAppMode"),
			object: nil
		)

		// Then present main views
		presentMainView()
		presentSettingsView()
		NSApp.activate(ignoringOtherApps: true)
	}

	/// Sets XDG_CACHE_HOME so FluidAudio stores models under our app's
	/// Application Support folder, keeping everything in one place.
    private func configureLocalCaches() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let cache = support.appendingPathComponent("com.kitlangton.Hex/cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            setenv("XDG_CACHE_HOME", cache.path, 1)
            print("[Hex] XDG_CACHE_HOME set to: \(cache.path)")
        } catch {
            print("Warning: failed to configure local caches: \(error)")
        }
    }

	func presentMainView() {
		guard invisibleWindow == nil else {
			return
		}
		let transcriptionStore = HexApp.appStore.scope(state: \.transcription, action: \.transcription)
		let transcriptionView = TranscriptionView(store: transcriptionStore).padding().padding(.top).padding(.top)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		invisibleWindow = InvisibleWindow.fromView(transcriptionView)
		invisibleWindow?.makeKeyAndOrderFront(nil)
	}

	func presentSettingsView() {
		if let settingsWindow = settingsWindow {
			settingsWindow.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let settingsView = AppView(store: HexApp.appStore)
		let settingsWindow = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable],
			backing: .buffered,
			defer: false
		)
		settingsWindow.titleVisibility = .visible
		settingsWindow.contentView = NSHostingView(rootView: settingsView)
		settingsWindow.makeKeyAndOrderFront(nil)
		settingsWindow.isReleasedWhenClosed = false
		settingsWindow.center()
        settingsWindow.toolbarStyle = NSWindow.ToolbarStyle.unified
		NSApp.activate(ignoringOtherApps: true)
		self.settingsWindow = settingsWindow
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
		}
	}

	@MainActor
	private func updateAppMode() {
		print("hexSettings.showDockIcon: \(hexSettings.showDockIcon)")
		if hexSettings.showDockIcon {
			NSApp.setActivationPolicy(.regular)
		} else {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		presentSettingsView()
		return true
	}
}
