@preconcurrency import AppKit
import Foundation
import SwiftMCP

@MCPServer(name: "Hex Tools")
actor HexToolServerActor {
    private var allowedGroups: Set<HexToolGroup>
    private let automation: HexApplicationAutomation
    
    init(configuration: HexToolServerConfiguration = .init(enabledToolGroups: [])) {
        self.allowedGroups = Set(configuration.enabledToolGroups)
        self.automation = HexApplicationAutomation()
    }
    
    func updateAllowedGroups(_ groups: Set<HexToolGroup>) {
        allowedGroups = groups
    }
	
	@MCPTool(
		description: "Launches or focuses a macOS application by bundle identifier.",
		isConsequential: true
	)
	func openApplication(bundleIdentifier: String, activate: Bool = true) async throws -> String {
		try ensureGroup(.appControl)
		return try await automation.openApplication(bundleIdentifier: bundleIdentifier, activate: activate)
	}

	@MCPTool(
		description: "Opens a URL using the system default handler (e.g., browser).",
		isConsequential: true
	)
	func openURL(_ url: String, activate: Bool = true) async throws -> String {
		try ensureGroup(.appControl)
		return try await automation.openURL(urlString: url, activate: activate)
	}

	@MCPTool(
		description: "Lists installed macOS applications with names, bundle identifiers, and paths.",
		isConsequential: false
	)
	func listApplications(query: String? = nil, limit: Int = 50) async throws -> [InstalledApplicationInfo] {
		try ensureGroup(.appDiscovery)
		return try await automation.listInstalledApplications(matching: query, limit: limit)
	}

	@MCPTool(
		description: "Captures the currently selected text from the frontmost application without leaving clipboard residue.",
		isConsequential: false
	)
	func getSelectedText(timeoutMilliseconds: Int = 400) async throws -> SelectedTextResult {
		try ensureGroup(.context)
		return try await automation.readSelectedText(timeoutMilliseconds: timeoutMilliseconds)
	}

	@MCPTool(
		description: "Reads the current clipboard's plain-text contents along with available data types.",
		isConsequential: false
	)
	func getClipboardText() async throws -> ClipboardSnapshot {
		try ensureGroup(.context)
		return await automation.readClipboard()
	}

	private func ensureGroup(_ group: HexToolGroup) throws {
		guard allowedGroups.contains(group) else {
			throw HexToolServerError.toolGroupDisabled(group.rawValue)
		}
	}
}

enum HexToolServerError: Error, LocalizedError {
	case toolGroupDisabled(String)
	case invalidBundleIdentifier
	case applicationNotFound(String)
	case launchFailed(String)
	case invalidURL(String)
	case urlOpenFailed(String)
	case clipboardUnavailable
	case frontmostAppUnavailable
	case selectionTimeout
	case emptySelection(String)
	case automationFailed(String)

	var errorDescription: String? {
		switch self {
		case .toolGroupDisabled(let group):
			return "Tool group '\(group)' is not enabled for this session."
		case .invalidBundleIdentifier:
			return "A valid bundle identifier is required."
		case .applicationNotFound(let bundleID):
			return "No application was found for bundle identifier '\(bundleID)'."
		case .launchFailed(let bundleID):
			return "Failed to launch application '\(bundleID)'."
		case .invalidURL(let value):
			return "A valid URL is required (received: \(value))."
		case .urlOpenFailed(let url):
			return "Failed to open URL '\(url)'."
		case .clipboardUnavailable:
			return "The clipboard could not be read."
		case .frontmostAppUnavailable:
			return "Could not determine the frontmost application."
		case .selectionTimeout:
			return "Timed out waiting for the selected text to be copied."
		case .emptySelection(let appName):
			return "The frontmost app (\(appName)) did not provide any selected text."
		case .automationFailed(let reason):
			return reason
		}
	}
}

struct HexApplicationAutomation {
	private static let applicationDirectories: [URL] = {
		let fm = FileManager.default
		var directories: [URL] = [
			URL(fileURLWithPath: "/Applications", isDirectory: true),
			URL(fileURLWithPath: "/System/Applications", isDirectory: true)
		]
		let userApplications = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
		directories.append(userApplications)
		return directories
	}()

	@MainActor
	func openApplication(bundleIdentifier: String, activate: Bool) async throws -> String {
		let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw HexToolServerError.invalidBundleIdentifier
		}

		if let running = NSRunningApplication.runningApplications(withBundleIdentifier: trimmed).first {
			if activate {
				running.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
			}
			return "Activated running application '\(trimmed)'."
		}

		guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) != nil else {
			throw HexToolServerError.applicationNotFound(trimmed)
		}

		guard NSWorkspace.shared.launchApplication(
			withBundleIdentifier: trimmed,
			options: [.default],
			additionalEventParamDescriptor: nil,
			launchIdentifier: nil
		) else {
			throw HexToolServerError.launchFailed(trimmed)
		}

		if activate,
		   let running = NSRunningApplication.runningApplications(withBundleIdentifier: trimmed).first {
			running.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
		}

		return "Launched application '\(trimmed)'."
	}

	@MainActor
	func openURL(urlString: String, activate: Bool) async throws -> String {
		let targetURL = try sanitizeURL(from: urlString)
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = activate
		do {
			try await NSWorkspace.shared.open(targetURL, configuration: configuration)
			return "Opened URL '\(targetURL.absoluteString)'\(activate ? " and activated the handler." : ".")"
		} catch {
			throw HexToolServerError.urlOpenFailed(targetURL.absoluteString)
		}
	}

	@MainActor
	func listInstalledApplications(matching query: String?, limit: Int) async throws -> [InstalledApplicationInfo] {
		let fm = FileManager.default
		let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let clampedLimit = max(1, min(limit, 200))
		let directories = Self.applicationDirectories.filter { fm.fileExists(atPath: $0.path) }
		let runningBundleIDs = await MainActor.run {
			Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
		}

		var seenBundleIDs: Set<String> = []
		var results: [InstalledApplicationInfo] = []
		let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]

		for directory in directories {
			guard let enumerator = fm.enumerator(
				at: directory,
				includingPropertiesForKeys: Array(resourceKeys),
				options: [.skipsHiddenFiles, .skipsPackageDescendants]
			) else { continue }

			while let entry = enumerator.nextObject() as? URL {
				guard entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
				guard let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier else { continue }
				guard seenBundleIDs.insert(bundleID).inserted else { continue }

				let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
					?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
					?? entry.deletingPathExtension().lastPathComponent
				if let normalizedQuery, !normalizedQuery.isEmpty {
					let haystack = "\(appName.lowercased()) \(bundleID.lowercased())"
					if !haystack.contains(normalizedQuery) {
						continue
					}
				}

				var modificationDate: Date?
				if let values = try? entry.resourceValues(forKeys: resourceKeys) {
					modificationDate = values.contentModificationDate
				}

				let info = InstalledApplicationInfo(
					bundleIdentifier: bundleID,
					name: appName,
					path: entry.path,
					version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
					isRunning: runningBundleIDs.contains(bundleID),
					lastModified: modificationDate
				)
				results.append(info)
			}
		}

		let sorted = results.sorted { lhs, rhs in
			lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
		}
		return Array(sorted.prefix(clampedLimit))
	}

	@MainActor
	func readClipboard() -> ClipboardSnapshot {
		let pasteboard = NSPasteboard.general
		let availableTypes = Set(pasteboard.pasteboardItems?.flatMap { $0.types.map { $0.rawValue } } ?? [])
		return ClipboardSnapshot(
			plainText: pasteboard.string(forType: .string),
			availableTypes: Array(availableTypes).sorted(),
			changeCount: pasteboard.changeCount,
			timestamp: Date()
		)
	}

	@MainActor
	func readSelectedText(timeoutMilliseconds: Int) async throws -> SelectedTextResult {
		guard let frontmost = NSWorkspace.shared.frontmostApplication else {
			throw HexToolServerError.frontmostAppUnavailable
		}

		let pasteboard = NSPasteboard.general
		let snapshot = capturePasteboardSnapshot(pasteboard: pasteboard)
		let timeout = Duration.milliseconds(max(100, min(timeoutMilliseconds, 2_000)))
		let appDisplayName = frontmost.localizedName ?? frontmost.bundleIdentifier ?? "current app"

		do {
			try triggerCopyShortcut()
		} catch {
			restorePasteboardSnapshot(pasteboard: pasteboard, snapshot: snapshot)
			throw error
		}

		let didChange = await waitForPasteboardChange(pasteboard: pasteboard, timeout: timeout)
		guard didChange else {
			restorePasteboardSnapshot(pasteboard: pasteboard, snapshot: snapshot)
			throw HexToolServerError.selectionTimeout
		}

		let copied = pasteboard.string(forType: .string) ?? ""
		restorePasteboardSnapshot(pasteboard: pasteboard, snapshot: snapshot)

		guard !copied.isEmpty else {
			throw HexToolServerError.emptySelection(appDisplayName)
		}

		return SelectedTextResult(
			text: copied,
			sourceBundleIdentifier: frontmost.bundleIdentifier,
			sourceApplicationName: frontmost.localizedName,
			timestamp: Date(),
			clipboardRestored: true
		)
	}

	@MainActor
	private func triggerCopyShortcut() throws {
		let script = """
	if application \"System Events\" is not running then
	    tell application \"System Events\" to launch
	    delay 0.05
	end if
	tell application \"System Events\"
	    keystroke \"c\" using {command down}
	end tell
	"""
		guard let appleScript = NSAppleScript(source: script) else {
			throw HexToolServerError.automationFailed("Failed to create automation script for copy.")
		}
		var errorDict: NSDictionary?
		appleScript.executeAndReturnError(&errorDict)
		if let errorDict {
			throw HexToolServerError.automationFailed("System Events copy failed: \(errorDict)")
		}
	}

	@MainActor
	private func capturePasteboardSnapshot(pasteboard: NSPasteboard) -> PasteboardSnapshotState {
		var storedItems: [[PasteboardSnapshotState.PasteboardRepresentation]] = []
		for item in pasteboard.pasteboardItems ?? [] {
			var representations: [PasteboardSnapshotState.PasteboardRepresentation] = []
			for type in item.types {
				if let data = item.data(forType: type) {
					representations.append(.init(type: type, data: data))
				}
			}
			storedItems.append(representations)
		}
		return PasteboardSnapshotState(items: storedItems)
	}

	@MainActor
	private func restorePasteboardSnapshot(pasteboard: NSPasteboard, snapshot: PasteboardSnapshotState) {
		pasteboard.clearContents()
		guard !snapshot.items.isEmpty else { return }
		let items: [NSPasteboardItem] = snapshot.items.map { representations in
			let item = NSPasteboardItem()
			representations.forEach { representation in
				item.setData(representation.data, forType: representation.type)
			}
			return item
		}
		pasteboard.writeObjects(items)
	}

	@MainActor
	private func waitForPasteboardChange(
		pasteboard: NSPasteboard,
		timeout: Duration,
		pollInterval: Duration = .milliseconds(25)
	) async -> Bool {
		let targetChangeCount = pasteboard.changeCount + 1
		let clock = ContinuousClock()
		let deadline = clock.now + timeout
		while clock.now < deadline {
			if pasteboard.changeCount >= targetChangeCount {
				return true
			}
			try? await Task.sleep(for: pollInterval)
		}
		return pasteboard.changeCount >= targetChangeCount
	}

	private func sanitizeURL(from value: String) throws -> URL {
		var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw HexToolServerError.invalidURL(value)
		}
		if !trimmed.contains("://") {
			trimmed = "https://\(trimmed)"
		}
		guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
			throw HexToolServerError.invalidURL(value)
		}
		return url
	}
}

private struct PasteboardSnapshotState {
	struct PasteboardRepresentation {
		let type: NSPasteboard.PasteboardType
		let data: Data
	}

	let items: [[PasteboardRepresentation]]
}

struct InstalledApplicationInfo: Codable, Sendable {
	let bundleIdentifier: String
	let name: String
	let path: String
	let version: String?
	let isRunning: Bool
	let lastModified: Date?
}

struct ClipboardSnapshot: Codable, Sendable {
	let plainText: String?
	let availableTypes: [String]
	let changeCount: Int
	let timestamp: Date
}

struct SelectedTextResult: Codable, Sendable {
	let text: String
	let sourceBundleIdentifier: String?
	let sourceApplicationName: String?
	let timestamp: Date
	let clipboardRestored: Bool
}

// Shakespeare, I have to take out the trash in a minute.
// Shakespeare, I have no way to go.
