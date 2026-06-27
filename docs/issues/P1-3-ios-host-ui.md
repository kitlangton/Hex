# [P1-3] iOS host UI + reuse TCA features

- **Phase:** 1 — iOS host app
- **Depends on:** P1-2
- **Blocks:** P4-1, P4-2 (sync needs models/history in place)
- **Size:** L
- **Risk:** Medium

## Goal
A usable standalone iOS app: record → on-device transcribe → history, plus settings and
model download. Milestone **M1**.

> **UI design is LOCKED:** follow [ios-ui-design-v1.md](../ios-ui-design-v1.md)
> (monochrome + single iOS-blue accent; iOS 26 cues; floating tab bar). Screens here:
> Home, Recording, History, Settings, model picker.

## Tasks
- [ ] Reuse `TranscriptionFeature` with iOS clients injected; drop paste/hotkey branches.
- [ ] Reuse `HistoryFeature`, `SettingsFeature`, `ModelDownloadFeature`.
- [ ] **Tab bar root** (floating, iOS 26 style): Home / History / Settings.
- [ ] **Home** = engine-room status + in-app **notes**: keyboard-ready status pill,
      "New note" mic card (records & saves **in-app**, never switches apps), Recent preview.
- [ ] **Recording** screen (modal over Home): timer + waveform + stop; transient
      "Transcribing…". **No live preview in V1.**
- [ ] **History**: unified list (notes + keyboard insertions), day-grouped, each row tagged
      with **source** icon (`text · time · source · duration`) + inline playback when audio.
- [ ] **Settings**: grouped inset lists mirroring the macOS model picker + Session length /
      Language / Vocabulary / iCloud sync / Sync audio / Clean-up filler (off; formatter-seam
      placeholder, #199) / Keyboard Full-Access status.
- [ ] Single swappable accent token (asset-catalog `AccentColor`); no scattered hardcoded colors.
- [ ] Wire microphone permission prompt (from P0-3 iOS PermissionClient).

## Acceptance criteria
- [ ] On a real A14+ device: record → text appears and is saved to history.
- [ ] Both a Whisper size and Parakeet validated for memory/perf on the device floor.
- [ ] Model download works on iOS.
- [ ] Matches [ios-ui-design-v1.md](../ios-ui-design-v1.md); verified in **light and dark** mode.

## Files
- `HexiOS/` views, feature wiring; reuses `Hex/Features/*` reducers where portable.
