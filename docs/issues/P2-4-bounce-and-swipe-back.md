# [P2-4] Keyboard→app bounce + swipe-back screen

- **Phase:** 2 — Keyboard + IPC
- **Depends on:** P2-3
- **Blocks:** P3-1
- **Size:** M
- **Risk:** Medium — uses the unsupported `openURL` responder-chain hack.

## Goal
The keyboard can launch the host app to (re)establish a session; the host app guides the
user back. Completes the dictation loop (Milestone **M2** with P2-2/P2-3).

## Tasks
- [ ] Keyboard "Start session" opens `hexkb://start-session` via the responder-chain
      `openURL` hack — isolate it behind a single function (one place to fix if iOS breaks it).
- [ ] Host app handles the URL, starts the session (full session logic in P3-1), shows a
      "Swipe back to your app" screen (Apple removed auto-return).
- [ ] Document the hack + its fragility inline.

## Acceptance criteria
- [ ] From a text field: switch to Hex keyboard → start session → swipe back → tap mic →
      speak → text inserts.
- [ ] A second dictation within the window inserts with **no re-bounce** (depends on P3-1).

## Files
- `HexKeyboard/*`, `HexiOS/*` (URL handling + swipe-back screen)
