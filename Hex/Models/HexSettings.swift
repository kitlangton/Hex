import ComposableArchitecture
import Dependencies
import Foundation

// To add a new setting, add a new property to the struct, the CodingKeys enum, and the custom decoder
struct TranscriptionSettings: Codable, Equatable, Identifiable {
	var soundEffectsEnabled: Bool = true
	var selectedModel: String = "openai_whisper-large-v3-v20240930"
	var useClipboardPaste: Bool = true
	var preventSystemSleep: Bool = true
	var pauseMediaOnRecord: Bool = true
	var outputLanguage: String? = nil
	var hotkey: HotKey = .init(key: nil, modifiers: [.option])

	// Define coding keys to match struct properties
	enum CodingKeys: String, CodingKey {
		case soundEffectsEnabled
		case selectedModel
		case useClipboardPaste
		case preventSystemSleep
		case pauseMediaOnRecord
		case outputLanguage
		case hotkey
	}

	var id: HotKey {
		return hotkey
	}

	init(
		soundEffectsEnabled: Bool = true,
		selectedModel: String = "openai_whisper-large-v3-v20240930",
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		pauseMediaOnRecord: Bool = true,
		outputLanguage: String? = nil,
		hotkey: HotKey = .init(key: nil, modifiers: [.option])
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.pauseMediaOnRecord = pauseMediaOnRecord
		self.outputLanguage = outputLanguage
		self.hotkey = hotkey
	}

	// Custom decoder that handles missing fields
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		hotkey =
			try container.decodeIfPresent(HotKey.self, forKey: .hotkey)
			?? .init(key: nil, modifiers: [.option])
		selectedModel =
			try container.decodeIfPresent(String.self, forKey: .selectedModel)
			?? "openai_whisper-large-v3-v20240930"
		useClipboardPaste =
			try container.decodeIfPresent(Bool.self, forKey: .useClipboardPaste) ?? true
		preventSystemSleep =
			try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? true
		pauseMediaOnRecord =
			try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) ?? true
		outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
		hotkey =
			try container.decodeIfPresent(HotKey.self, forKey: .hotkey)
			?? .init(key: nil, modifiers: [.option])
	}
}

// To add a new setting, add a new property to the struct, the CodingKeys enum, and the custom decoder
struct HexSettings: Codable, Equatable {
	var hotKeyOptions: IdentifiedArrayOf<TranscriptionSettings> = [.init()]
	var openOnLogin: Bool = false
	var showDockIcon: Bool = true

	// Define coding keys to match struct properties
	enum CodingKeys: String, CodingKey {
		case openOnLogin
		case showDockIcon
		case hotKeyOptions
	}

	init(
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		hotKeyOptions: IdentifiedArrayOf<TranscriptionSettings> = [.init()]
	) {
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.hotKeyOptions = hotKeyOptions
	}

	// Custom decoder that handles missing fields
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		// Decode each property, using decodeIfPresent with default fallbacks
		openOnLogin = try container.decodeIfPresent(Bool.self, forKey: .openOnLogin) ?? false
		showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
		/// TODO: Write code to upgrade settings from previous versions where transcriptionSettings was not present
		hotKeyOptions =
			try container.decodeIfPresent(
				IdentifiedArrayOf<TranscriptionSettings>.self, forKey: .hotKeyOptions)
			?? [.init()]
	}
}

extension SharedReaderKey
where Self == FileStorageKey<HexSettings>.Default {
	static var hexSettings: Self {
		Self[
			.fileStorage(URL.documentsDirectory.appending(component: "hex_settings.json")),
			default: .init()
		]
	}
}
