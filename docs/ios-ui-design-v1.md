# Hex for iOS — UI Design (V1, LOCKED)

> Companion to [ios-keyboard-v1-plan.md](ios-keyboard-v1-plan.md) (product spec) and
> [ios-keyboard-v1-implementation.md](ios-keyboard-v1-implementation.md) (build plan).
> This is the **visual + interaction design** for the host app and keyboard. Decisions
> here are locked for V1; revisit only with a deliberate change.

## 1. Design language

- **Monochrome surfaces, one accent.** All backgrounds/text/borders are neutral and come
  from the system semantic palette (so dark mode is automatic). Exactly **one accent
  color** — iOS system blue (`#007AFF`) — applied **only to interactive / live signals**:
  the mic button, toggles (on), the active tab, play/sync glyphs, the primary CTA, and the
  "mic hot" session pill. Color earns its place by meaning ("tappable" / "live"), never as
  decoration.
- **Single swappable tint token.** The accent is one variable (think `--ac` / an asset
  catalog color `AccentColor`). Changing the whole app's identity later is a one-line edit.
  More brand color can be added post-V1; do not scatter hardcoded colors.
- **iOS 26 / Liquid Glass cues:** large continuous corner radii; **grouped inset lists**
  (Settings); a **floating pill tab bar**; glass/material on the tab bar and over-keyboard
  chrome where the OS supports it. Use the `swiftui-liquid-glass` patterns, gated by
  availability with a clean fallback to flat fills on < iOS 26.
- **Dark mode is mandatory** — verify every screen in both appearances.

## 2. Navigation

Root is a **tab bar** with three tabs:

| Tab | Purpose |
|-----|---------|
| **Home** | Engine-room status + in-app voice **notes**. |
| **History** | Unified transcript list (notes + keyboard insertions). |
| **Settings** | Model, session, language, vocabulary, sync, keyboard status. |

Recording (note capture) and Onboarding are **presented modally / full-screen**, not tabs.

## 3. Two ways to make text (one history)

1. **In-app notes** (Home mic): record → on-device transcribe → **save as a note inside
   Hex**. Never switches apps. This is the "simple notes" use case.
2. **Keyboard** (any other app): the session-based hot-mic dictation from the product spec
   — bounce once, then keyboard mic taps insert text with no re-bounce until timeout.

Both flow into **one unified History list**, each row tagged with its **source** (Note,
Messages, Mail, Safari, …) via an app/source icon. Keep it unified for V1 (it is also the
clean data foundation for a future **Coach**); split into segments/tabs later only if it
gets noisy.

## 4. Screen inventory

Reference mockup: the `hex_ios_app_designs_v3_ios26` widget (six screens). Summary:

1. **Home** — title; keyboard-ready status pill (tinted: `⌨ Keyboard ready · <model>`); a
   bordered **New note** card with the accent mic button + "Records & saves here. Won't
   switch apps."; a **Recent** preview (last 2–3, with source icons); floating tab bar.
2. **Recording** (modal over Home) — "New note" label; red recording dot + timer pill;
   waveform; accent stop button; "Tap to stop · swipe up to cancel". Then a transient
   "Transcribing…" state. **No live partial-transcript preview in V1** (see §6).
3. **Keyboard** (the product) — shown docked under a host app. Tinted **"mic hot · MM:SS
   left"** session pill; waveform; the mic button + minimal controls (globe / space /
   backspace / return). **No QWERTY.** Insertion via `textDocumentProxy`. In-place **editing
   controls** beyond the basics (a letter-free control surface) are scoped separately in
   [P2-5](issues/P2-5-keyboard-editing-controls.md).
4. **History** — search field; day-grouped rows (`text · time · source · duration`); inline
   play on rows that have audio; iCloud status glyph in the header.
5. **Settings** — grouped inset lists: **Group 1** Model / Session length / Language /
   Vocabulary (push rows mirroring the macOS picker). **Group 2** iCloud sync (on) / Sync
   audio (off) / Clean-up filler (off). **Group 3** Keyboard → Full Access status. Tab bar.
6. **Onboarding** — accent mic header; a 5-step checklist (add keyboard → Full Access → mic
   permission → download model → first dictation incl. swipe-back), each step reflecting
   **real system state**; primary CTA.

## 5. Keyboard interaction states (to design/build under P2-2)

> In-place editing (a letter-free control surface, caret trackpad, etc.) is scoped
> separately — see [P2-5](issues/P2-5-keyboard-editing-controls.md).

The keyboard must render and read clearly in every state:

- **No Full Access** — disabled mic + "Enable Full Access in Settings ▸ Keyboards".
- **Idle / ready** — "Tap to dictate" (or "mic hot · MM:SS left" when a session is live).
- **Recording** — waveform animating, recording affordance.
- **Inserting** — brief confirmation after `insertText`.
- **Session expired / needs bounce** — prompt to re-start a session (re-bounce).
- **Error** — model/app unreachable.

## 6. Locked decisions & deferrals

- **Visual identity:** monochrome + single iOS-blue accent for V1. More color later.
- **Live transcription preview (#237): deferred.** V1 is record → stop → transcribe →
  insert/save. Keep the recording UI simple; design the streaming preview later.
- **History is unified** (notes + insertions) with a source tag. No split tabs in V1.
- **"Clean-up filler" toggle** is the visible placeholder for the deferred formatter seam
  (#199); default **off**. It signals the architecture intent without shipping the feature.
- **Coach** remains post-V1; History is its foundation and ships in V1.

## 7. Where this is implemented

| Screens | Issue |
|---------|-------|
| Home, Recording, History, Settings, model picker | [P1-3](issues/P1-3-ios-host-ui.md) |
| Keyboard UI + all keyboard states (§5) | [P2-2](issues/P2-2-keyboard-ui.md) |
| Onboarding checklist | [X-1](issues/X-1-onboarding-flow.md) |
| Accent/sync glyphs, audio playback rows | [P4-1](issues/P4-1-settings-vocab-sync.md) / [P4-2](issues/P4-2-history-sync-cloudkit.md) / [P4-3](issues/P4-3-audio-sync-optin.md) |
