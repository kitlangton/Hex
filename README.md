# Hex — Voice → Text, with practical refinements

This is a personal fork of [Kit Langton's Hex](https://github.com/kitlangton/Hex), a fast macOS menu-bar app for on-device voice transcription. I created it to bring together a few features I wanted in daily use while they are considered for upstream inclusion.

It remains Hex at its core: hold a global hotkey, speak, and have the transcription pasted into the app you are using. This fork adds more dependable recovery, more flexible hotkeys, and optional AI-powered cleanup when you want it.

> This is not the official Hex distribution. Build this fork yourself if you want to use these additions; for the official app and releases, visit the [upstream project](https://github.com/kitlangton/Hex).

## What this fork adds

### Refine transcriptions and selected text with your voice

Keep normal transcription unchanged, or set a separate refinement hotkey to clean up, rewrite, or format the completed transcript with your own instructions.

- Choose Apple Intelligence, Gemini, or any text model available through OpenRouter.
- Store provider credentials securely and select an OpenRouter model from its catalog.
- Select text in another app, trigger the refinement hotkey, and dictate an instruction such as “make this shorter and friendlier.” Hex replaces the selected text with the refined result while preserving your clipboard.
- Refinement runs after Hex's normal text transforms. Audio remains on-device; when you select a cloud provider, only the completed text is sent to it.

### Keep failed recordings available for retry

Failed and cancelled recordings stay in History rather than disappearing. Retry them when you are ready, with successful retry output copied to the clipboard. You can choose whether cancelled recordings should be retained.

### Use modifier-only hotkeys your way

Modifier-only hotkeys support double-tap-only recording and respect your configured minimum key time, rather than imposing a separate hard-coded delay.

## Build from source

This fork is intended to be built locally on an Apple Silicon Mac running macOS 14 or later with Xcode 15 or later:

```bash
git clone https://github.com/blackforestboi/Hex.git
cd Hex
xcodebuild -scheme Hex -configuration Debug \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO build
```

Open the resulting `Hex Debug.app` from Xcode's DerivedData build products, then grant microphone and accessibility permissions when prompted.

## Upstream work included here

This fork combines and extends several upstream contributions:

- [#217 — Keep failed and cancelled recordings around for retry](https://github.com/kitlangton/Hex/pull/217)
- [#227 — Allow double-tap-only mode for modifier hotkeys](https://github.com/kitlangton/Hex/pull/227)
- [#241 — Respect the user's minimumKeyTime for modifier-only hotkeys](https://github.com/kitlangton/Hex/pull/241)
- [#191 — Transcription refinement via Apple Intelligence / Gemini](https://github.com/kitlangton/Hex/pull/191), which inspired the refinement workflow and has been substantially adapted here.
