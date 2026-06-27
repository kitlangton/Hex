# [P2-2] Mic-centric keyboard UI + insertion

- **Phase:** 2 — Keyboard + IPC
- **Depends on:** P2-1
- **Blocks:** X-1
- **Size:** M
- **Risk:** Low/Medium — keyboard memory budget is tight (no model here!).

## Goal
The keyboard's visible UI: a big mic button + status, and text insertion. No full QWERTY.

> **UI design is LOCKED:** follow [ios-ui-design-v1.md](../ios-ui-design-v1.md) — monochrome
> with the single iOS-blue accent on the mic + "mic hot" session pill; three primary controls
> (undo-last / mic / backspace) + bottom row globe + settings. See §5 for the full state set.

## Tasks
- [ ] `KeyboardViewController` hosting SwiftUI: large accent mic button, live waveform,
      tinted **"mic hot · MM:SS left"** session pill, controls (undo-last, mic, backspace,
      globe/next-keyboard, open settings).
- [ ] Insert via `textDocumentProxy.insertText`; delete-last via `deleteBackward`.
- [ ] **Design + handle all keyboard states** (per design §5): no-Full-Access, idle/ready,
      recording, inserting, session-expired/needs-bounce, error.
- [ ] Keep memory minimal — the extension never loads an ML model (host app does inference).

## Acceptance criteria
- [ ] Keyboard renders and can insert/delete static text in a real text field.
- [ ] All six states (design §5) render clearly in light and dark mode.
- [ ] Stays well under the keyboard-extension memory budget.

## Files
- `HexKeyboard/KeyboardViewController.swift` + SwiftUI views
