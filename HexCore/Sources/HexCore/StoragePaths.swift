import Foundation

public extension URL {
	static var hexApplicationSupport: URL {
		get throws {
			let fm = FileManager.default
			let appSupport = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			let hexDirectory = appSupport.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
			try fm.createDirectory(at: hexDirectory, withIntermediateDirectories: true)
			return hexDirectory
		}
	}

	static var legacyDocumentsDirectory: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	}

	static func hexMigratedFileURL(named fileName: String) -> URL {
		let newURL = (try? hexApplicationSupport.appending(component: fileName))
			?? documentsDirectory.appending(component: fileName)
		let legacyURL = legacyDocumentsDirectory.appending(component: fileName)
		FileManager.default.migrateIfNeeded(from: legacyURL, to: newURL)
		return newURL
	}

	static var hexModelsDirectory: URL {
		get throws {
			let modelsDirectory = try hexApplicationSupport.appendingPathComponent("models", isDirectory: true)
			try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
			return modelsDirectory
		}
	}

	static var hexOpenCodeWorkspaceDirectory: URL {
		get throws {
			let workspaceDirectory = try hexApplicationSupport.appendingPathComponent("OpenCode", isDirectory: true)
			let configDirectory = workspaceDirectory.appendingPathComponent(".opencode", isDirectory: true)
			let fm = FileManager.default
			try fm.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
			try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
			try fm.createDirectory(at: configDirectory.appendingPathComponent("tool", isDirectory: true), withIntermediateDirectories: true)
			try fm.createDirectory(at: configDirectory.appendingPathComponent("plugin", isDirectory: true), withIntermediateDirectories: true)
			try fm.createDirectory(at: configDirectory.appendingPathComponent("agent", isDirectory: true), withIntermediateDirectories: true)
			return workspaceDirectory
		}
	}
}

public extension FileManager {
	func migrateIfNeeded(from legacy: URL, to new: URL) {
		guard fileExists(atPath: legacy.path), !fileExists(atPath: new.path) else { return }
		try? copyItem(at: legacy, to: new)
	}

	func removeItemIfExists(at url: URL) {
		guard fileExists(atPath: url.path) else { return }
		try? removeItem(at: url)
	}
}
