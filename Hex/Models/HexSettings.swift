import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

// MARK: - URL Extensions

extension URL {
	/// Returns the Application Support directory for Hex
	static var hexApplicationSupport: URL {
		get throws {
			let fm = FileManager.default
			let appSupport = try fm.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			let hexDir = appSupport.appending(component: "com.kitlangton.Hex")
			try fm.createDirectory(at: hexDir, withIntermediateDirectories: true)
			return hexDir
		}
	}
	
	/// Legacy location in Documents (for migration)
	static var legacyDocumentsDirectory: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
	}
}

// To add a new setting, add a new property to the struct, the CodingKeys enum, and the custom decoder
struct HexSettings: Codable, Equatable {
	static let defaultPasteLastTranscriptHotkey = HotKey(key: .v, modifiers: [.option, .shift])
	static var defaultPasteLastTranscriptHotkeyDescription: String {
		let modifiers = defaultPasteLastTranscriptHotkey.modifiers.sorted.map { $0.stringValue }.joined()
		let key = defaultPasteLastTranscriptHotkey.key?.toString ?? ""
		return modifiers + key
	}
	var soundEffectsEnabled: Bool = true
	var hotkey: HotKey = .init(key: nil, modifiers: [.option])
	var openOnLogin: Bool = false
	var showDockIcon: Bool = true
    var selectedModel: String = "parakeet-tdt-0.6b-v3-coreml"
	var useClipboardPaste: Bool = true
	var preventSystemSleep: Bool = true
	var pauseMediaOnRecord: Bool = true
	var minimumKeyTime: Double = 0.2
	var copyToClipboard: Bool = false
	var useDoubleTapOnly: Bool = false
	var outputLanguage: String? = nil
	var selectedMicrophoneID: String? = nil
	var saveTranscriptionHistory: Bool = true
	var maxHistoryEntries: Int? = nil
	var pasteLastTranscriptHotkey: HotKey? = HexSettings.defaultPasteLastTranscriptHotkey
	var hasCompletedModelBootstrap: Bool = false
	var hasCompletedStorageMigration: Bool = false

	// Define coding keys to match struct properties
		enum CodingKeys: String, CodingKey {
		case soundEffectsEnabled
		case hotkey
		case openOnLogin
		case showDockIcon
		case selectedModel
		case useClipboardPaste
		case preventSystemSleep
		case pauseMediaOnRecord
		case minimumKeyTime
		case copyToClipboard
		case useDoubleTapOnly
		case outputLanguage
		case selectedMicrophoneID
		case saveTranscriptionHistory
		case maxHistoryEntries
		case pasteLastTranscriptHotkey
		case hasCompletedModelBootstrap
		case hasCompletedStorageMigration
	}

	init(
		soundEffectsEnabled: Bool = true,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
        selectedModel: String = "parakeet-tdt-0.6b-v3-coreml",
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		pauseMediaOnRecord: Bool = true,
		minimumKeyTime: Double = 0.2,
		copyToClipboard: Bool = false,
		useDoubleTapOnly: Bool = false,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
		saveTranscriptionHistory: Bool = true,
		maxHistoryEntries: Int? = nil,
		pasteLastTranscriptHotkey: HotKey? = HexSettings.defaultPasteLastTranscriptHotkey,
		hasCompletedModelBootstrap: Bool = false,
		hasCompletedStorageMigration: Bool = false
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.pauseMediaOnRecord = pauseMediaOnRecord
		self.minimumKeyTime = minimumKeyTime
		self.copyToClipboard = copyToClipboard
		self.useDoubleTapOnly = useDoubleTapOnly
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
		self.saveTranscriptionHistory = saveTranscriptionHistory
		self.maxHistoryEntries = maxHistoryEntries
		self.pasteLastTranscriptHotkey = pasteLastTranscriptHotkey
		self.hasCompletedModelBootstrap = hasCompletedModelBootstrap
		self.hasCompletedStorageMigration = hasCompletedStorageMigration
	}

	// Custom decoder that handles missing fields
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		// Decode each property, using decodeIfPresent with default fallbacks
		soundEffectsEnabled =
			try container.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? true
		hotkey =
			try container.decodeIfPresent(HotKey.self, forKey: .hotkey)
				?? .init(key: nil, modifiers: [.option])
		openOnLogin = try container.decodeIfPresent(Bool.self, forKey: .openOnLogin) ?? false
		showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        selectedModel =
            try container.decodeIfPresent(String.self, forKey: .selectedModel)
                ?? "parakeet-tdt-0.6b-v3-coreml"
		useClipboardPaste = try container.decodeIfPresent(Bool.self, forKey: .useClipboardPaste) ?? true
		preventSystemSleep =
			try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? true
		pauseMediaOnRecord =
			try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) ?? true
		minimumKeyTime =
			try container.decodeIfPresent(Double.self, forKey: .minimumKeyTime) ?? 0.2
		copyToClipboard =
			try container.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? false
		useDoubleTapOnly =
			try container.decodeIfPresent(Bool.self, forKey: .useDoubleTapOnly) ?? false
		outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
		selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
		saveTranscriptionHistory =
			try container.decodeIfPresent(Bool.self, forKey: .saveTranscriptionHistory) ?? true
		maxHistoryEntries = try container.decodeIfPresent(Int.self, forKey: .maxHistoryEntries)
		pasteLastTranscriptHotkey = try container.decodeIfPresent(HotKey.self, forKey: .pasteLastTranscriptHotkey) ?? HexSettings.defaultPasteLastTranscriptHotkey
		hasCompletedModelBootstrap =
			try container.decodeIfPresent(Bool.self, forKey: .hasCompletedModelBootstrap) ?? false
		hasCompletedStorageMigration =
			try container.decodeIfPresent(Bool.self, forKey: .hasCompletedStorageMigration) ?? false
	}
}

extension SharedReaderKey
	where Self == FileStorageKey<HexSettings>.Default
{
	static var hexSettings: Self {
		Self[
			.fileStorage(.hexSettingsURL),
			default: .init()
		]
	}
}

// MARK: - Storage Migration

extension URL {
	static var hexSettingsURL: URL {
		get {
			let newURL = (try? URL.hexApplicationSupport.appending(component: "hex_settings.json")) ?? URL.documentsDirectory.appending(component: "hex_settings.json")
			let legacyURL = URL.legacyDocumentsDirectory.appending(component: "hex_settings.json")
			
			// Migrate if needed
			if FileManager.default.fileExists(atPath: legacyURL.path),
			   !FileManager.default.fileExists(atPath: newURL.path) {
				try? FileManager.default.copyItem(at: legacyURL, to: newURL)
			}
			
			return newURL
		}
	}
}
