import ComposableArchitecture
import Dependencies
import Foundation

// To add a new setting, add a new property to the struct, the CodingKeys enum, and the custom decoder
struct HexSettings: Codable, Equatable {
	// History storage mode
	enum HistoryStorageMode: String, Codable, Equatable, CaseIterable {
		case off
		case textOnly
		case textAndAudio
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

	// New setting replacing the old boolean flag
	var historyStorageMode: HistoryStorageMode = .textAndAudio

	var maxHistoryEntries: Int? = nil
	var didCompleteFirstRun: Bool = false

	// Backward-compatibility bridge for existing codepaths referencing the old boolean.
	// Not encoded; maps to the new enum internally.
	var saveTranscriptionHistory: Bool {
		get { historyStorageMode != .off }
		set { historyStorageMode = newValue ? .textAndAudio : .off }
	}

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
		case historyStorageMode
		case maxHistoryEntries
		case didCompleteFirstRun
		case saveTranscriptionHistory // legacy key for migration
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
		historyStorageMode: HistoryStorageMode = .textAndAudio,
		maxHistoryEntries: Int? = nil
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
		self.historyStorageMode = historyStorageMode
		self.maxHistoryEntries = maxHistoryEntries
	}

	// Custom decoder that handles missing fields and migrates legacy settings
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

		// Migration: prefer new enum, else map legacy boolean (defaulting to true)
		if let mode = try container.decodeIfPresent(HistoryStorageMode.self, forKey: .historyStorageMode) {
			historyStorageMode = mode
		} else {
			let legacy = try container.decodeIfPresent(Bool.self, forKey: .saveTranscriptionHistory) ?? true
			historyStorageMode = legacy ? .textAndAudio : .off
		}

		maxHistoryEntries = try container.decodeIfPresent(Int.self, forKey: .maxHistoryEntries)
		didCompleteFirstRun =
			try container.decodeIfPresent(Bool.self, forKey: .didCompleteFirstRun) ?? false
	}

	// Custom encoder that omits legacy key
	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(soundEffectsEnabled, forKey: .soundEffectsEnabled)
		try container.encode(hotkey, forKey: .hotkey)
		try container.encode(openOnLogin, forKey: .openOnLogin)
		try container.encode(showDockIcon, forKey: .showDockIcon)
		try container.encode(selectedModel, forKey: .selectedModel)
		try container.encode(useClipboardPaste, forKey: .useClipboardPaste)
		try container.encode(preventSystemSleep, forKey: .preventSystemSleep)
		try container.encode(pauseMediaOnRecord, forKey: .pauseMediaOnRecord)
		try container.encode(minimumKeyTime, forKey: .minimumKeyTime)
		try container.encode(copyToClipboard, forKey: .copyToClipboard)
		try container.encode(useDoubleTapOnly, forKey: .useDoubleTapOnly)
		try container.encodeIfPresent(outputLanguage, forKey: .outputLanguage)
		try container.encodeIfPresent(selectedMicrophoneID, forKey: .selectedMicrophoneID)
		try container.encode(historyStorageMode, forKey: .historyStorageMode)
		try container.encodeIfPresent(maxHistoryEntries, forKey: .maxHistoryEntries)
		try container.encode(didCompleteFirstRun, forKey: .didCompleteFirstRun)
		// Intentionally do not encode .saveTranscriptionHistory (legacy key)
	}
}

extension SharedReaderKey
	where Self == FileStorageKey<HexSettings>.Default
{
	static var hexSettings: Self {
		Self[
			.fileStorage(URL.documentsDirectory.appending(component: "hex_settings.json")),
			default: .init()
		]
	}
}
