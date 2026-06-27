# [X-1] Onboarding flow

- **Phase:** cross-cutting (build alongside Phase 2)
- **Depends on:** P2-2
- **Blocks:** —
- **Size:** M
- **Risk:** Medium — high user friction; the #1 conversion killer for keyboard apps.

## Goal
Guide the user through the multi-step setup with as little drop-off as possible.

> **UI design is LOCKED:** follow [ios-ui-design-v1.md](../ios-ui-design-v1.md) screen 6 —
> accent mic header + a 5-step checklist, each step reflecting real system state, with one
> primary CTA.

## Tasks
- [ ] Step 1: add the keyboard in iOS Settings (deep link + instructions).
- [ ] Step 2: enable Full Access (explain why: App Group + network).
- [ ] Step 3: grant microphone permission — must be triggered from the **host app**, not
      the keyboard.
- [ ] Step 4: download a model.
- [ ] Step 5: first-session walkthrough incl. the manual swipe-back gesture.
- [ ] Detect completion state for each step and resume where the user left off.

## Acceptance criteria
- [ ] A fresh install can reach a successful first dictation following only in-app guidance.
- [ ] Each step reflects real system state (don't show "enable keyboard" if already enabled).

## Files
- `HexiOS/Onboarding/*`
