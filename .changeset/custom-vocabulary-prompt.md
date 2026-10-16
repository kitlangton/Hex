---
"hex-app": minor
---

Add custom vocabulary prompt for Whisper models: a new "Custom vocabulary" section in the Transforms tab lets you list names/jargon the transcriber gets wrong. The terms are injected as decoder prompt tokens (Whisper's `initial_prompt` equivalent) before transcription, biasing WhisperKit toward the exact spelling and casing you entered. Applies to Whisper models only; Parakeet ignores the setting.
