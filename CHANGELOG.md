# Changelog

## 0.4.0

### Minor Changes

- e50478d: Add Parakeet TDT v3 plus the first-run model bootstrap, faster recording pipeline, and solid Fn/modifier hotkeys so the next release captures all of the recent feature work (#71, #97, #113, #89, #81, #87).

### Patch Changes

- ea42b5b: Move `HexSettings` + `RecordingAudioBehavior` into HexCore and add fixtures/tests so we can migrate historic settings blobs safely before shipping new media-ducking options.
- e50478d: Adopt Changesets for SemVer + changelog management, wire release.ts to fail without pending fragments, and sync the aggregated release notes into the bundled changelog + GitHub releases.
- 2fbbe7a: Wait for NSPasteboard changeCount to advance before pasting so panel apps always receive the latest transcript (#69, #42).

All notable changes to Hex are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Added NVIDIA Parakeet TDT v3 support with a redesigned model manager so you can swap between Parakeet and curated Whisper variants without juggling files (#71).
- Added first-run model bootstrap: Hex now automatically downloads the recommended model, shows progress/cancel controls, and prevents transcription from starting until a model is ready (#97).
- Added a global hotkey to paste the last transcript plus contextual actions to cancel or delete model downloads directly from Settings, making recovery workflows faster.

### Improved

- Model downloads now surface the failing host/domain in their error message so DNS or network issues are easier to debug (#112).
- Recording starts ~200–700 ms faster: start sounds play immediately, media pausing runs off the main actor, and transcription errors skip the extra cancel chime for less audio clutter (#113).
- The transcription overlay tracks the active window so UI hints stay anchored to whichever app currently has focus.
- HexSettings now lives inside HexCore with fixture-based migration tests, giving us a single source of truth for future settings changes.

### Fixed

- Printable-key hotkeys (for example `⌘+'`) can now trigger short recordings just like modifier-only chords, so quick phrases aren’t discarded anymore (#113).
- Fn and other modifier-only hotkeys respect left/right side selection, ignore phantom arrow events, and stop firing when combined with other keys, resolving long-standing regressions (#89, #81, #87).
- Paste reliability: Hex now waits for the clipboard write to commit before firing ⌘V, so panel apps like Alfred, Raycast, and IntelliBar always receive the latest transcript instead of the previous clipboard contents (#69, #42).

## 1.4

### Patch Changes

- Bump version for stable release

## 0.1.33

### Added

- Add copy to clipboard option
- Add support for complete keyboard shortcuts
- Add indication for model prewarming

### Fixed

- Fix issue with Hex showing in Mission Control and Cmd+Tab
- Improve paste behavior when text input fails
- Rework audio pausing logic to make it more reliable

## 0.1.26

### Added

- Add changelog
- Add option to set minimum record time
