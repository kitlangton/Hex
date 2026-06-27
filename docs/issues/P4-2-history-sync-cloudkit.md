# [P4-2] iCloud sync: history (CloudKit)

- **Phase:** 4 — iCloud sync
- **Depends on:** P1-3
- **Blocks:** P4-3
- **Size:** L
- **Risk:** Medium/High — schema + conflicts + migration.

## Goal
Transcription history (text/metadata) syncs across Mac and iOS.

## Tasks
- [ ] CloudKit private DB `Transcript` record type: text, timestamps, app context,
      duration, language.
- [ ] Sync engine on both iOS + macOS (push on create, pull on launch/foreground).
- [ ] Stable IDs + Codable on `Transcript`/`TranscriptionHistory` (audit existing models).
- [ ] Conflict policy: last-writer-wins keyed by transcript `id`; dedupe on id.

## Acceptance criteria
- [ ] Dictation on iOS appears in macOS history and vice versa.
- [ ] No duplicates after repeated sync cycles.

## Files
- `HexCore/Sources/HexCore/.../CloudSync/*`, `Models/TranscriptionHistory.swift`
