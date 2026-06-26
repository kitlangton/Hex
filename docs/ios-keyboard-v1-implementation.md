# Hex for iOS — Implementation Plan (V1)

> Companion to [ios-keyboard-v1-plan.md](ios-keyboard-v1-plan.md) (the feature spec).
> This is the file-by-file build plan. Phases are ordered so each one compiles and is
> independently verifiable before the next begins.

## Current structure (verified)

- `HexCore/` is a **local SwiftPM package** (`XCLocalSwiftPackageReference`, macOS-only:
  `platforms: [.macOS(.v14)]`). Linked into the Hex app.
- **WhisperKit + FluidAudio are wired at the app target**, not in HexCore. So
  `TranscriptionClient` / `ParakeetClient` live in `Hex/Clients/`, not in the package.
- `Sauce` is a HexCore dependency, used in 3 model files: `Models/HotKey.swift`,
  `Models/KeyEvent.swift`, `Models/KeyboardCommand.swift`.
- HexCore files with macOS-only imports: `HotKey.swift` (`Cocoa`), `PermissionClient+Live.swift`
  (`AppKit`/`IOKit`), `SleepManagementClient+Live.swift` (`IOKit.pwr_mgt`).
- **Linchpin:** `Settings/HexSettings.swift` is otherwise portable but transitively
  pulls in `HotKey` → `Cocoa`/`Sauce`. Decoupling this is the first real task.

Target end-state: **one Xcode project, three app-layer targets** (macOS app, iOS app,
iOS keyboard extension) all sharing a **multiplatform `HexCore`** that owns the
transcription engine.

```
HexCore (multiplatform SwiftPM)  ── engine: models, logic, TranscriptionClient, ParakeetClient, SoundEffect, Keychain
   ├── Hex (macOS app)            ── existing menu-bar app (unchanged behavior)
   ├── HexiOS (iOS app)           ── host/engine-room: onboarding, record session, models, history, settings, sync
   └── HexKeyboard (iOS ext)      ── mic-centric keyboard, talks to HexiOS via App Group + Darwin notifications
```

---

## Phase 0 — Make HexCore multiplatform (foundation, also benefits macOS)

Goal: HexCore compiles for **both** macOS and iOS; the macOS app still builds and
behaves identically. No iOS app yet. This is mostly mechanical and gated edits.

### 0.1 Package manifest
`HexCore/Package.swift`
- `platforms: [.macOS(.v14), .iOS(.v17)]`.
- Keep the `Sauce` package dependency declared, but **link it only on macOS**:
  `.product(name: "Sauce", package: "Sauce", condition: .when(platforms: [.macOS]))`.
- Make IOKit macOS-only: `.linkedFramework("IOKit", .when(platforms: [.macOS]))`.
- Add WhisperKit + FluidAudio as HexCore dependencies (see 0.4).

### 0.2 Decouple settings from macOS input types (the linchpin)
Goal: `HexSettings` and any shared code compile on iOS without `Sauce`/`Cocoa`.
- `Models/HotKey.swift`: keep the **plain data model** cross-platform (key as `Int`,
  modifiers as a portable `OptionSet`). Wrap only the platform bridges in
  `#if os(macOS)`: `import Cocoa`, `import Sauce`, `Modifiers.from(cocoa:)`,
  `from(carbonFlags:)`, `DeviceModifierMask`, and any Sauce `Key` display lookups.
- `Models/KeyEvent.swift`, `Models/KeyboardCommand.swift`: wrap `import Sauce` and all
  Sauce-typed members/initializers in `#if os(macOS)`; keep the Codable data shape
  available on both platforms (iOS never produces these, but shared types must compile).
- Verify `HexSettings` builds for iOS with the hotkey fields still present (just inert
  on iOS).

### 0.3 Platform-split the live clients
- `PermissionClient/PermissionClient+Live.swift`: wrap the whole macOS body in
  `#if os(macOS)`. Add an **iOS live** implementation (new file
  `PermissionClient+Live+iOS.swift`) behind `#if os(iOS)` covering **microphone only**
  (`AVAudioApplication.requestRecordPermission` / `AVAudioSession`), plus a
  "open Settings" deep link via `UIApplication.openSettingsURLString`. Accessibility /
  input-monitoring concepts don't exist on iOS — interface returns `.notApplicable`.
- `SleepManagementClient/SleepManagementClient+Live.swift`: wrap macOS body in
  `#if os(macOS)`; iOS impl uses `UIApplication.shared.isIdleTimerDisabled`.
- Keep both client **interfaces** (`PermissionClient.swift`, `SleepManagementClient.swift`)
  fully cross-platform.

### 0.4 Move the transcription engine into HexCore
So iOS and macOS share one engine instead of duplicating app code.
- Add to HexCore dependencies: WhisperKit (`XCRemote`), FluidAudio
  (`condition: .when(platforms: [.iOS, .macOS])`, guarded by `#if canImport(FluidAudio)`).
- Move into `HexCore/Sources/HexCore/Transcription/`:
  `TranscriptionClient.swift`, `ParakeetClient.swift`, `ParakeetClipPreparer.swift`,
  `LiveTranscriptionClient.swift`. Audit each for AppKit/`NSWorkspace`/AppleScript usage
  and gate any macOS-only bits. (`StoragePaths.swift` is already in HexCore — verify the
  iOS container path resolves under the App Group, see Phase 2.)
- Move `SoundEffect.swift` and `KeychainClient.swift` into HexCore (both cross-platform;
  Keychain `Security` framework works on iOS).
- Remove these packages from the **macOS app target** only after the app links them via
  HexCore (avoid double-linking).

### 0.5 Verify Phase 0
- `cd HexCore && swift test` passes on macOS.
- HexCore builds for an iOS simulator destination (`xcodebuild -scheme HexCore -destination 'generic/platform=iOS'` or via the package in Xcode).
- The macOS Hex app builds and runs unchanged.

**Deliverable:** a multiplatform engine package. No user-visible change on macOS.

---

## Phase 1 — iOS host app (record → transcribe → history)

Goal: a standalone iOS app that records (foreground), transcribes on-device, and shows
history. This de-risks on-device Parakeet/Whisper before any keyboard complexity.

### 1.1 New target
- Add **`HexiOS`** app target (SwiftUI lifecycle, iOS 17). Link HexCore, WhisperKit,
  FluidAudio. Set `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, device family iPhone.
- `Info.plist`: `NSMicrophoneUsageDescription`; background mode `audio` (used in Phase 3);
  custom URL scheme (e.g. `hexkb://`) for the keyboard bounce (Phase 2).

### 1.2 iOS RecordingClient
- New `RecordingClient+Live+iOS.swift` behind `#if os(iOS)` implementing the existing
  `RecordingClient` interface using `AVAudioEngine`/`AVAudioSession` (16 kHz mono, matches
  Parakeet expectations). Drop CoreAudio device enumeration + AppleScript media control
  (macOS-only). Reuse `SuperFastCaptureController` ring-buffer logic if portable; otherwise
  a simpler iOS capture path is fine for V1.

### 1.3 Reuse TCA features
- Reuse `TranscriptionFeature` with the iOS clients injected; drop the paste/hotkey
  branches (no `PasteboardClient`, no `KeyEventMonitorClient` on iOS).
- Reuse `HistoryFeature` + `SettingsFeature` + `ModelDownloadFeature` (model picker
  mirrors macOS). Build iOS SwiftUI views for: record screen, history list, settings,
  model download.

### 1.4 Verify Phase 1
- Record in-app → on-device transcription returns text → appears in history. Test both a
  Whisper size and Parakeet on a real A14+ device (memory/perf check).

**Deliverable:** shippable standalone iOS voice-notes app; on-device ML proven.

---

## Phase 2 — Keyboard extension + IPC

Goal: the mic-centric keyboard that inserts transcribed text, talking to the host app.

### 2.1 New target + entitlements
- Add **`HexKeyboard`** keyboard extension target.
- Create an **App Group** (e.g. `group.co.stonefrontier.hex`) shared by `HexiOS` +
  `HexKeyboard`. Move the shared container / model storage under the App Group so both
  processes read/write the same place (update `StoragePaths` for iOS).
- Keyboard requires **Full Access** (`RequestsOpenAccess = true`) for App Group + network.

### 2.2 Keyboard UI (`KeyboardViewController`)
- Mic-centric SwiftUI hosted in the input view: big mic button, live waveform/status,
  controls: insert, delete-last-utterance, return-to-app hint, open-settings.
- Text insertion via `textDocumentProxy.insertText` / `deleteBackward`.

### 2.3 IPC layer (new in HexCore, `IPC/`)
- **App Group container** for the latest transcription result + session state flags.
- **Darwin notifications** (`CFNotificationCenterGetDarwinNotifyCenter`) for cross-process
  signals: keyboard→app "capture start/stop", app→keyboard "result ready".
- Keyboard polls/observes the App Group file for the result and inserts it.

### 2.4 The bounce
- Keyboard "Start session" uses the **responder-chain `openURL` hack** to open
  `hexkb://start-session`. (Documented as unsupported; acceptable for open-source/sideload.)
- Host app handles the URL, starts the session (Phase 3), shows a "Swipe back to your app"
  screen (Apple removed auto-return).

### 2.5 Verify Phase 2
- From a real text field (Notes/Safari): switch to Hex keyboard → start session → swipe
  back → tap mic → speak → text inserts. Confirm **no re-bounce** for a second dictation
  within the session window.

**Deliverable:** working dictation-into-any-app loop.

---

## Phase 3 — Session controller + Shortcuts

Goal: the continuous-mic session model and the second entry point.

### 3.1 Session controller (new TCA feature in HexiOS)
- On `hexkb://start-session`: activate a **continuous** `AVAudioSession` in the
  foreground, enable background-audio so it survives the swipe-back; mic stays hot.
- Keyboard mic taps (via Darwin notif) mark snippet boundaries; the running host app
  transcribes each snippet and writes results to the App Group — **no re-bounce**.
- **Timeout**: configurable (5 / 15 / 60 / never), default **15 min**; on expiry, tear
  down the session (next use re-bounces). Surface remaining-time + an end-session control.

### 3.2 Shortcuts / Action Button
- Add an **App Intent** ("Start Hex Dictation") so Shortcuts and the Action Button can
  trigger a session. Reuses the same session controller entry path as the URL scheme.

### 3.3 Verify Phase 3
- Session honors the timeout; battery/indicator behavior is as expected (orange indicator
  on for the session). App Intent starts a session from Shortcuts.

**Deliverable:** the full Wispr-style session UX + Shortcuts entry.

---

## Phase 4 — iCloud sync (settings + history + vocab; audio opt-in)

Goal: cross-device continuity with the macOS app.

### 4.1 Settings + vocab
- Sync `HexSettings` (relevant subset) + `wordRemappings`/`wordRemovals` via
  `NSUbiquitousKeyValueStore` (small, simple, conflict-tolerant).

### 4.2 History (text/metadata)
- CloudKit private DB: a `Transcript` record type (text, timestamps, app context,
  duration, language). Sync on both iOS and macOS. Define a conflict policy
  (last-writer-wins keyed by stable transcript `id`; dedupe on id).
- Ensure `Transcript`/`TranscriptionHistory` models have **stable IDs** + are Codable
  (mostly true already — audit).

### 4.3 Audio (opt-in)
- Setting (default **off**, Wi-Fi-only when on): sync recordings as **CloudKit assets**.
  Throttle uploads; guard cellular. Audio absent on a device → history row shows
  text-only (playback disabled).

### 4.4 Verify Phase 4
- Dictate on iOS → row appears on macOS (and vice versa). Toggle audio sync and confirm
  asset transfer respects Wi-Fi-only.

**Deliverable:** Mac ↔ iOS continuity.

---

## Cross-cutting

### Onboarding (host app, build alongside Phase 2)
High-friction, needs care: (1) add keyboard in Settings → (2) enable Full Access →
(3) grant mic permission (must be triggered from the **host app**, not the keyboard) →
(4) download a model → (5) first session walkthrough incl. the swipe-back gesture.

### Project / repo structure
- Keep one `Hex.xcodeproj`. Add `HexiOS` + `HexKeyboard` targets. Share schemes for CI.
- Consider a shared `HexUI` package later if SwiftUI views diverge; not needed for V1.

### Testing
- Keep `HexCore` unit tests green on both platforms.
- Add tests for the IPC result round-trip and session timeout logic (pure logic, no UI).
- Manual device matrix: at least one A14-class and one current device.

### Risks / watch-items
- **Background-audio survival** across the swipe-back is the #1 technical risk — spike it
  early in Phase 3 (or a throwaway probe during Phase 1) before committing UI.
- **`openURL` hack** could break on an iOS update; isolate it behind one function.
- **Model memory** on the device floor — validate Parakeet vs Whisper sizes on A14/8GB.
- **App Group storage path** must be consistent across both processes (Phase 2.1).

## Suggested sequencing

Phase 0 → 1 first (each independently shippable/verifiable and low-risk). Spike the
background-audio-session survival probe before fully building Phase 3. Phase 2 and 3 are
tightly coupled — build 2's IPC + bounce, then 3's session model. Phase 4 last.
