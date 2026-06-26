# [X-2] Project structure + multiplatform CI

- **Phase:** cross-cutting
- **Depends on:** P0-1
- **Blocks:** —
- **Size:** S
- **Risk:** Low

## Goal
Keep one Xcode project building cleanly for all targets, with CI covering both platforms.

## Tasks
- [ ] One `Hex.xcodeproj` with targets: `Hex` (macOS), `HexiOS`, `HexKeyboard`, all sharing
      the multiplatform HexCore package.
- [ ] Shared schemes for CI.
- [ ] CI: build macOS app, build iOS app, run `HexCore` tests (both platforms).
- [ ] (Later, only if SwiftUI views diverge) consider a shared `HexUI` package — not needed for V1.

## Acceptance criteria
- [ ] CI green for macOS build + iOS build + HexCore tests.

## Files
- `.github/workflows/*`, `Hex.xcodeproj/*`
