# [P2-3] IPC layer (App Group + Darwin notifications)

- **Phase:** 2 — Keyboard + IPC
- **Depends on:** P2-1
- **Blocks:** P2-4, P3-1
- **Size:** M
- **Risk:** Medium

## Goal
A reusable cross-process channel between the keyboard and the host app.

## Tasks
- [ ] New `HexCore/Sources/HexCore/IPC/`.
- [ ] App Group file(s) for: latest transcription result, session state flags.
- [ ] Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) for signals:
      keyboard→app "capture start/stop", app→keyboard "result ready".
- [ ] Keyboard observes the result file and inserts when "result ready" fires.
- [ ] Pure-logic unit tests for the round-trip (encode → write → read → decode).

## Acceptance criteria
- [ ] A value written by one process is observed by the other via Darwin notification.
- [ ] Round-trip unit tests pass.

## Files
- `HexCore/Sources/HexCore/IPC/*`
