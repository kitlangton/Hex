# Hex CLI Implementation Plan

## Goal

Ship a standalone `hex-cli` executable that records from the default microphone, transcribes locally with Parakeet or WhisperKit, and prints the result to stdout or writes it to a file

## Status

Implemented

This document now describes the final architecture that shipped, not the earlier proposal that assumed a separate Xcode command-line target

## Final Outcome

- `hex-cli` is a SwiftPM executable product in `HexCore/Package.swift`
- shared model download, load, and transcription logic lives in `HexCore` as `HexTranscriptionEngine`
- the GUI app keeps its `TranscriptionClient` API, but now delegates to the shared engine
- the CLI uses a thin `AVAudioRecorder` wrapper and does not depend on TCA, SwiftUI, or AppKit
- the CLI can be run from source with `swift run --package-path HexCore hex-cli`
- the CLI can be installed locally onto `PATH` with `./HexCore/install-hex-cli.sh`
- the installer writes a versioned binary that matches the current Hex app version and refreshes the `hex-cli` symlink
- the CLI loads Parakeet with CPU-only CoreML compute units to avoid ANE runtime warnings leaking into stderr

## Architecture Decisions

### Use a SwiftPM executable target

We shipped `hex-cli` as an executable target in `HexCore/Package.swift` instead of adding a new Xcode target to `Hex.xcodeproj`

Why this won:

- keeps the CLI close to the reusable core code
- avoids extra Xcode project maintenance
- makes local installation and release builds straightforward with `swift build`
- still shares the same WhisperKit and FluidAudio dependency graph through the package

### Move transcription behavior into `HexCore`

The original proposal reused `TranscriptionClientLive` directly from the app target. The final implementation extracted the behavior into `HexTranscriptionEngine` inside `HexCore`

That change gave both the GUI app and CLI one shared implementation for:

- model discovery
- model download
- model loading
- WhisperKit vs Parakeet routing
- transcription execution
- shared cache and storage behavior

This is the key architectural difference from the original draft

### Keep recording CLI-specific

`RecordingClientLive` remains app-oriented and pulls in GUI-specific behavior. The CLI instead uses a focused `AVAudioRecorder` wrapper with the same PCM settings that Hex already expects:

- 16 kHz sample rate
- mono channel
- 32-bit float PCM
- WAV output in a temporary file

### Share model cache locations with the app

WhisperKit models still live under `URL.hexModelsDirectory`

Parakeet still relies on `XDG_CACHE_HOME`, so the CLI sets that before loading models so it can reuse the same cache root as the app

### Keep the interaction simple for v1

The CLI interaction model is still the one proposed originally:

- optional `--model` to choose a model explicitly
- optional `--output` to write the transcript to disk
- otherwise auto-detect a downloaded model or prompt the user to pick one
- press Enter or `Ctrl+C` to stop recording

## Final File Layout

```text
HexCore/
  Package.swift
  Sources/
    HexCLI/
      HexCLI.swift
      CLIRecorder.swift
      CLIStopMonitor.swift
      CLITranscriber.swift
    HexCore/
      Transcription/
        HexTranscriptionEngine.swift

Hex/
  Clients/
    TranscriptionClient.swift

HexCore/
  install-hex-cli.sh
```

## Runtime Behavior

### Permissions and sandboxing

The CLI is not sandboxed and does not need app entitlements

Microphone access is requested through the terminal app's normal TCC flow, so Terminal, Ghostty, or iTerm needs microphone permission the first time you record

### Model storage

- WhisperKit models are stored under the Hex application support models directory
- Parakeet models are stored under the shared cache root controlled by `XDG_CACHE_HOME`
- both the GUI app and CLI reuse these locations

### Recording flow

1. configure cache paths
2. resolve the model from flags, existing downloads, or the interactive picker
3. request microphone permission
4. load or download the model
5. record until Enter or `Ctrl+C`
6. transcribe locally
7. print to stdout and optionally write to a file

## Local Usage

Run directly from source:

```bash
swift run --package-path HexCore hex-cli
```

Examples:

```bash
swift run --package-path HexCore hex-cli --help
swift run --package-path HexCore hex-cli --model parakeet-tdt-0.6b-v3-coreml
swift run --package-path HexCore hex-cli --model openai_whisper-tiny --output transcript.txt
```

## Local Installation

Install a release build into `~/.local/bin` by default:

```bash
./HexCore/install-hex-cli.sh
```

Install into a different directory:

```bash
INSTALL_DIR="$HOME/bin" ./HexCore/install-hex-cli.sh
```

After installation:

```bash
hex-cli --help
```

The installer creates `hex-cli-<current-version>` and updates `hex-cli` to point at it so the installed artifact matches the current Hex version

## Validation

Current verification for this implementation:

- `swift run --package-path HexCore hex-cli --help`
- `swift test` from `HexCore`
- app build verified separately during implementation work

## Differences From The Original Draft

The earlier draft is no longer accurate in these areas:

- it proposed a dedicated Xcode CLI target
- it proposed using `TranscriptionClientLive` directly from the app target
- it described a `Hex/CLI` source layout instead of `HexCore/Sources/HexCLI`
- it assumed some shared files would need dual target membership in the app project

Those steps are no longer needed because the CLI now ships from the package and the shared engine lives in `HexCore`

## Remaining Follow-ups

These are nice-to-have improvements, not blockers for the current CLI:

- explicit microphone selection via `--device`
- richer argument parsing if the command surface grows
- broader distribution beyond local source builds and local install
