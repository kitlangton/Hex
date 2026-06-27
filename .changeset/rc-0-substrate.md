---
"hex-app": minor
---

Retain dictation audio and persist every dictation as the Coach corpus substrate (RC-0). Recordings are no longer deleted after transcription — they're moved into the App Group and referenced by a portable filename. Transcripts now carry a `kind` (`.dictation` for cross-app/keyboard Flow Sessions vs `.note` for in-app capture) plus an optional `sourceAppName`, so the upcoming Review/Coach companion can mine real daily speech.
