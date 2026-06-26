# [P0-4] Move transcription engine into HexCore

- **Phase:** 0 — Multiplatform HexCore
- **Depends on:** P0-1
- **Blocks:** P1-1
- **Size:** L
- **Risk:** Medium — touches build wiring for the macOS app too.

## Goal
The on-device engine lives in HexCore so iOS and macOS share one implementation instead
of duplicating app code.

## Tasks
- [ ] Add to HexCore deps: WhisperKit (`XCRemote`), FluidAudio
      (`condition: .when(platforms: [.iOS, .macOS])`, guarded by `#if canImport(FluidAudio)`).
- [ ] Move into `HexCore/Sources/HexCore/Transcription/`: `TranscriptionClient.swift`,
      `ParakeetClient.swift`, `ParakeetClipPreparer.swift`, `LiveTranscriptionClient.swift`.
      Audit/gate any AppKit/`NSWorkspace`/AppleScript usage.
- [ ] Move `SoundEffect.swift` and `KeychainClient.swift` into HexCore.
- [ ] Verify `StoragePaths.swift` resolves correctly on iOS (App Group path comes in P2-1).
- [ ] Update the macOS app to consume these via HexCore; remove the now-duplicated
      package links from the macOS app target to avoid double-linking.

## Acceptance criteria
- [ ] HexCore builds for iOS + macOS.
- [ ] macOS app builds and transcribes exactly as before (no behavior change).
- [ ] `swift test` green.

## Files
- `HexCore/Package.swift`, `HexCore/Sources/HexCore/Transcription/*`
- `Hex/Clients/*` (moved out), `Hex.xcodeproj/project.pbxproj` (package wiring)
