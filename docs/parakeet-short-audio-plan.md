# Parakeet Short-Audio Padding Plan

## Problem Statement
- FluidAudio's Parakeet TDT v3 decoder refuses to run (or produces unstable text) when the input WAV is shorter than its internal chunk size.
- Hex often emits <250 ms clips when users tap-to-talk, so we must “pack” (pad) the PCM before `AsrManager.transcribe(_:)` is called.
- WhisperKit already zero-pads to 30 s internally, but Parakeet expects callers to hand it an audio segment that spans an entire chunk.

## Goals (Parakeet-first)
1. Detect when a captured recording is below Parakeet’s minimum duration (TBD) and ensure the on-disk file we hand to FluidAudio meets or exceeds that window.
2. Keep padding transparent to users: no audible artifacts, no extra latency, and logs that explain when/why padding ran (`HexLog.parakeet`).
3. Limit scope to Parakeet for now; Whisper will keep using its existing flow unless we discover regressions.

## Constraints & Research Tasks
- [ ] Confirm Parakeet’s required sample count / duration. FluidAudio docs hint that v3 expects whole “chunk_duration” intervals (default 1.5 s @ 16 kHz mono). Need an authoritative value from:
  - `FluidAudio/Documentation/Models/ASR/LastChunkHandling.md`
  - Hugging Face card for `parakeet-tdt-0.6b-v3-coreml`
  - Any sample scripts in `FluidAudio` repo (look for `chunk_duration`, `min_samples`, or padding helpers).
- [ ] Determine whether Parakeet tolerates zero-padding vs. repeating tail samples. Preference is zero-padding unless docs warn about VAD slip.
- [ ] Verify whether padding must retain the original WAV container (RIFF header). If `AsrManager` only reads PCM floats, we can rewrite the whole file; otherwise we may need to append silence samples and fix the header lengths.

## Current Pipeline Touchpoints
1. `Hex/Clients/RecordingClient.swift:667` sets up `AVAudioRecorder` at 16 kHz mono float and writes to `recording.wav` in `FileManager.default.temporaryDirectory`.
2. `Hex/Features/Transcription/TranscriptionFeature.swift:320` calls `recording.stopRecording()` and passes the resulting URL into `TranscriptionClient.transcribe`.
3. `Hex/Clients/TranscriptionClient.swift:242` routes Parakeet variants straight to `ParakeetClient.transcribe(_:)` with no preprocessing.
4. `Hex/Clients/ParakeetClient.swift:118` hands the URL to `AsrManager.transcribe(url)` and returns the text.

These spots give us two obvious injection points: (a) mutate the WAV immediately after `recording.stopRecording()` returns, or (b) intercept inside `ParakeetClient` before calling FluidAudio.

## Implementation Plan

### Phase 1 – Instrumentation & Guardrails
1. Add a lightweight helper (e.g., `ShortClipInspector`) that loads the WAV header, validates sample rate/channels, and returns total duration.
2. Insert the inspector inside `TranscriptionClient` right before the Parakeet branch so we can log current clip lengths (`HexLog.parakeet.debug("clip=0.18s")`).
3. Ship this logging first (behind a debug flag if needed) to confirm real-world distributions before we enable padding.

### Phase 2 – Padding Helper (Parakeet Only)
1. Create a new utility in `Hex/Audio/ShortClipPadder.swift` (or similar) that:
   - Accepts a source `URL`, desired minimum samples, and output `URL` (can be the same file if we rewrite safely).
   - Reads PCM floats via `AVAudioFile` or `ExtAudioFile`, counts samples, and if below threshold, appends zeros until `minSamples` is met.
   - Rewrites the WAV header chunk sizes so the file stays valid.
2. Unit test this helper in `HexCoreTests` with fixtures (<50 ms clip, >threshold clip) to guarantee correct math and metadata.
3. Make the minimum configurable (env var or `HexSettings`) so we can tweak without hard-coding; default to whatever FluidAudio recommends.

### Phase 3 – Integration Path
1. Inside `TranscriptionClient.transcribe`, when `isParakeet(model)` is true:
   - Inspect clip duration.
   - If below threshold, call the padder and produce a temporary padded file (e.g., `recording_padded.wav`).
   - Pass the padded URL to `parakeet.transcribe` and clean up temp files afterward.
2. Alternatively (if we want to contain logic), embed the padding call in `ParakeetClient.transcribe` so every backend use (future features/tests) benefits without touching the rest of the app flow.
3. Ensure padding happens off the main actor to avoid UI stalls—`TranscriptionClient` already runs inside an async task, so heavy I/O should stay there.

### Phase 4 – Telemetry & Recovery UX
1. Emit structured logs when padding occurs, including original duration and pad length, so we can grep Console for “Parakeet padded clip”.
2. If FluidAudio still rejects the clip after padding, surface a user-friendly error and optionally auto-retry with a slightly longer pad.
3. Consider capturing anonymized counts (number of padded clips per session) for future tuning once analytics hooks exist.

## Validation Strategy
- **Unit tests:**
  - `ShortClipPadderTests` verifying sample count math, header rewrites, and idempotent behavior when clip already meets threshold.
- **Integration smoke test:**
  - CLI harness that feeds a synthetic 150 ms WAV through `ParakeetClient` with padding enabled; ensure the decoder returns text (or at least does not throw).
- **Manual QA:**
  - Tap hotkey quickly on macOS 15 (Intel + Apple Silicon). Confirm transcripts appear instead of “clip too short” errors, and latency increase is negligible (<5 ms for padding).

## Open Questions
1. Does `AsrManager.transcribe` stream audio internally (making padding unnecessary if we tweak its chunk config) or does it expect fully sized files only?
2. Should we preserve raw, unpadded recordings for history exports while only padding the temporary file handed to Parakeet?
3. Do we need to bump the `RecordingDecisionEngine` thresholds so we still discard accidental tap-noise clips, or is padding enough?
4. Could insanely short clips (e.g., <10 ms) produce audible pops once padded? If so, we may need a pre-smoothing step (fade in/out) before zero-fill.

> Next action: gather the concrete min-duration requirement from FluidAudio docs and pick an injection point (TranscriptionClient vs. ParakeetClient) so we can spike the padding helper.
