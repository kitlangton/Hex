---
"hex-app": patch
---

Optimize recorder startup by keeping AVAudioRecorder primed between sessions, eliminating ~500ms latency for successive recordings
