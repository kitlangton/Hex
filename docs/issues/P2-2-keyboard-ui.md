# [P2-2] Mic-centric keyboard UI + insertion

- **Phase:** 2 — Keyboard + IPC
- **Depends on:** P2-1
- **Blocks:** X-1
- **Size:** M
- **Risk:** Low/Medium — keyboard memory budget is tight (no model here!).

## Goal
The keyboard's visible UI: a big mic button + status, and text insertion. No full QWERTY.

## Tasks
- [ ] `KeyboardViewController` hosting SwiftUI: large mic button, live waveform/status,
      controls (insert, delete-last-utterance, return-to-app hint, open settings, globe).
- [ ] Insert via `textDocumentProxy.insertText`; delete-last via `deleteBackward`.
- [ ] Keep memory minimal — the extension never loads an ML model (host app does inference).

## Acceptance criteria
- [ ] Keyboard renders and can insert/delete static text in a real text field.
- [ ] Stays well under the keyboard-extension memory budget.

## Files
- `HexKeyboard/KeyboardViewController.swift` + SwiftUI views
