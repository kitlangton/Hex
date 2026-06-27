# [P0-3] iOS `PermissionClient` + `SleepManagementClient` live impls

- **Phase:** 0 — Multiplatform HexCore
- **Depends on:** P0-1
- **Blocks:** P1-1
- **Size:** M
- **Risk:** Low/Medium

## Goal
Both clients have iOS `+Live` implementations behind the same interface; macOS bodies
are gated and unchanged.

## Tasks
- [ ] `PermissionClient+Live.swift`: wrap macOS body in `#if os(macOS)`.
- [ ] New `PermissionClient+Live+iOS.swift` (`#if os(iOS)`): microphone only via
      `AVAudioApplication.requestRecordPermission` / `AVAudioSession`; "open Settings"
      via `UIApplication.openSettingsURLString`. Accessibility / input-monitoring →
      `.notApplicable`.
- [ ] `SleepManagementClient+Live.swift`: gate macOS (`IOPMAssertion*`) in `#if os(macOS)`;
      iOS impl uses `UIApplication.shared.isIdleTimerDisabled`.
- [ ] Keep both interfaces fully cross-platform.

## Acceptance criteria
- [ ] HexCore compiles for iOS through the client layer.
- [ ] macOS permission + sleep behavior unchanged.

## Files
- `HexCore/Sources/HexCore/PermissionClient/*`
- `HexCore/Sources/HexCore/SleepManagementClient/*`
