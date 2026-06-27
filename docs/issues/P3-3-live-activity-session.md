# [P3-3] Flow-Session Live Activity (Dynamic Island / Lock Screen)

- **Phase:** 3 — Session + Shortcuts
- **Depends on:** P3-1 (session controller)
- **Blocks:** —
- **Size:** M
- **Risk:** Medium — new widget-extension target + ActivityKit lifecycle + background updates.
- **Skills:** `activitykit`, `app-intents`, `swiftui-liquid-glass`

## Goal

While a Flow Session is hot, show a persistent **"🎙 mic hot · MM:SS left"** Live Activity on
the Lock Screen and in the Dynamic Island — visible *while the user dictates in other apps* —
with an **End** control. Turns the unavoidable orange recording indicator into a branded,
controllable, always-present affordance. (Decided for V1.)

## Requirements

- **New Widget Extension target** (ActivityKit Live Activity) — created in Xcode (user step,
  like the keyboard). Shares the App Group + a `HexCore` `ActivityAttributes` type.
- Follow the locked design: monochrome + single iOS-blue accent on the mic/“live” glyph.

## Tasks

- [ ] Define `FlowSessionAttributes` (+ `ContentState`: `expiresAt`, `isCapturing`) in HexCore
      so app, keyboard-side, and widget share it.
- [ ] Add the **Widget Extension** target; implement the Live Activity UI:
      Lock Screen view + Dynamic Island **compact / minimal / expanded** layouts.
- [ ] Session lifecycle: `Activity.request` on session start; `.update` on extend / capture
      start-stop / countdown; `.end` on session end or expiry.
- [ ] **Interactive End** button via an `AppIntent` (ends the session from the Live Activity).
- [ ] Availability-gate (Live Activities iOS 16.1+; Dynamic Island device-gated) with graceful
      absence on unsupported devices.

## Acceptance criteria

- [ ] Starting a session shows the Live Activity (Lock Screen + Dynamic Island) with a live
      countdown and capturing state.
- [ ] Tapping **End** ends the session and dismisses the Activity.
- [ ] Activity dismisses automatically on session timeout.
- [ ] Renders correctly in light + dark and across DI compact/minimal/expanded.

## Files

- `HexCore/Sources/HexCore/.../FlowSessionAttributes.swift` (shared attributes)
- New `HexWidgets/` (or similar) widget-extension target; session lifecycle calls in the
  HexIOS session controller (P3-1).
