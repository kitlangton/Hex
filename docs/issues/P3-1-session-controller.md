# [P3-1] Continuous session controller + timeout

- **Phase:** 3 — Session + Shortcuts
- **Depends on:** SPIKE-1, P2-4
- **Blocks:** P3-2
- **Size:** L
- **Risk:** HIGH — gated by SPIKE-1's outcome.

## Goal
The continuous-mic "Flow Session" model: bounce once to start, then keyboard triggers
snippets with no re-bounce until timeout.

## Tasks
- [ ] New TCA feature in `HexiOS`: on `hexkb://start-session`, activate a **continuous**
      `AVAudioSession` in the foreground with background-audio so it survives the swipe-back.
- [ ] Keyboard mic taps (via Darwin notif from P2-3) mark snippet boundaries; the running
      host app transcribes each snippet → writes result to App Group → no re-bounce.
- [ ] Configurable timeout (5 / 15 / 60 / never), default **15 min**; tear down on expiry.
- [ ] Surface remaining time + an "end session" control.

## Acceptance criteria
- [ ] Multiple dictations within the window with no re-bounce.
- [ ] Session ends at the configured timeout; next use re-bounces.
- [ ] Orange indicator behavior + battery cost understood and acceptable.

## Files
- `HexiOS/` session feature; consumes `HexCore/IPC`.
