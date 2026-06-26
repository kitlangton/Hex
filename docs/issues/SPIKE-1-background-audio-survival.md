# [SPIKE-1] Background-audio session survival probe

- **Phase:** risk spike (do EARLY, before P3)
- **Depends on:** none (a throwaway probe; can ride on P1 once a target exists)
- **Blocks:** P3-1
- **Size:** S
- **Risk:** HIGH — validates the central premise of the whole product

## Goal
Prove that a host app can keep an `AVAudioSession` recording across a foreground →
background transition (the "swipe back to your app" moment) so subsequent keyboard
dictations need **no re-bounce**. If this doesn't hold, the session model in the spec
is invalid and we must fall back to per-dictation bounce.

## Tasks
- [ ] Minimal app: start a continuous `AVAudioSession` (record) in the foreground with
      the `audio` background mode enabled.
- [ ] Background the app (simulate the swipe-back); confirm capture continues and the
      orange indicator stays on.
- [ ] From background, trigger "capture a snippet" via a Darwin notification and confirm
      audio buffers are still flowing.
- [ ] Measure: how long does iOS keep it alive? Any suspension after N minutes idle?
      Behavior when the mic *stops* then needs to restart from background (expected: must
      re-foreground).

## Acceptance criteria
- [ ] Documented answer (in this file) on whether continuous background capture survives
      the swipe-back, for how long, and under what conditions it dies.
- [ ] Go/no-go recommendation for the P3 session model vs per-dictation fallback.

## Notes
This is throwaway code; do not gold-plate. The deliverable is *knowledge*, captured here.
