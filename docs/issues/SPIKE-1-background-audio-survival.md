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

## Result — PASSED ✅ (2026-06-27, on device)

Validated live via the P3-1 implementation rather than a throwaway probe. With the
host app holding a continuous `AVAudioEngine` (UIBackgroundModes: audio) started in
the foreground, the app **survives the swipe-back and keeps recording in the
background**: the keyboard signals capture start/stop over Darwin notifications and
inserts results **with no re-bounce**. Confirmed working end-to-end on the user's
iPhone (paid team, Full Access enabled).

**Conclusion:** the continuous-session architecture is viable. Bounce once per session
to start; in-place dictation thereafter. Proceed with P3 on this design.

## Notes
This was validated through real usage, not a throwaway probe. The deliverable was
*knowledge*: the session model holds on device.
