# Hex for iOS — Production Plan

> Goal: take the working V1 prototype to a **production-grade, releasable** app that
> matches the LOCKED design ([ios-ui-design-v1.md](ios-ui-design-v1.md)) and product spec
> ([ios-keyboard-v1-plan.md](ios-keyboard-v1-plan.md)). Builds on the validated core
> (continuous Flow Session works on device — SPIKE-1 passed).

## Where we are (prototype → production gap)

Working: multiplatform HexCore, IPC layer, HexIOS app, dictation keyboard, continuous
Flow Session. **Prototype debt to pay down:**
- Transcription is **WhisperKit "base" wired directly** in HexIOS — not the shared engine,
  not Parakeet.
- Recording lives in HexIOS (`AudioRecorder`, `SessionAudioEngine`) instead of HexCore
  clients; the session engine's audio tap uses a hand-rolled lock.
- UI is a functional placeholder, **not** the locked design.
- App is **MV/`@Observable`**, while the plan/design assume **reuse of the macOS TCA
  features** (`TranscriptionFeature`/`HistoryFeature`/`SettingsFeature`).
- No tests on the iOS side, no privacy manifest, no onboarding, no sync.

## Decisions this plan depends on (confirm first)

1. **App architecture** — adopt **TCA** in HexIOS (reuse macOS reducers; consistent, testable
   with `TestStore`) vs keep **MV/`@Observable`** (less ceremony, but diverges from the plan
   and the macOS app). *Recommendation: TCA*, since History/Settings/Model logic already
   exists as reducers and we want one shared brain.
2. **Default on-device engine** — **Parakeet** (macOS default; multilingual, fast on ANE) vs
   **Whisper** sizes vs **both, user-selectable** (design's Settings shows a model picker).
   *Recommendation: both, Parakeet default.*
3. **Release target** — **App Store** vs **TestFlight/personal**. This is load-bearing: the
   `openURL` bounce + background-audio are App Store review risks (see Risks). *Recommendation:
   build to App-Store quality but ship TestFlight first.*

## Workstreams

### A — Foundation / rebalance  (pay down prototype debt)
- **P0-4**: move the engine into HexCore as proper `@DependencyClient`s. New shared clients:
  `TranscriptionClient` (Whisper + Parakeet), `RecordingClient` (one-shot), `SessionAudioClient`
  (continuous). Publicize API; keep HexCore Swift-6-clean (or an isolated Swift-5 engine
  sub-target if migration is heavy).
- Replace WhisperKit-direct prototype with the shared engine; **add Parakeet** (FluidAudio).
- Fix `SessionAudioEngine` tap thread-safety properly (audit under Swift 6); dedupe the two
  recording paths.
- Lock in the **architecture decision** (TCA features wired into HexIOS).
- *Skills:* `apple-on-device-ai`, `swift-architecture`, `swift-api-design-guidelines`.

### B — UI to the locked design  (P1-3, P2-2, X-1)
- **Tab root** (Home / History / Settings), floating pill tab bar; Liquid Glass with
  availability fallback to flat fills (< iOS 26).
- **Home** (status pill + New-note card + Recent), **Recording** modal (timer/waveform/stop,
  transient Transcribing), **History** (unified, day-grouped, source tags, inline playback),
  **Settings** (grouped inset lists; model picker; session length / language / vocab / sync /
  clean-up-filler placeholder / Full-Access status), **Onboarding** (5-step, real system state).
- **Keyboard**: all 6 states (design §5), accent mic, "mic hot · MM:SS" pill, waveform,
  undo-last / mic / backspace + globe/settings.
- **Design tokens**: single `AccentColor`; verify **light + dark**.
- *Skills:* `swiftui-liquid-glass`, `swiftui-patterns`, `swiftui-navigation`,
  `swiftui-layout-components`, `swiftui-animation`.

### C — Hands-free entry  (P3-2)
- App Intent **"Start Hex Dictation"** → starts a session (reuses the session controller);
  Shortcuts + **Action Button**. Control Center later.
- *Skills:* `app-intents`.

### D — Sync & unified data  (P4)
- Unified History model (source + stable IDs, Codable). iCloud: settings/vocab via KVS,
  History via CloudKit, **opt-in** audio assets (Wi-Fi only).
- *Skills:* `cloudkit`.

### E — Production hardening  (cross-cutting, runs alongside B–D)
- **Error handling & recovery:** model-load failure, session loss, no Full Access, app
  unreachable from keyboard — every keyboard state from design §5 has a real path.
- **Logging:** route through `HexLog`, privacy annotations on transcript text/paths.
- **Tests:** HexCore logic + IPC + session-timeout (Swift Testing); TCA reducers (`TestStore`)
  if we adopt TCA. *Skill:* the repo `tdd` skill / `swift` testing guidance in
  [swift-ios-guidelines.md](engineering/swift-ios-guidelines.md).
- **Accessibility:** VoiceOver labels, Dynamic Type, contrast, reduce-motion. *Skill:*
  `design:accessibility-review`.
- **Privacy & review prep:** `PrivacyInfo.xcprivacy` (mic + required-reason APIs), entitlements
  audit, extension API-only safety for HexCore in the keyboard, App Store guideline pass.
  *Skill:* `app-store-review`.
- **Performance/battery:** model memory on the device floor (A14/8GB), keyboard memory budget,
  session battery cost, cold-launch latency. *Skill:* `swiftui-performance`.
- **Changesets** per CLAUDE.md for every user-facing change.

## Milestones

- **M-A — Solid foundation:** engine in HexCore + Parakeet, architecture set, debt paid. (A)
- **M-B — Design-complete:** every screen matches the locked design, light+dark. (B)
- **M-C — Full-featured:** hands-free entry + iCloud sync + unified History. (C, D)
- **M-D — Release-ready:** tests, a11y, privacy/review, perf → **TestFlight**. (E)

Suggested order: **A → B** (foundation before re-skinning, so we re-skin the *final*
architecture once), then **C/D in parallel**, with **E** continuous throughout.

## Risks / watch-items

- **App Store review:** the keyboard's `openURL` bounce is "unsupported," and background-audio
  needs a real justification (guideline 2.5.4). Mitigation: keep TestFlight as the floor;
  for App Store, isolate the hack, document the audio need, and have a fallback UX.
- **Keyboard memory:** never load a model in the extension (host app only) — already the case;
  guard it stays that way.
- **TCA adoption cost:** rewriting the prototype's MV screens as reducers is real work; doing
  it in M-A (before the UI build) avoids doing the UI twice.
- **Parakeet on the device floor:** validate memory/latency before making it the default.
