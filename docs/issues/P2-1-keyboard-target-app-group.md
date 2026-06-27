# [P2-1] `HexKeyboard` extension + App Group

- **Phase:** 2 — Keyboard + IPC
- **Depends on:** P1-1
- **Blocks:** P2-2, P2-3
- **Size:** M
- **Risk:** Medium — App Group storage path must be shared correctly.

## Goal
A keyboard extension target that shares storage with the host app via an App Group.

## Tasks
- [ ] Add `HexKeyboard` keyboard extension target.
- [ ] Create App Group (e.g. `group.co.stonefrontier.hex`) on both `HexiOS` + `HexKeyboard`.
- [ ] Move shared container / model storage under the App Group; update `StoragePaths`
      for iOS to resolve the App Group container.
- [ ] Enable Full Access (`RequestsOpenAccess = true`).

## Acceptance criteria
- [ ] Keyboard appears in iOS Settings and can be enabled with Full Access.
- [ ] Both processes read/write the same App Group container (verified with a test file).

## Files
- `Hex.xcodeproj/project.pbxproj`, new `HexKeyboard/`, entitlements for both targets,
  `HexCore/Sources/HexCore/StoragePaths.swift`
