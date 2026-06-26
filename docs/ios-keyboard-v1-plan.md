# Hex for iOS — Keyboard-First Dictation (V1 Feature Plan)

> Status: **feature planning / pre-implementation**. This captures product decisions
> reached during design grilling. Implementation plan (file-by-file) comes after this
> is agreed.

## 1. Product thesis

Hex on iOS is a **keyboard-first voice dictation** product — a Wispr Flow–style
competitor that lets you speak into any app's text field. The dictation keyboard
**is** the product; the host app is the engine room (recording, model management,
session control, settings, history).

Hex stays true to its macOS identity: **100% on-device transcription, private, no
backend.**

## 2. The hard iOS constraint that shapes everything

iOS **custom keyboards cannot access the microphone** — ever, even with Full Access.
So the keyboard cannot record. Recording must happen in the **host app**, and iOS
only lets an audio session *continue* in the background if it was *started* in the
foreground (the app is suspended once mic recording stops).

This forces a **session-based** architecture (the same one Wispr uses):

```
Session start:  keyboard "Start" ─(openURL responder-chain hack)─▶ host app foregrounds
                ─▶ starts a continuous AVAudioSession (background-audio mode, mic stays hot)
                ─▶ user MANUALLY swipes back to their app   (Apple removed auto-return)
During session: keyboard mic tap ─(Darwin notification + App Group)─▶ host app (alive, mic hot)
                captures snippet ─▶ transcribes on-device ─▶ writes text to App Group
                ─▶ keyboard inserts via textDocumentProxy        [NO re-bounce]
Session end:    timeout (configurable, default 15 min) or app killed ─▶ next use re-bounces
```

Inherent, unavoidable costs (the market leader pays them too):
- One **manual swipe-back** per session start.
- The **orange recording indicator** stays lit for the whole session (mic is hot).
- Launching the host app from the keyboard uses an **unsupported responder-chain
  `openURL` hack** — fine for open-source/sideload; an App Store review risk to revisit
  later.

## 3. Distribution

Open-source project. **App Store is not a V1 requirement.** This lets us use the
gray-area techniques above (background audio + `openURL` hack). Revisit App Store
compliance only if/when we choose to submit.

## 4. V1 decisions (locked)

| Area | Decision |
|---|---|
| Center of gravity | **Keyboard-first.** Host app is the engine room. |
| Recording model | **Session-based**, continuous hot mic during a session. |
| Session length | **Default 15 min, user-configurable** (5 / 15 / 60 / never). |
| Transcription location | **On-device only** (no backend, no cloud). |
| Models | **User-selectable, mirror the macOS picker** (Parakeet + Whisper sizes). |
| Text post-processing | **Raw transcription only** for V1 (model's native punctuation). Architect a formatter seam for future cleanup/commands. Reuse existing rule-based `wordRemappings`/`wordRemovals` where cheap. |
| Keyboard UI | **Mic-centric minimal keyboard** — big mic button + waveform + a few controls (insert, delete-last, return-to-app, settings). No full QWERTY. |
| Host app scope | **Essentials + History.** (Onboarding, model mgmt, session control, settings, transcription history.) |
| Sync | **iCloud from day one** — settings + history (text/metadata) + vocab. |
| Audio sync | **Opt-in** (default off; Wi-Fi-only when enabled). Audio stays local by default. |
| Entry points | **Keyboard mic button + Shortcuts (App Intent).** App Intent also covers the Action Button. |
| Device floor | **iOS 17+, A14 / 8GB-class and newer** — comfortable headroom for on-device Parakeet/Whisper + background audio. |

## 5. Explicitly deferred (NOT in V1)

- **AI / LLM text cleanup** (filler removal, smart formatting) — formatter seam only.
- **Voice editing commands** ("new line", "delete that").
- **Coach** (pronunciation coaching) — host app is architected to add it later; Coach
  depends on History, which V1 ships.
- **Full QWERTY keyboard** with autocorrect / layouts / emoji.
- **Control Center widget** trigger.
- App Store submission + compliance hardening.

## 6. Reuse map (from codebase exploration)

**Reuse directly (already portable):** `TranscriptionClient` (WhisperKit),
`ParakeetClient` (FluidAudio), `SoundEffect`, `KeychainClient`, all Models
(`Transcript`, `HexSettings`, `ParakeetModel`, `wordRemappings`/`wordRemovals`), and
pure logic (`RecordingDecisionEngine`, `ModelPatternMatcher`, `HexLog`). WhisperKit
and FluidAudio both support iOS + Neural Engine.

**Re-implement behind the same interface for iOS (`+Live`):** `RecordingClient`
(AVAudioSession core is fine; CoreAudio device enumeration + AppleScript media control
are macOS-only), `PermissionClient`, `SleepManagementClient`.

**macOS-only, replaced by new iOS UX (do not port):** `KeyEventMonitorClient`
(global hotkey), `PasteboardClient` (synthetic paste), `InvisibleWindow`,
`HexAppDelegate` (menu bar), the `Sauce` dependency.

**TCA features reusable on iOS:** `TranscriptionFeature` (with iOS clients),
`HistoryFeature`, `SettingsFeature` + `ModelDownloadFeature`. New: a session-controller
feature + keyboard-IPC layer.

## 7. New components iOS needs (net-new)

- **Keyboard extension** target (mic-centric UI, `textDocumentProxy` insertion).
- **App Group** shared container + **Darwin notification** IPC between keyboard and host.
- **Session controller**: foreground entry, continuous `AVAudioSession`, timeout,
  swipe-back prompt screen.
- **App Intent** for Shortcuts / Action Button.
- **iCloud sync layer** (CloudKit for history text/metadata + vocab; key-value for
  settings; optional CloudKit assets for opt-in audio).
- **Onboarding flow**: enable keyboard → grant Full Access → mic permission → first
  Flow session. (Known high-friction; needs careful design.)

## 8. Open questions for the implementation plan

- Project structure: single Xcode project with macOS + iOS app targets + keyboard
  extension, all sharing a multiplatform `HexCore` SwiftPM package (recommended).
- Phase 0 refactor: move portable code into `HexCore`, add `.iOS` platform, gate
  macOS-only code behind `#if os(macOS)`, drop `Sauce`/`Cocoa` from `HexCore`.
- iCloud schema + conflict policy for History.

_(Device floor resolved: **iOS 17+, A14/8GB-class and newer** — see decisions table.)_
