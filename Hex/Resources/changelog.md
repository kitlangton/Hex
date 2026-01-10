# Changelog

## 0.6.6

### Patch Changes

- 3b6c966: Improve transcript modifications layout and remove log export settings
- 3b6c966: Add opt-in regex word removals for transcripts (#121)

## 0.6.5

### Patch Changes

- 140c205: Fix Sparkle auto-update for sandboxed app by adding required XPC entitlements and SUEnableInstallerLauncherService. Users on 0.6.3 will need to manually download this update.

## 0.6.4

### Patch Changes

- c00f79e: Reduce code duplication: add ModelPatternMatcher, FileManager helpers, settingsCaption style, notification constants, and Core Audio helper
- 658a755: Fix silent recordings caused by device-level microphone mute - automatically detects and fixes muted input devices before recording

## 0.6.3

### Patch Changes

- b4c54ce: Fix microphone priming and media pause races
- 5217d3f: Add word remappings and remove LLM UI (#000)
- 4d38708: Add persistent MCP config editing for Claude Code modes
- bbd0b80: Show system default mic name in picker
- bbd0b80: Fix Parakeet polling cleanup and organize paste flow
- 3413d68: Rename Transformations tab to Modes
- 4d38708: Fix microphone freezing and speech cutoff when using custom microphone. Only switch input device when actually needed, re-prime recorder after device changes, and add cleanup on app termination.

## 0.6.2

### Patch Changes

- 7e325ad: Fix Sequoia hotkey deadlock by removing Input Monitoring guard that prevented CGEventTap creation. Tap creation triggers permission prompt naturally. Re-add 'force quit Hex now' voice escape hatch from v0.5.8 (#122 #124)
- 7e325ad: Add missing-model callout and focus settings when transcription starts without a model

## 0.6.0

### Patch Changes

- 3bf2fb0: Fix voice prefix matching with punctuation - now strips punctuation (.,;:!?) when matching prefixes

## 0.5.13

### Patch Changes

- 083513c: Add comprehensive documentation to HotKeyProcessor and extract magic numbers into named constants (HexCoreConstants)

## 0.5.12

### Patch Changes

- 471310c: Fix Input Monitoring permission enforcement for hotkey reliability

## 0.5.11

### Patch Changes

- 1deda2a: Route Advanced → Export Logs through the new swift-log diagnostics file so Sequoia permission bugs (#122 #124) can be diagnosed locally without relying on macOS unified logs.

## 0.5.10

### Patch Changes

- 3560bdb: Keep hotkeys alive on Sequoia and add voice force-quit plus Advanced log export (#122 #124)

## 0.5.9

### Patch Changes

- 6c2f1bd: Add comprehensive permissions logging for improved debugging and log export support

## 0.5.8

### Patch Changes

- 03b81c7: Let the hotkey tap start even when Input Monitoring is missing so Sequoia users get prompts again, while keeping the accessibility watchdog (#122 #124). Add a spoken “force quit Hex now” escape hatch in case permissions clobber input.

## 0.5.7

### Patch Changes

- 539b0a4: Pad sub-1.5s Parakeet recordings so FluidAudio accepts them

## 0.5.6

### Patch Changes

- a1eb1d0: Restore hotkeys when Input Monitoring permission is missing (#122, #124)
- 1ee452a: Add non-interactive changeset creation for AI agents
- 68475f5: Fix clipboard restore timing for slow apps – increased delay from 100ms to 500ms to prevent paste failures in apps that read clipboard asynchronously

## 0.5.5

### Patch Changes

- 0045f28: Fix recording chime latency by switching to AVAudioEngine with pre-loaded buffers
- 7f6c5db: Actually request macOS Input Monitoring permission when installing the key event tap so Sequoia users can record hotkeys again (#122, #124).

## 0.5.4

### Patch Changes

- Fix hotkey monitoring on macOS Sequoia 15.7.1 by properly handling Input Monitoring permissions (#122, #124)

## 0.5.3

### Patch Changes

- Fix Sparkle update delivery by regenerating appcast with correct bundle versions and updating release tooling to prevent duplicate CFBundleVersion issues

## 0.5.2

### Patch Changes

- Fix Sparkle update delivery by regenerating appcast with correct bundle versions and updating release tooling to prevent duplicate CFBundleVersion issues

## 0.5.1

### Patch Changes

- Fix Sparkle appcast generation by cleaning duplicate bundle versions and updating release pipeline to preserve last 3 DMGs for delta generation

## 0.5.0

### Minor Changes

- 049592c: Add support for multiple Parakeet model variants: choose between English-only (v2) or multilingual (v3) based on your transcription needs.

### Patch Changes

- aca9ad5: Fix microphone access retained when recording canceled with ESC (#117)
- 049592c: Polish paste-last-transcript hotkey UI with improved layout and clearer instructions.
- 049592c: Improve hotkey reliability with accessibility trust monitoring and automatic recovery from tap disabled events (#89, #81, #87).
- 049592c: Improve media pausing reliability by using MediaRemote API instead of simulated keyboard events.
- 049592c: Fix menu bar rendering issue where items appeared as single embedded view instead of separate clickable menu items.
- 1b9bd52: Optimize recorder startup by keeping AVAudioRecorder primed between sessions, eliminating ~500ms latency for successive recordings
- 55fb4f8: Add a sound effects volume slider beneath the toggle so users can fine-tune feedback relative to the existing 20% baseline, keeping 100% at the legacy loudness (#000).

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
