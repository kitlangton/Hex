import ComposableArchitecture
import Dependencies
import Foundation

// To add a new setting, add a new property to the struct, the CodingKeys enum, and the custom decoder
struct HexSettings: Codable, Equatable {
	var soundEffectsEnabled: Bool = true
	var hotkey: HotKey = .init(key: nil, modifiers: [.option])
	var openOnLogin: Bool = false
	var showDockIcon: Bool = true
	var selectedModel: String = "openai_whisper-large-v3-v20240930"
	var useClipboardPaste: Bool = true
	var preventSystemSleep: Bool = true
	var pauseMediaOnRecord: Bool = true
	var minimumKeyTime: Double = 0.2
	var copyToClipboard: Bool = true
	var useDoubleTapOnly: Bool = false
	var outputLanguage: String? = nil
	var selectedMicrophoneID: String? = nil
    var disableAutoCapitalization: Bool = false // New setting for disabling auto-capitalization
    // AI Enhancement options
    var useAIEnhancement: Bool = false
    var selectedAIModel: String = "gemma3"
    var aiEnhancementPrompt: String = EnhancementOptions.defaultPrompt
    var aiEnhancementTemperature: Double = 0.3

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
        case disableAutoCapitalization
        case useAIEnhancement
        case selectedAIModel
        case aiEnhancementPrompt
        case aiEnhancementTemperature
	}

	init(
		soundEffectsEnabled: Bool = true,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = "openai_whisper-large-v3-v20240930",
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		pauseMediaOnRecord: Bool = true,
		minimumKeyTime: Double = 0.2,
		copyToClipboard: Bool = true,
		useDoubleTapOnly: Bool = false,
		on outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
        disableAutoCapitalization: Bool = false,
        useAIEnhancement: Bool = false,
        selectedAIModel: String = "gemma3",
        aiEnhancementPrompt: String = EnhancementOptions.defaultPrompt,
        aiEnhancementTemperature: Double = 0.3
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
        self.disableAutoCapitalization = disableAutoCapitalization
        self.useAIEnhancement = useAIEnhancement
        self.selectedAIModel = selectedAIModel
        self.aiEnhancementPrompt = aiEnhancementPrompt
        self.aiEnhancementTemperature = aiEnhancementTemperature
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
			?? "openai_whisper-large-v3-v20240930"
		useClipboardPaste = try container.decodeIfPresent(Bool.self, forKey: .useClipboardPaste) ?? true
		preventSystemSleep =
			try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? true
		pauseMediaOnRecord =
			try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) ?? true
		minimumKeyTime =
			try container.decodeIfPresent(Double.self, forKey: .minimumKeyTime) ?? 0.2
		copyToClipboard =
			try container.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? true
		useDoubleTapOnly =
			try container.decodeIfPresent(Bool.self, forKey: .useDoubleTapOnly) ?? false
		outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
        selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
        disableAutoCapitalization = try container.decodeIfPresent(Bool.self, forKey: .disableAutoCapitalization) ?? false
        // AI Enhancement settings
        useAIEnhancement = try container.decodeIfPresent(Bool.self, forKey: .useAIEnhancement) ?? false
        selectedAIModel = try container.decodeIfPresent(String.self, forKey: .selectedAIModel) ?? "gemma3"
        aiEnhancementPrompt = try container.decodeIfPresent(String.self, forKey: .aiEnhancementPrompt) ?? EnhancementOptions.defaultPrompt
        aiEnhancementTemperature = try container.decodeIfPresent(Double.self, forKey: .aiEnhancementTemperature) ?? 0.3
	}
}

// Cache for HexSettings to reduce disk I/O
private var cachedSettings: HexSettings? = nil
private var lastSettingsLoadTime: Date = .distantPast

// Helper function to get cached settings or load from disk
func getCachedSettings() -> HexSettings {
    // Use cached settings if they exist and are recent (within last 5 seconds)
    if let cached = cachedSettings, 
       Date().timeIntervalSince(lastSettingsLoadTime) < 5.0 {
        return cached
    }
    
    // Otherwise read from disk
    do {
        let url = URL.documentsDirectory.appending(component: "hex_settings.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let settings = try JSONDecoder().decode(HexSettings.self, from: data)
            
            // Update cache
            cachedSettings = settings
            lastSettingsLoadTime = Date()
            
            return settings
        }
    } catch {
        print("Error loading settings: \(error)")
    }
    
    // On error or if file doesn't exist, return default settings
    let defaultSettings = HexSettings()
    cachedSettings = defaultSettings
    lastSettingsLoadTime = Date()
    return defaultSettings
}

extension SharedReaderKey
	where Self == FileStorageKey<HexSettings>.Default
{
	static var hexSettings: Self {
		Self[
			.fileStorage(URL.documentsDirectory.appending(component: "hex_settings.json")),
			default: getCachedSettings()
		]
	}
}
