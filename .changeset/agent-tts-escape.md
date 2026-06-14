---
"hex-app": patch
---

Fix the Agent Plugins voice window so pressing Escape always dismisses it and stops read-aloud (TTS) playback. Previously, while the reply field had focus the field editor swallowed Escape before it could reach the dismiss handler, so a long prompt being read aloud kept playing with no way to stop it.
