# Bug: iOS app unresponsive on launch

## Symptom

The app freezes for several seconds after launch — buttons don't respond, tabs won't switch. It eventually recovers once background initialization completes.

## Root Cause

Multiple heavy `.task` blocks fire simultaneously when the first views appear, saturating the executor and starving the main thread:

### 1. RecordingView `.task` — Audio prewarming
- `soundEffects.preloadSounds()` — reads 4 audio files from bundle, creates AVAudioEngine, attaches AVAudioPlayerNode instances
- `recording.warmUpRecorder()` — configures AVAudioSession, calls `setActive(true)`, allocates AVAudioRecorder, calls `prepareToRecord()`

**File:** `HexiOS/Features/IOSTranscriptionFeature.swift` (lines 56-62)

### 2. IOSSettingsView `.task` — Model fetching
- `transcription.getRecommendedModels()` — network call to WhisperKit/Hugging Face
- `transcription.getAvailableModels()` — another network call
- `transcription.isModelDownloaded()` x N — file system checks per model

**File:** `HexiOS/Features/ModelDownloadFeature.swift` (lines 176-195)

### 3. `@Shared` file storage — synchronous file I/O during State init
- `hex_settings.json` and `transcription_history.json` are read from disk when State structs are initialized

## Possible Fixes

- Defer audio prewarming until the user actually navigates to the recording tab or taps record for the first time
- Defer model fetching until the settings tab is visible
- Show a lightweight loading state instead of rendering the full UI while initialization runs
- Move heavy I/O to explicit background tasks with `Task.detached(priority: .utility)`
