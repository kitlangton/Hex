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

	/// Where FluidAudio (Parakeet) keeps its on-disk model caches.
	///
	/// FluidAudio writes to `<Application Support>/FluidAudio/Models/<variant>` in
	/// the sandboxed container, regardless of `XDG_CACHE_HOME`. We surface that
	/// location so "Show in Finder" can reveal Parakeet caches instead of the
	/// WhisperKit-only models directory.
	static var hexParakeetModelsDirectory: URL {
		get throws {
			let fm = FileManager.default
			let appSupport = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			let dir = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
			try fm.createDirectory(at: dir, withIntermediateDirectories: true)
			return dir
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
