# [P0-2] Decouple settings/input models from Sauce + Cocoa

- **Phase:** 0 — Multiplatform HexCore
- **Depends on:** P0-1
- **Blocks:** P1-1
- **Size:** M
- **Risk:** Medium — this is the linchpin; `HexSettings` transitively pulls in `HotKey`.

## Goal
`HexSettings` and all shared code compile on iOS without `Sauce`/`Cocoa`. The hotkey
data model stays portable; only the macOS platform bridges are gated out.

## Tasks
- [ ] `Models/HotKey.swift`: keep the plain data model cross-platform (key as `Int`,
      modifiers as portable `OptionSet`). Gate behind `#if os(macOS)`: `import Cocoa`,
      `import Sauce`, `Modifiers.from(cocoa:)`, `from(carbonFlags:)`, `DeviceModifierMask`,
      and Sauce `Key` display lookups.
- [ ] `Models/KeyEvent.swift`: gate `import Sauce` + Sauce-typed members; keep Codable shape.
- [ ] `Models/KeyboardCommand.swift`: same treatment.
- [ ] Confirm `Settings/HexSettings.swift` keeps its hotkey fields (inert on iOS).

## Acceptance criteria
- [ ] HexCore compiles for iOS destination through the models + settings layer.
- [ ] macOS app still builds; hotkey behavior unchanged.
- [ ] `swift test` green on macOS.

## Files
- `HexCore/Sources/HexCore/Models/{HotKey,KeyEvent,KeyboardCommand}.swift`
- `HexCore/Sources/HexCore/Settings/HexSettings.swift` (verify only)
