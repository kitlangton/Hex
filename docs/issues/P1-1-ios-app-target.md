# [P1-1] Create `HexiOS` app target

- **Phase:** 1 — iOS host app
- **Depends on:** P0-2, P0-3, P0-4
- **Blocks:** P1-2, P2-1
- **Size:** S
- **Risk:** Low

## Goal
A buildable, empty-but-wired iOS app target that links the multiplatform HexCore.

## Tasks
- [ ] Add `HexiOS` app target (SwiftUI lifecycle), `IPHONEOS_DEPLOYMENT_TARGET = 17.0`,
      device family iPhone.
- [ ] Link HexCore, WhisperKit, FluidAudio.
- [ ] `Info.plist`: `NSMicrophoneUsageDescription`; `audio` background mode (used in P3);
      custom URL scheme `hexkb://` (used in P2-4).
- [ ] Basic app entry + placeholder root view.

## Acceptance criteria
- [ ] `HexiOS` builds and launches on simulator + device.

## Files
- `Hex.xcodeproj/project.pbxproj`, new `HexiOS/` sources + `Info.plist`
