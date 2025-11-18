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
		}
	}
}

struct HexApplicationAutomation {
	func openApplication(bundleIdentifier: String, activate: Bool) async throws -> String {
		let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw HexToolServerError.invalidBundleIdentifier
		}
		
		return try await MainActor.run {
			if let running = NSRunningApplication.runningApplications(withBundleIdentifier: trimmed).first {
				if activate {
					running.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
				}
				return "Activated running application '\(trimmed)'."
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
	}
}
