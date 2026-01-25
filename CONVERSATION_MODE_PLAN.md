# Hex Conversation Mode Integration Plan

## Overview

This document outlines the design for adding a **Conversation Mode** to Hex that enables full-duplex speech interaction using PersonaPlex MLX. This mode will complement Hex's existing one-way voice-to-text transcription with bidirectional speech conversations.

### Goals

1. **Full-Duplex Speech**: Enable simultaneous listening and speaking via PersonaPlex
2. **Seamless Mode Switching**: Allow users to easily toggle between Transcription Mode and Conversation Mode
3. **Preserve Existing Features**: Maintain all current Hex functionality unchanged
4. **Clean Architecture**: Follow Hex's TCA patterns and dependency injection

### Target Hardware

- Mac Mini M2 Pro with 16GB RAM
- Uses 4-bit quantized models to fit in memory
- Cannot run both Whisper and PersonaPlex simultaneously

---

## System Architecture

### Current Hex Architecture (Transcription Mode)

```
User Speech → Hotkey → RecordingClient → Audio File → TranscriptionClient → Text → Paste
              ↓                                              ↓
         HotKeyProcessor                              WhisperKit/Parakeet
```

### Proposed Architecture (Conversation Mode)

```
                    ┌─────────────────────────────────────────┐
                    │           ConversationClient            │
                    │  ┌──────────────────────────────────┐   │
User Speech ───────►│  │     PersonaPlex MLX Server       │   │──────► Speaker
                    │  │  (lm_persona.py + rustymimi)     │   │
                    │  └──────────────────────────────────┘   │
                    │           ↕ Audio Tokens ↕              │
                    │  ┌──────────────────────────────────┐   │
                    │  │    StreamTokenizer (Mimi)        │   │
                    │  └──────────────────────────────────┘   │
                    └─────────────────────────────────────────┘
                                      ↓
                              Transcript (optional)
```

### Unified Mode Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                           AppFeature                                │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────────┐│
│  │TranscriptionF│   │ConversationF │   │     SettingsFeature      ││
│  │   (existing) │   │   (new)      │   │  (mode selection added)  ││
│  └──────┬───────┘   └──────┬───────┘   └──────────────────────────┘│
│         │                  │                                        │
│  ┌──────▼───────┐   ┌──────▼───────┐                               │
│  │Transcription │   │Conversation  │                               │
│  │Client        │   │Client        │                               │
│  │(WhisperKit)  │   │(PersonaPlex) │                               │
│  └──────────────┘   └──────────────┘                               │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │              Shared: RecordingClient (microphone)            │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

---

## New Components

### 1. ConversationClient

A new TCA dependency client that wraps PersonaPlex MLX functionality.

```swift
// Hex/Clients/ConversationClient.swift

@DependencyClient
struct ConversationClient {
    /// Start a conversation session with the given persona
    var startSession: (ConversationConfig) async throws -> Void

    /// Stop the current conversation session
    var stopSession: () async -> Void

    /// Check if a session is currently active
    var isSessionActive: () -> Bool

    /// Stream of transcript text (what PersonaPlex says)
    var transcriptStream: () -> AsyncStream<String>

    /// Stream of conversation state changes
    var stateStream: () -> AsyncStream<ConversationState>

    /// Load a persona configuration
    var loadPersona: (PersonaConfig) async throws -> Void

    /// Get available voice presets
    var getVoicePresets: () async -> [VoicePreset]

    /// Download/prepare the model
    var prepareModel: (@escaping (Progress) -> Void) async throws -> Void

    /// Check if model is ready
    var isModelReady: () async -> Bool

    /// Cleanup resources
    var cleanup: () async -> Void
}

struct ConversationConfig: Codable, Equatable {
    var persona: PersonaConfig
    var inputDeviceID: String?
    var outputDeviceID: String?
    var quantization: Int = 4  // 4-bit or 8-bit
}

struct PersonaConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var textPrompt: String?
    var voicePreset: String?  // e.g., "NATF0", "VARM2"
    var voiceEmbeddingPath: URL?
}

struct VoicePreset: Codable, Equatable, Identifiable {
    var id: String  // e.g., "NATF0"
    var name: String  // e.g., "Natural Female 0"
    var gender: Gender

    enum Gender: String, Codable {
        case female, male
    }
}

enum ConversationState: Equatable {
    case idle
    case loading(Progress)
    case ready
    case active(speaking: Bool, listening: Bool)
    case error(String)
}
```

### 2. ConversationFeature

A new TCA reducer for conversation mode, parallel to TranscriptionFeature.

```swift
// Hex/Features/Conversation/ConversationFeature.swift

@Reducer
struct ConversationFeature {
    @ObservableState
    struct State: Equatable {
        // Session state
        var sessionState: ConversationState = .idle
        var isActive: Bool = false

        // Current conversation
        var currentTranscript: String = ""
        var conversationHistory: [ConversationTurn] = []

        // Audio levels (from model, for visualization)
        var inputLevel: Float = 0
        var outputLevel: Float = 0

        // Shared state
        @Shared(.hexSettings) var hexSettings: HexSettings
        @Shared(.conversationPersonas) var personas: [PersonaConfig]
        @Shared(.selectedPersonaID) var selectedPersonaID: UUID?

        var selectedPersona: PersonaConfig? {
            personas.first { $0.id == selectedPersonaID }
        }
    }

    enum Action {
        // Lifecycle
        case onAppear
        case onDisappear

        // Session control
        case startConversation
        case stopConversation
        case toggleConversation  // For hotkey

        // Persona management
        case selectPersona(UUID)
        case createPersona(PersonaConfig)
        case deletePersona(UUID)
        case editPersona(PersonaConfig)

        // Model management
        case prepareModel
        case modelProgress(Progress)
        case modelReady
        case modelError(Error)

        // Conversation events
        case transcriptReceived(String)
        case stateChanged(ConversationState)
        case conversationError(Error)

        // Internal
        case _streamStarted
        case _streamEnded
    }

    @Dependency(\.conversation) var conversation
    @Dependency(\.soundEffects) var soundEffects

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .startConversation:
                guard let persona = state.selectedPersona else {
                    return .none
                }
                state.isActive = true
                return .run { send in
                    await send(.stateChanged(.loading(.init())))
                    let config = ConversationConfig(persona: persona)
                    try await conversation.startSession(config)
                    await send(.stateChanged(.active(speaking: false, listening: true)))

                    // Start transcript stream
                    for await text in conversation.transcriptStream() {
                        await send(.transcriptReceived(text))
                    }
                } catch: { error, send in
                    await send(.conversationError(error))
                }

            case .stopConversation:
                state.isActive = false
                state.sessionState = .idle
                return .run { _ in
                    await conversation.stopSession()
                }

            // ... other cases
            }
        }
    }
}

struct ConversationTurn: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var speaker: Speaker
    var text: String

    enum Speaker: String, Codable {
        case user
        case assistant
    }
}
```

### 3. ConversationClientLive Implementation

The live implementation bridges Swift and PersonaPlex Python via a subprocess.

```swift
// Hex/Clients/ConversationClient+Live.swift

actor ConversationClientLive {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var stateSubject = AsyncStream<ConversationState>.Continuation?
    private var transcriptSubject = AsyncStream<String>.Continuation?

    func startSession(_ config: ConversationConfig) async throws {
        // Launch PersonaPlex MLX as subprocess
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")

        var args = [
            "-m", "personaplex_mlx.local",
            "-q", String(config.quantization)
        ]

        if let textPrompt = config.persona.textPrompt {
            args += ["--persona", textPrompt]
        }

        if let voicePath = config.persona.voiceEmbeddingPath {
            args += ["--voice-file", voicePath.path]
        }

        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: "~/repos/personaplex-mlx")

        // Set up pipes for communication
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe

        try process.run()

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe

        // Start reading output
        Task {
            await readOutputStream()
        }
    }

    private func readOutputStream() async {
        guard let outputPipe else { return }
        let handle = outputPipe.fileHandleForReading

        for try await line in handle.bytes.lines {
            if line.hasPrefix("TOKEN: ") {
                let text = String(line.dropFirst(7))
                transcriptSubject?.yield(text)
            }
        }
    }

    func stopSession() async {
        process?.terminate()
        process = nil
        inputPipe = nil
        outputPipe = nil
    }
}
```

---

## Settings & UI Changes

### 4. HexSettings Extensions

```swift
// In HexCore/Settings/HexSettings.swift

extension HexSettings {
    // New properties for conversation mode
    var operationMode: OperationMode = .transcription
    var conversationHotkey: HotKey? = nil  // Separate hotkey for conversation
    var selectedPersonaID: UUID? = nil
    var savedPersonas: [PersonaConfig] = []
}

enum OperationMode: String, Codable, CaseIterable {
    case transcription = "Transcription"
    case conversation = "Conversation"

    var description: String {
        switch self {
        case .transcription:
            return "Voice to text (one-way)"
        case .conversation:
            return "Full-duplex speech AI"
        }
    }
}
```

### 5. Settings UI - Mode Selection

```swift
// Hex/Features/Settings/Views/ModeSettingsView.swift

struct ModeSettingsView: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Section("Operation Mode") {
            Picker("Mode", selection: $store.hexSettings.operationMode) {
                ForEach(OperationMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading) {
                        Text(mode.rawValue)
                        Text(mode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            if store.hexSettings.operationMode == .conversation {
                ConversationSettingsSection(store: store)
            }
        }
    }
}

struct ConversationSettingsSection: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Group {
            // Persona selection
            PersonaPickerView(
                personas: store.personas,
                selectedID: $store.hexSettings.selectedPersonaID
            )

            // Conversation hotkey
            HotKeyRecorderView(
                label: "Conversation Hotkey",
                hotkey: $store.hexSettings.conversationHotkey,
                description: "Press to start/stop conversation"
            )

            // Model status
            ConversationModelStatusView(store: store)
        }
    }
}
```

### 6. Persona Management UI

```swift
// Hex/Features/Settings/Views/PersonaEditorView.swift

struct PersonaEditorView: View {
    @Binding var persona: PersonaConfig
    @State private var voicePresets: [VoicePreset] = []

    var body: some View {
        Form {
            Section("Basic Info") {
                TextField("Name", text: $persona.name)
            }

            Section("Persona Prompt") {
                TextEditor(text: Binding(
                    get: { persona.textPrompt ?? "" },
                    set: { persona.textPrompt = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 100)

                Text("Describe how the AI should behave. Example: 'You are a helpful assistant who speaks concisely.'")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice") {
                Picker("Voice Preset", selection: $persona.voicePreset) {
                    Text("Default").tag(String?.none)
                    ForEach(voicePresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }

                // Or custom voice embedding file
                HStack {
                    Text("Custom Voice File:")
                    if let path = persona.voiceEmbeddingPath {
                        Text(path.lastPathComponent)
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose...") {
                        // File picker
                    }
                }
            }
        }
    }
}
```

### 7. Conversation Indicator View

```swift
// Hex/Views/ConversationIndicatorView.swift

struct ConversationIndicatorView: View {
    let state: ConversationState
    let inputLevel: Float
    let outputLevel: Float

    var body: some View {
        VStack(spacing: 12) {
            // Conversation active indicator
            HStack(spacing: 16) {
                // Listening indicator (microphone)
                AudioLevelIndicator(
                    level: inputLevel,
                    icon: "mic.fill",
                    color: .blue,
                    label: "Listening"
                )

                // Speaking indicator (speaker)
                AudioLevelIndicator(
                    level: outputLevel,
                    icon: "speaker.wave.2.fill",
                    color: .green,
                    label: "Speaking"
                )
            }

            // State text
            switch state {
            case .idle:
                Text("Press hotkey to start conversation")
            case .loading:
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading model...")
                }
            case .active(let speaking, let listening):
                HStack {
                    if listening { Image(systemName: "ear") }
                    if speaking { Image(systemName: "mouth.fill") }
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .ready:
                Text("Ready")
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct AudioLevelIndicator: View {
    let level: Float
    let icon: String
    let color: Color
    let label: String

    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: 44, height: 44)

                Circle()
                    .fill(color.opacity(Double(level)))
                    .frame(width: 44 * CGFloat(0.5 + level * 0.5),
                           height: 44 * CGFloat(0.5 + level * 0.5))
                    .animation(.easeOut(duration: 0.1), value: level)

                Image(systemName: icon)
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.caption2)
        }
    }
}
```

---

## Hotkey Integration

### 8. Extended HotKeyProcessor

The existing HotKeyProcessor supports the conversation mode hotkey.

```swift
// In HexCore/Logic/HotKeyProcessor.swift

extension HotKeyProcessor {
    enum HotKeyType {
        case transcription
        case conversation
        case pasteLastTranscript
    }

    /// Process a key event for conversation mode
    func processConversation(_ event: KeyEvent) -> ConversationAction? {
        guard let hotkey = conversationHotkey else { return nil }

        // Simple toggle for conversation (no hold mode)
        if event.matches(hotkey) {
            return isConversationActive ? .stop : .start
        }

        // Escape always cancels
        if event.key == .escape {
            return .stop
        }

        return nil
    }
}

enum ConversationAction {
    case start
    case stop
}
```

---

## Memory Management Strategy

Since we can't run both Whisper and PersonaPlex simultaneously on 16GB RAM:

### 9. Model Lifecycle Manager

```swift
// Hex/Clients/ModelLifecycleManager.swift

actor ModelLifecycleManager {
    enum LoadedModel {
        case none
        case transcription(String)  // model name
        case conversation
    }

    private var loadedModel: LoadedModel = .none

    @Dependency(\.transcription) var transcription
    @Dependency(\.conversation) var conversation

    /// Prepare for transcription mode (unload conversation if needed)
    func prepareForTranscription(model: String) async throws {
        switch loadedModel {
        case .conversation:
            // Unload PersonaPlex first
            await conversation.cleanup()
            loadedModel = .none

            // Brief delay for memory to be released
            try await Task.sleep(for: .milliseconds(500))

        case .transcription(let current) where current != model:
            // Different transcription model, unload
            // (TranscriptionClient handles this internally)
            break

        default:
            break
        }

        // Now safe to load transcription model
        loadedModel = .transcription(model)
    }

    /// Prepare for conversation mode (unload transcription if needed)
    func prepareForConversation() async throws {
        switch loadedModel {
        case .transcription:
            // TranscriptionClient should unload WhisperKit
            // This is implicit when we don't use it
            loadedModel = .none
            try await Task.sleep(for: .milliseconds(500))

        case .conversation:
            // Already loaded
            return

        default:
            break
        }

        // Prepare PersonaPlex model
        try await conversation.prepareModel { _ in }
        loadedModel = .conversation
    }
}
```

---

## Implementation Phases

### Phase 1: Foundation (Week 1)

**Goal**: Basic conversation client and model loading

1. **Create ConversationClient protocol and dependency**
   - Define the interface as shown above
   - Add to dependency container
   - Create test/preview implementations

2. **Implement ConversationClientLive**
   - Subprocess management for PersonaPlex
   - Basic start/stop functionality
   - Pipe-based communication

3. **Add PersonaConfig model**
   - Core data structures
   - Shared state keys
   - File-based persistence

### Phase 2: Feature Reducer (Week 2)

**Goal**: TCA integration with conversation state management

1. **Create ConversationFeature reducer**
   - Session lifecycle actions
   - State transitions
   - Error handling

2. **Integrate with AppFeature**
   - Scope ConversationFeature
   - Mode switching logic
   - Permission checks (microphone needed for both modes)

3. **Add conversation hotkey handling**
   - Extend HotKeyProcessor
   - Toggle behavior (vs. press-and-hold)

### Phase 3: UI Implementation (Week 3)

**Goal**: User-facing interface for conversation mode

1. **Mode selection in Settings**
   - Radio button picker
   - Mode-specific settings sections

2. **Persona management UI**
   - List view with add/edit/delete
   - Persona editor form
   - Voice preset picker

3. **Conversation indicator overlay**
   - Floating window (like transcription indicator)
   - Bidirectional audio level visualization
   - State feedback

### Phase 4: Integration & Polish (Week 4)

**Goal**: Seamless experience and edge cases

1. **Model lifecycle management**
   - Automatic unloading when switching modes
   - Memory pressure handling
   - Download progress UI

2. **Audio device handling**
   - Share microphone selection with transcription
   - Add output device selection for conversation
   - Handle device changes during conversation

3. **History integration**
   - Optionally save conversation transcripts
   - Distinguish from transcription history
   - Export options

---

## Testing Strategy

### Unit Tests

```swift
// Tests/ConversationFeatureTests.swift

@MainActor
func testStartConversation() async {
    let store = TestStore(
        initialState: ConversationFeature.State(),
        reducer: { ConversationFeature() },
        withDependencies: {
            $0.conversation = .mock
        }
    )

    store.state.personas = [.mock]
    store.state.selectedPersonaID = PersonaConfig.mock.id

    await store.send(.startConversation) {
        $0.isActive = true
    }

    await store.receive(.stateChanged(.loading(.init())))
    await store.receive(.stateChanged(.active(speaking: false, listening: true)))
}
```

### Integration Tests

1. Test mode switching doesn't leak memory
2. Test conversation survives app backgrounding
3. Test hotkey works in both modes
4. Test error recovery (model crash, audio device disconnect)

### Manual Testing Checklist

- [ ] Start conversation from idle
- [ ] Stop conversation via hotkey
- [ ] Stop conversation via ESC
- [ ] Switch from transcription to conversation mode
- [ ] Switch from conversation to transcription mode
- [ ] Create custom persona
- [ ] Edit existing persona
- [ ] Delete persona
- [ ] Select different voice preset
- [ ] Conversation indicator appears correctly
- [ ] Audio levels visualize correctly
- [ ] Model downloads with progress
- [ ] Error messages display clearly

---

## API Compatibility Notes

### PersonaPlex MLX Interface

The PersonaPlex MLX local.py provides:

```
Input:  --persona "text prompt"
        --voice-file "path/to/voice.safetensors"
        -q 4|8 (quantization)

Output: stdout lines:
        [info] message
        TOKEN: text
        LAG (output buffer underrun)
        === PersonaPlex MLX Ready ===
```

For tighter integration, consider adding a JSON-RPC or gRPC interface to PersonaPlex.

### Future Enhancements

1. **Native Swift MLX binding** - Eliminate Python subprocess
2. **Real-time transcript streaming** - Show what user said
3. **Conversation context** - Multi-turn memory
4. **Voice cloning** - Custom voice from audio sample
5. **Interrupt handling** - User can interrupt AI mid-speech

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Memory pressure on 16GB | High | Strict model unloading, 4-bit quantization only |
| Audio latency | Medium | Tune buffer sizes, async audio I/O |
| PersonaPlex port incomplete | High | Provide fallback stub, graceful degradation |
| Subprocess communication reliability | Medium | Health checks, auto-restart, timeout handling |
| User confusion about modes | Low | Clear UI labels, mode indicator in menu bar |

---

## Appendix: File Structure

```
Hex/
├── Clients/
│   ├── ConversationClient.swift           # New
│   ├── ConversationClient+Live.swift      # New
│   └── ModelLifecycleManager.swift        # New
├── Features/
│   ├── Conversation/                      # New directory
│   │   ├── ConversationFeature.swift
│   │   └── Views/
│   │       ├── ConversationIndicatorView.swift
│   │       └── PersonaEditorView.swift
│   └── Settings/
│       └── Views/
│           ├── ModeSettingsView.swift     # New
│           └── ConversationSettingsSection.swift  # New
└── Models/
    └── ConversationModels.swift           # New

HexCore/
├── Models/
│   ├── PersonaConfig.swift                # New
│   └── ConversationState.swift            # New
└── Settings/
    └── HexSettings.swift                  # Modified (add mode, persona settings)
```

---

## Summary

This plan adds a **Conversation Mode** to Hex that:

1. **Integrates PersonaPlex MLX** as a subprocess with pipe-based communication
2. **Follows Hex's TCA architecture** with a new ConversationFeature reducer
3. **Shares infrastructure** (microphone selection, permissions, hotkeys) with existing transcription
4. **Manages memory carefully** by ensuring only one large model is loaded at a time
5. **Provides clean UI** for mode selection, persona management, and conversation feedback

The phased implementation approach allows for incremental delivery while maintaining Hex's stability and code quality standards.
