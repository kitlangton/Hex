# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hex is a macOS menu bar application that provides AI-powered voice-to-text transcription using OpenAI's Whisper models. Users activate transcription via customizable hotkeys, and the transcribed text can be automatically pasted into the active application.

## Build & Development Commands

```bash
# Build the app
xcodebuild -scheme Hex -configuration Release

# Run tests
xcodebuild test -scheme Hex

# Open in Xcode (recommended for development)
open Hex.xcodeproj
```

## Architecture

The app uses **The Composable Architecture (TCA)** for state management. Key architectural components:

### Features (TCA Reducers)

- `AppFeature`: Root feature coordinating the app lifecycle
- `TranscriptionFeature`: Core recording and transcription logic
- `SettingsFeature`: User preferences and configuration
- `HistoryFeature`: Transcription history management

### Dependency Clients

- `TranscriptionClient`: WhisperKit integration for ML transcription
- `RecordingClient`: AVAudioRecorder wrapper for audio capture
- `PasteboardClient`: Clipboard operations
- `KeyEventMonitorClient`: Global hotkey monitoring via Sauce framework

### Key Dependencies

- **WhisperKit**: Core ML transcription (tracking main branch)
- **Sauce**: Keyboard event monitoring
- **Sparkle**: Auto-updates (feed: <https://hex-updates.s3.amazonaws.com/appcast.xml>)
- **Swift Composable Architecture**: State management
- **Inject** Hot Reloading for SwiftUI

## Important Implementation Details

1. **Hotkey Recording Modes**: The app supports both press-and-hold and double-tap recording modes, implemented in `HotKeyProcessor.swift`

2. **Model Management**: Whisper models are downloaded on-demand via `ModelDownloadFeature`. Available models are defined in `Resources/Data/models.json`

3. **Sound Effects**: Audio feedback is provided via `SoundEffect.swift` using files in `Resources/Audio/`

4. **Window Management**: Uses an `InvisibleWindow` for the transcription indicator overlay

5. **Permissions**: Requires audio input and automation entitlements (see `Hex.entitlements`)

## Testing

Tests use Swift Testing framework. The main test file is `HexTests/HexTests.swift`. Run tests via Xcode or the command line.
