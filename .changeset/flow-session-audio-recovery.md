---
"hex-app": patch
---

Fix the iOS Flow Session silently dying in the background. The continuous-capture audio engine had no interruption handling, so iOS would deactivate it on audio interruptions (calls, Siri, other apps), route/config changes (common when switching apps), or media-services resets — while the session kept reporting itself as "active." Tapping the keyboard mic then recorded an empty file and surfaced a generic `Foundation._GenericObjCError error 0` alert when you returned to the app; toggling Dictation off/on was the only workaround. SessionAudioEngine now observes interruption / configuration-change / media-reset notifications and restarts the engine, the capture path verifies a live engine (and re-bounces for a fresh session if it can't recover), and background snippet failures are logged instead of showing an out-of-context modal.
