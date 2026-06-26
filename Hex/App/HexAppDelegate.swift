import Combine
import ComposableArchitecture
import HexCore
import SwiftUI

private let appLogger = HexLog.app
private let cacheLogger = HexLog.caches

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	var statusItem: NSStatusItem!
	var coachPanel: NSPanel!
	private var coachOutsideClickMonitor: Any?
	private var launchedAtLogin = false
	private var settingsObserver: AnyCancellable?

	@Dependency(\.soundEffects) var soundEffect
	@Dependency(\.recording) var recording
	@Shared(.hexSettings) var hexSettings: HexSettings

	func applicationDidFinishLaunching(_: Notification) {
		DiagnosticsLogging.bootstrapIfNeeded()
		// Ensure Parakeet/FluidAudio caches live under Application Support, not ~/.cache
		configureLocalCaches()
		if isTesting {
			appLogger.debug("Running in testing mode")
			return
		}

		Task {
			await soundEffect.preloadSounds()
			await soundEffect.setEnabled(hexSettings.soundEffectsEnabled)
		}
		launchedAtLogin = wasLaunchedAtLogin()
		appLogger.info("Application did finish launching")
		appLogger.notice("launchedAtLogin = \(self.launchedAtLogin)")

		// Set activation policy first
		updateAppMode()

		// Add notification observers
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: .updateAppMode,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleCoachPresentPopover),
			name: .coachShouldPresentPopover,
			object: nil
		)

		// Status bar UI (replaces SwiftUI MenuBarExtra)
		setupStatusItemAndPopover()

		// Start long-running app effects (global hotkeys, permissions, etc.)
		startLifecycleTasksIfNeeded()

		// Then present main views
		presentMainView()

		guard shouldOpenForegroundUIOnLaunch else {
			appLogger.notice("Suppressing foreground windows for login launch")
			return
		}

		presentSettingsView()
		NSApp.activate(ignoringOtherApps: true)
	}

	private var shouldOpenForegroundUIOnLaunch: Bool {
		!launchedAtLogin
	}

	private func wasLaunchedAtLogin() -> Bool {
		guard let event = NSAppleEventManager.shared().currentAppleEvent else {
			return false
		}

		return event.eventID == AEEventID(kAEOpenApplication)
			&& event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
	}

	private func startLifecycleTasksIfNeeded() {
		Task { @MainActor in
			await HexApp.appStore.send(.task).finish()
		}
	}

	private func configureLocalCaches() {
		do {
			let cache = try URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
			try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
			setenv("XDG_CACHE_HOME", cache.path, 1)
			cacheLogger.info("XDG_CACHE_HOME set to \(cache.path)")
		} catch {
			cacheLogger.error("Failed to configure local caches: \(error.localizedDescription)")
		}
	}

	// MARK: - Status item + popover

	private func setupStatusItemAndPopover() {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		if let button = statusItem.button {
			button.target = self
			button.action = #selector(statusItemClicked(_:))
			button.sendAction(on: [.leftMouseUp, .rightMouseUp])
			refreshStatusIcon(on: button)
		}

		coachPanel = makeCoachPanel()

		// Keep the menu-bar dot in sync with the coach toggle.
		settingsObserver = $hexSettings.publisher
			.map { $0.coach.enabled }
			.removeDuplicates()
			.sink { [weak self] _ in
				Task { @MainActor in
					guard let self, let button = self.statusItem.button else { return }
					self.refreshStatusIcon(on: button)
				}
			}
	}

	private func refreshStatusIcon(on button: NSStatusBarButton) {
		guard let base = NSImage(named: "HexIcon") else { return }
		let scaled = scaledMenuBarImage(base, target: 18)
		button.image = hexSettings.coach.enabled
			? imageWithDot(on: scaled)
			: scaled
	}

	private func scaledMenuBarImage(_ image: NSImage, target: CGFloat) -> NSImage {
		let copy = NSImage(size: image.size)
		copy.addRepresentations(image.representations)
		let ratio = copy.size.height / max(copy.size.width, 1)
		copy.size = NSSize(width: target / ratio, height: target)
		copy.isTemplate = true
		return copy
	}

	private func imageWithDot(on base: NSImage) -> NSImage {
		let size = base.size
		let composite = NSImage(size: size)
		composite.lockFocus()
		base.draw(in: NSRect(origin: .zero, size: size))
		let dotDiameter: CGFloat = 6
		let dotRect = NSRect(
			x: size.width - dotDiameter - 1,
			y: size.height - dotDiameter - 1,
			width: dotDiameter,
			height: dotDiameter
		)
		NSColor.systemGreen.setFill()
		NSBezierPath(ovalIn: dotRect).fill()
		composite.unlockFocus()
		composite.isTemplate = false
		return composite
	}

	@objc private func statusItemClicked(_ sender: Any?) {
		let event = NSApp.currentEvent
		let isRightClick = event?.type == .rightMouseUp
			|| (event?.modifierFlags.contains(.control) ?? false)

		if isRightClick {
			showStatusMenu()
		} else {
			toggleCoachPopover()
		}
	}

	func toggleCoachPopover() {
		if coachPanel.isVisible {
			hideCoachPanel()
		} else {
			showCoachPanel()
		}
	}

	private func makeCoachPanel() -> NSPanel {
		let panel = NSPanel(
			contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isReleasedWhenClosed = false
		panel.level = .statusBar
		panel.hidesOnDeactivate = false
		panel.isFloatingPanel = true
		panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
		panel.hasShadow = true
		panel.backgroundColor = .clear
		panel.isOpaque = false

		let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
		effect.material = .popover
		effect.state = .active
		effect.blendingMode = .behindWindow
		effect.wantsLayer = true
		effect.layer?.cornerRadius = 12
		effect.layer?.masksToBounds = true

		let coachStore = HexApp.appStore.scope(state: \.coach, action: \.coach)
		let hosting = NSHostingView(rootView: CoachPopoverView(store: coachStore))
		hosting.translatesAutoresizingMaskIntoConstraints = false
		effect.addSubview(hosting)
		NSLayoutConstraint.activate([
			hosting.topAnchor.constraint(equalTo: effect.topAnchor),
			hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
			hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
			hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
		])

		panel.contentView = effect
		return panel
	}

	private func showCoachPanel() {
		// Position top-right of whatever screen the cursor is currently on,
		// just below the menu bar. Falls back to the main screen if needed.
		let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
			?? NSScreen.main
		guard let visible = screen?.visibleFrame else { return }
		let size = coachPanel.frame.size
		let margin: CGFloat = 12
		let origin = NSPoint(
			x: visible.maxX - size.width - margin,
			y: visible.maxY - size.height - margin
		)
		coachPanel.setFrameOrigin(origin)
		coachPanel.orderFrontRegardless()

		installOutsideClickMonitor()
	}

	private func hideCoachPanel() {
		coachPanel.orderOut(nil)
		removeOutsideClickMonitor()
	}

	private func installOutsideClickMonitor() {
		removeOutsideClickMonitor()
		coachOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
			guard let self else { return }
			Task { @MainActor in
				self.hideCoachPanel()
			}
		}
	}

	private func removeOutsideClickMonitor() {
		if let monitor = coachOutsideClickMonitor {
			NSEvent.removeMonitor(monitor)
			coachOutsideClickMonitor = nil
		}
	}

	private func showStatusMenu() {
		let menu = NSMenu()

		let checkUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckForUpdates(_:)), keyEquivalent: "")
		checkUpdates.target = self
		menu.addItem(checkUpdates)

		let copyLast = NSMenuItem(title: "Copy Last Transcript", action: #selector(menuCopyLastTranscript(_:)), keyEquivalent: "")
		copyLast.target = self
		menu.addItem(copyLast)

		menu.addItem(.separator())

		let coachItem = NSMenuItem(
			title: hexSettings.coach.enabled ? "Pronunciation Coach: On" : "Pronunciation Coach: Off",
			action: #selector(menuToggleCoach(_:)),
			keyEquivalent: ""
		)
		coachItem.target = self
		coachItem.state = hexSettings.coach.enabled ? .on : .off
		menu.addItem(coachItem)

		let showCoach = NSMenuItem(title: "Show Coach…", action: #selector(menuShowCoach(_:)), keyEquivalent: "")
		showCoach.target = self
		menu.addItem(showCoach)

		menu.addItem(.separator())

		let settings = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings(_:)), keyEquivalent: ",")
		settings.target = self
		menu.addItem(settings)

		menu.addItem(.separator())

		let quit = NSMenuItem(title: "Quit", action: #selector(menuQuit(_:)), keyEquivalent: "q")
		quit.target = self
		menu.addItem(quit)

		statusItem.menu = menu
		statusItem.button?.performClick(nil)
		// Detach menu so future left-clicks don't open it.
		statusItem.menu = nil
	}

	@objc private func menuCheckForUpdates(_ sender: Any?) {
		Task { @MainActor in
			CheckForUpdatesViewModel.shared.checkForUpdates()
		}
	}

	@objc private func menuCopyLastTranscript(_ sender: Any?) {
		Task { @MainActor in
			await HexApp.appStore.send(.pasteLastTranscript).finish()
		}
	}

	@objc private func menuToggleCoach(_ sender: Any?) {
		Task { @MainActor in
			let newValue = !hexSettings.coach.enabled
			await HexApp.appStore.send(.coach(.setEnabled(newValue))).finish()
		}
	}

	@objc private func menuShowCoach(_ sender: Any?) {
		Task { @MainActor in
			toggleCoachPopover()
		}
	}

	@objc func showCoachPopover(_ sender: Any?) {
		Task { @MainActor in
			toggleCoachPopover()
		}
	}

	@objc private func menuOpenSettings(_ sender: Any?) {
		presentSettingsView()
	}

	@objc private func menuQuit(_ sender: Any?) {
		NSApp.terminate(nil)
	}

	// MARK: - Windows

	func presentMainView() {
		guard invisibleWindow == nil else {
			return
		}
		let transcriptionStore = HexApp.appStore.scope(state: \.transcription, action: \.transcription)
		let transcriptionView = TranscriptionView(store: transcriptionStore).padding().padding(.top).padding(.top)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		invisibleWindow = InvisibleWindow.fromView(transcriptionView)
		invisibleWindow?.orderFrontRegardless()
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
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		settingsWindow.titleVisibility = .visible
		settingsWindow.contentView = NSHostingView(rootView: settingsView)
		settingsWindow.isReleasedWhenClosed = false
		settingsWindow.minSize = .init(width: 620, height: 560)
		settingsWindow.setFrameAutosaveName("Settings")
		settingsWindow.center()
		settingsWindow.toolbarStyle = NSWindow.ToolbarStyle.unified
		settingsWindow.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		self.settingsWindow = settingsWindow
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
		}
	}

	@objc private func handleCoachPresentPopover() {
		Task { @MainActor in
			guard !coachPanel.isVisible else { return }
			showCoachPanel()
		}
	}

	@MainActor
	private func updateAppMode() {
		appLogger.debug("showDockIcon = \(self.hexSettings.showDockIcon)")
		if self.hexSettings.showDockIcon {
			NSApp.setActivationPolicy(.regular)
		} else {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		presentSettingsView()
		return true
	}

	func applicationWillTerminate(_: Notification) {
		Task {
			await recording.cleanup()
		}
	}
}
