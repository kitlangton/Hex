# Hex — Voice → Text

Use a hotkey to transcribe your voice and paste the result wherever you're typing.

**[Download Hex for macOS](https://hex-updates.s3.us-east-1.amazonaws.com/hex-latest.dmg)**
> **Note:** Hex is currently only available for **Apple Silicon** Macs.

I've opened-sourced the project in the hopes that others will find it useful! We rely on the awesome [WhisperKit](https://github.com/argmaxinc/WhisperKit) for transcription, and the incredible [Swift Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) for structuring the app. Please open issues with any questions or feedback! ❤️

Join our [Discord community](https://discord.gg/5UzVCqWmav) for support, discussions, and updates!

## Instructions

Once you open Hex, you'll need to grant it microphone and accessibility permissions—so it can record your voice and paste the transcribed text into any application, respectively.

Once you've configured a global hotkey, you can choose between **two recording modes** in settings:

1. **Hold-to-Record**: Press and hold the hotkey to begin recording. Say whatever you want, then release the hotkey to stop recording and start the transcription process.
2. **Tap-to-Toggle**: Tap the hotkey once to start recording. Say whatever you want, then tap the hotkey again to stop recording and start the transcription process.
 
> ⚠️ Note: The first time you run Hex, it will download and compile the Whisper model for your machine. During this process, you may notice high CPU usage from a background process called ANECompilerService. This is macOS optimizing the model for the Apple Neural Engine (ANE), and it's a normal one-time setup step.
>
> Depending on your CPU and the size of the model, this may take anywhere from a few seconds to a few minutes.
## Project Structure

Hex is organized into several directories, each serving a specific purpose:

- **`App/`**
	- Contains the main application entry point (`HexApp.swift`) and the app delegate (`HexAppDelegate.swift`), which manage the app's lifecycle and initial setup.
  
- **`Clients/`**
  - `PasteboardClient.swift`
    - Manages pasteboard operations for copying transcriptions.
  - `SoundEffect.swift`
    - Controls sound effects for user feedback.
  - `RecordingClient.swift`
    - Manages audio recording and microphone access.
  - `KeyEventMonitorClient.swift`
    - Monitors global key events for hotkey detection.
  - `TranscriptionClient.swift`
    - Interfaces with WhisperKit for transcription services.

- **`Features/`**
  - `AppFeature.swift`
    - The root feature that composes transcription, settings, and history.
  - `TranscriptionFeature.swift`
    - Manages the core transcription logic and recording flow.
  - `SettingsFeature.swift`
    - Handles app settings, including hotkey configuration and permissions.
  - `HistoryFeature.swift`
    - Manages the transcription history view.

- **`Models/`**
  - `HexSettings.swift`
    - Stores user preferences like hotkey settings and sound preferences.
  - `HotKey.swift`
    - Represents the hotkey configuration.

- **`Resources/`**
  - Contains the app's assets, including the app icon and sound effects.
  - `changelog.md`
    - A log of changes to the app.
  - `Data/languages.json`
    - A list of supported languages for transcription.
  - `Audio/`
    - Sound effects for user feedback.
