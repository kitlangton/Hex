# iOS Keyboard-First — Issue Backlog

Local issue tracker derived from
[ios-keyboard-v1-implementation.md](../ios-keyboard-v1-implementation.md) and
[ios-keyboard-v1-plan.md](../ios-keyboard-v1-plan.md).

> These are local markdown issues (not GitHub issues). Status legend:
> `TODO` · `IN-PROGRESS` · `BLOCKED` · `DONE`.

## Suggested order

Do **SPIKE-1** early (de-risks the whole architecture). Then Phase 0 → 1 (low-risk,
independently shippable). Phases 2 + 3 are tightly coupled. Phase 4 last.

| ID | Title | Phase | Depends on | Size | Status |
|----|-------|-------|-----------|------|--------|
| [SPIKE-1](SPIKE-1-background-audio-survival.md) | Background-audio session survival probe | risk spike | — | S | TODO |
| [P0-1](P0-1-package-multiplatform.md) | Make HexCore `Package.swift` multiplatform | 0 | — | S | TODO |
| [P0-2](P0-2-decouple-settings-input-types.md) | Decouple settings/input models from Sauce + Cocoa | 0 | P0-1 | M | TODO |
| [P0-3](P0-3-ios-permission-sleep-clients.md) | iOS `PermissionClient` + `SleepManagementClient` | 0 | P0-1 | M | TODO |
| [P0-4](P0-4-move-engine-into-hexcore.md) | Move transcription engine into HexCore | 0 | P0-1 | L | TODO |
| [P1-1](P1-1-ios-app-target.md) | Create `HexiOS` app target | 1 | P0-2, P0-3, P0-4 | S | TODO |
| [P1-2](P1-2-ios-recording-client.md) | iOS `RecordingClient` (AVAudioSession) | 1 | P1-1 | M | TODO |
| [P1-3](P1-3-ios-host-ui.md) | iOS host UI + reuse TCA features | 1 | P1-2 | L | TODO |
| [P2-1](P2-1-keyboard-target-app-group.md) | `HexKeyboard` extension + App Group | 2 | P1-1 | M | TODO |
| [P2-2](P2-2-keyboard-ui.md) | Mic-centric keyboard UI + insertion | 2 | P2-1 | M | TODO |
| [P2-3](P2-3-ipc-layer.md) | IPC layer (App Group + Darwin notifications) | 2 | P2-1 | M | TODO |
| [P2-4](P2-4-bounce-and-swipe-back.md) | Keyboard→app bounce + swipe-back screen | 2 | P2-3 | M | TODO |
| [P3-1](P3-1-session-controller.md) | Continuous session controller + timeout | 3 | SPIKE-1, P2-4 | L | TODO |
| [P3-2](P3-2-app-intent-shortcuts.md) | App Intent (Shortcuts / Action Button) | 3 | P3-1 | S | TODO |
| [P4-1](P4-1-settings-vocab-sync.md) | iCloud sync: settings + vocab | 4 | P1-3 | M | TODO |
| [P4-2](P4-2-history-sync-cloudkit.md) | iCloud sync: history (CloudKit) | 4 | P1-3 | L | TODO |
| [P4-3](P4-3-audio-sync-optin.md) | iCloud sync: opt-in audio assets | 4 | P4-2 | M | TODO |
| [X-1](X-1-onboarding-flow.md) | Onboarding flow | cross-cutting | P2-2 | M | TODO |
| [X-2](X-2-project-structure-ci.md) | Project structure + multiplatform CI | cross-cutting | P0-1 | S | TODO |

## Milestones

- **M0 — Engine portable:** P0-1..P0-4 (HexCore builds for iOS + macOS).
- **M1 — Standalone iOS app:** P1-1..P1-3 (record → transcribe → history on device).
- **M2 — Dictation works:** P2-1..P2-4 (speak into any app).
- **M3 — Wispr-style UX:** P3-1, P3-2, X-1 (sessions + Shortcuts + onboarding).
- **M4 — Cross-device:** P4-1..P4-3 (Mac ↔ iOS sync).
