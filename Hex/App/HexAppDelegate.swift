import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

private let appLogger = HexLog.app
private let cacheLogger = HexLog.caches

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	var agentWindow: AgentPanel?
	var statusItem: NSStatusItem!
	private var launchedAtLogin = false

	private var agentVisibilityToken: ObserveToken?

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

		// Add notification observer
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: .updateAppMode,
			object: nil
		)

		// Show/hide the agent voice window whenever the feature's visibility changes.
		agentVisibilityToken = observe { [weak self] in
			guard let self else { return }
			let visible = HexApp.appStore.agent.isVisible
			let wantsFocus = HexApp.appStore.agent.wantsFocus
			appLogger.notice("Agent panel visibility observed: visible=\(visible, privacy: .public) focus=\(wantsFocus, privacy: .public)")
			if visible {
				self.showAgentPanel(focus: wantsFocus)
			} else {
				self.hideAgentPanel()
			}
		}

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
		// When Hex launches at login, stay quietly in the menu bar regardless of
		// the dock-icon preference. Users who enabled "Open on Login" expect a
		// background launch; the Settings window can be opened later from the
		// menu bar item or ⌘, when needed.
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

	/// Sets XDG_CACHE_HOME so FluidAudio stores models under our app's
	/// Application Support folder, keeping everything in one place.
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

	// MARK: - Agent Plugins (Claude Code integration)

	/// Handles `hex://agent-update?…` deeplinks fired by the Claude Code hook script.
	func application(_: NSApplication, open urls: [URL]) {
		for url in urls where url.scheme == "hex" {
			handleHexURL(url)
		}
	}

	private func handleHexURL(_ url: URL) {
		appLogger.notice("Received hex URL: \(url.absoluteString, privacy: .public)")
		guard url.host == "agent-update" else {
			appLogger.notice("Ignoring unknown hex URL host: \(url.host ?? "nil", privacy: .public)")
			return
		}
		let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
		func value(_ name: String) -> String? {
			items.first { $0.name == name }?.value
		}

		let payload = AgentFeature.ShowPayload(
			event: value("event"),
			tool: value("tool"),
			sessionID: value("session"),
			cwd: value("cwd"),
			transcriptPath: value("transcript"),
			payloadPath: value("payload"),
			inlineMessage: value("message")
		)
		Task { @MainActor in
			HexApp.appStore.send(.agent(.show(payload)))
		}
	}

	private func showAgentPanel(focus: Bool) {
		if agentWindow == nil {
			let agentStore = HexApp.appStore.scope(state: \.agent, action: \.agent)
			agentWindow = AgentPanel.fromView(AgentView(store: agentStore))
		}
		guard let panel = agentWindow else { return }
		// Only (re)position when first coming on screen — never when merely engaging focus or
		// advancing the queue, which would make the card jump under the cursor.
		if !panel.isVisible {
			panel.positionNearMouse()
			panel.orderFrontRegardless()
		}
		// Become key only when the user summoned or engaged the window. A hook-driven passive
		// appearance must NOT steal keyboard focus from whatever the user is typing in.
		if focus {
			panel.makeKey()
		}
	}

	private func hideAgentPanel() {
		agentWindow?.orderOut(nil)
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
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
		// Release every still-blocked agent hook so quitting Hex never leaves a Claude
		// session hanging on its 600s timeout. An empty response yields to the terminal UI.
		for request in HexApp.appStore.agent.requests {
			if let payloadPath = request.payloadPath {
				AgentHookResponder.respond(payloadPath: payloadPath, json: nil)
			}
		}
		Task {
			await recording.cleanup()
		}
	}
}
