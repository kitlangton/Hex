Parakeet (NVIDIA) – Core ML integration

Overview
- This app can now run Parakeet TDT models on‑device using a Parakeet‑aware runtime.
- Integration is conditional: it activates when the FluidAudio Swift package is linked.

Setup (once)
- In Xcode, add package dependency: https://github.com/FluidInference/FluidAudio
- Select a Parakeet variant in Settings → Transcription Model:
  - "Parakeet TDT 0.6B (EN)" → English
  - "Parakeet TDT 0.6B (Multilingual)" → 25 European languages
- First transcription triggers an automatic download by the runtime. No manual steps required.

Optional: manual model install
- You can place precompiled Core ML bundles under:
  ~/Library/Application Support/com.kitlangton.Hex/models/parakeet/<variant>/
- Expected contents include: ParakeetEncoder.mlmodelc, RNNTJoint.mlmodelc, ParakeetDecoder.mlmodelc, and a Melspectrogram .mlmodelc.
- Ready‑made bundles: search for parakeet‑tdt‑0.6b‑v2‑coreml or parakeet‑tdt‑0.6b‑v3‑coreml (Hugging Face).

Notes
- Whisper models continue to use WhisperKit.
- The UI marks Parakeet as "downloads on first use"; deletion from within the app applies only to Whisper models.
- If FluidAudio is not linked, selecting a Parakeet model will return a clear error at runtime.

