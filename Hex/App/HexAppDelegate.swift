import ComposableArchitecture
import SwiftUI
import AppKit
import Sparkle

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	var statusItem: NSStatusItem!
	private var statusMenu: NSMenu?
	private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

	@Dependency(\.soundEffects) var soundEffect
	@Shared(.hexSettings) var hexSettings: HexSettings

	func applicationDidFinishLaunching(_: Notification) {
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

		// Create persistent native status item in menu bar
		setupStatusItem()

		// Add notification observer
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: NSNotification.Name("UpdateAppMode"),
			object: nil
		)

		// Then present main views
		presentMainView()
		if !hexSettings.didCompleteFirstRun {
			presentSettingsView()
			$hexSettings.withLock { $0.didCompleteFirstRun = true }
		}
		NSApp.activate(ignoringOtherApps: true)
	}

	func presentMainView() {
		guard invisibleWindow == nil else {
			return
		}
		let transcriptionStore = HexApp.appStore.scope(state: \.transcription, action: \.transcription)
		let transcriptionView = TranscriptionView(store: transcriptionStore)
			.padding(EdgeInsets(top: 48, leading: 16, bottom: 16, trailing: 16))
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

	@MainActor
	private func setupStatusItem() {
		guard statusItem == nil else { return }
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		if let button = statusItem.button {
			let image = NSImage(named: NSImage.Name("HexStatusIcon"))
			image?.isTemplate = true
			image?.size = NSSize(width: 18, height: 18)
			button.image = image
			button.imageScaling = .scaleProportionallyDown
			button.imagePosition = .imageOnly
			button.toolTip = "Hex"
		}
		rebuildStatusMenu()
		statusItem.menu = statusMenu
	}

	@MainActor
	private func rebuildStatusMenu() {
		let menu = NSMenu()
		menu.autoenablesItems = true

		let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction(_:)), keyEquivalent: "")
		updatesItem.target = self
		menu.addItem(updatesItem)

		let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsAction(_:)), keyEquivalent: ",")
		settingsItem.target = self
		menu.addItem(settingsItem)

		menu.addItem(.separator())

		let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Hex"
		let quitTitle = "Quit \(appName)"
		let quitItem = NSMenuItem(title: quitTitle, action: #selector(quitAction(_:)), keyEquivalent: "q")
		quitItem.target = self
		menu.addItem(quitItem)

		self.statusMenu = menu
	}

	@objc
	private func checkForUpdatesAction(_ sender: Any?) {
		updaterController.checkForUpdates(sender)
	}

	@objc
	private func openSettingsAction(_ sender: Any?) {
		presentSettingsView()
	}

	@objc
	private func quitAction(_ sender: Any?) {
		NSApplication.shared.terminate(nil)
	}
}
