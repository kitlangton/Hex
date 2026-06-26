# [P1-2] iOS `RecordingClient` (AVAudioSession)

- **Phase:** 1 — iOS host app
- **Depends on:** P1-1
- **Blocks:** P1-3
- **Size:** M
- **Risk:** Medium — audio format must match model expectations.

## Goal
An iOS implementation of the existing `RecordingClient` interface using AVAudioEngine /
AVAudioSession.

## Tasks
- [ ] `RecordingClient+Live+iOS.swift` (`#if os(iOS)`): capture 16 kHz mono via
      `AVAudioEngine`/`AVAudioSession`.
- [ ] Drop macOS-only bits (CoreAudio device enumeration, AppleScript media control).
- [ ] Reuse `SuperFastCaptureController` ring-buffer logic if portable; otherwise a
      simpler iOS capture path is acceptable for V1.
- [ ] Handle interruptions (calls, route changes) gracefully.

## Acceptance criteria
- [ ] Records a clean 16 kHz mono buffer/file that the engine transcribes correctly.
- [ ] Survives a basic interruption (e.g. route change) without crashing.

## Files
- `HexCore/Sources/HexCore/.../RecordingClient+Live+iOS.swift` (or app-side if interface stays in app)
