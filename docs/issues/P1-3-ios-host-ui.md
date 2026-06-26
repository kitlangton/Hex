# [P1-3] iOS host UI + reuse TCA features

- **Phase:** 1 — iOS host app
- **Depends on:** P1-2
- **Blocks:** P4-1, P4-2 (sync needs models/history in place)
- **Size:** L
- **Risk:** Medium

## Goal
A usable standalone iOS app: record → on-device transcribe → history, plus settings and
model download. Milestone **M1**.

## Tasks
- [ ] Reuse `TranscriptionFeature` with iOS clients injected; drop paste/hotkey branches.
- [ ] Reuse `HistoryFeature`, `SettingsFeature`, `ModelDownloadFeature`.
- [ ] iOS SwiftUI views: record screen, history list (+ playback), settings, model picker
      (mirror macOS model selection).
- [ ] Wire microphone permission prompt (from P0-3 iOS PermissionClient).

## Acceptance criteria
- [ ] On a real A14+ device: record → text appears and is saved to history.
- [ ] Both a Whisper size and Parakeet validated for memory/perf on the device floor.
- [ ] Model download works on iOS.

## Files
- `HexiOS/` views, feature wiring; reuses `Hex/Features/*` reducers where portable.
