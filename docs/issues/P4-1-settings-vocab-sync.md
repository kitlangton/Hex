# [P4-1] iCloud sync: settings + vocab

- **Phase:** 4 — iCloud sync
- **Depends on:** P1-3
- **Blocks:** —
- **Size:** M
- **Risk:** Low/Medium

## Goal
Lightweight config syncs across Mac and iOS.

## Tasks
- [ ] Sync relevant `HexSettings` subset + `wordRemappings`/`wordRemovals` via
      `NSUbiquitousKeyValueStore`.
- [ ] Decide which settings are device-local (e.g. selected microphone) vs synced.
- [ ] Merge strategy: KVS last-writer-wins is acceptable for config.

## Acceptance criteria
- [ ] Changing a synced setting / vocab on one device reflects on the other.
- [ ] Device-local settings do not sync.

## Files
- `HexCore/Sources/HexCore/Settings/*` (sync hook), both app targets.
