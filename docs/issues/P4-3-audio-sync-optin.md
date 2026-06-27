# [P4-3] iCloud sync: opt-in audio assets

- **Phase:** 4 — iCloud sync
- **Depends on:** P4-2
- **Blocks:** —
- **Size:** M
- **Risk:** Medium — cost/bandwidth/storage limits.

## Goal
Optionally sync the audio recordings (off by default), Wi-Fi-only when enabled.

## Tasks
- [ ] Setting (default **off**): "Sync audio recordings (Wi-Fi only)".
- [ ] Sync recordings as CloudKit assets attached to the `Transcript` record.
- [ ] Throttle uploads; guard against cellular; respect iCloud storage limits.
- [ ] History row shows text-only + disabled playback when audio absent on a device.

## Acceptance criteria
- [ ] With opt-in on (Wi-Fi): audio plays back on the other device.
- [ ] With opt-in off: only text/metadata sync; no asset transfer.
- [ ] No asset upload on cellular.

## Files
- `HexCore/Sources/HexCore/.../CloudSync/*`, settings UI on both targets.
