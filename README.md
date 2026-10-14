# Hex Has Moved

Hex has moved to **[anomalyco/hex](https://github.com/anomalyco/hex)**. This Swift app is no longer maintained.
Download the new app at **[hex.kitlangton.com](https://hex.kitlangton.com)**, and please file new issues on [anomalyco/hex](https://github.com/anomalyco/hex/issues).
This repository preserves the original Swift app, its history, and its releases.

## Legacy Swift App

Press-and-hold a hotkey to transcribe your voice and paste the result wherever you're typing.

**[Download the legacy Swift version](https://hex-updates.s3.us-east-1.amazonaws.com/hex-latest.dmg)**

> **Note:** Hex is currently only available for **Apple Silicon** Macs.

Or download via homebrew:
```bash
brew install --cask kitlangton-hex
```

The Swift version supports [Parakeet TDT v3](https://github.com/FluidInference/FluidAudio)
through [FluidAudio](https://github.com/FluidInference/FluidAudio) and
[WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device transcription.
It uses the [Swift Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

## Instructions

Once you open Hex, you'll need to grant it microphone and accessibility permissions—so it can record your voice and paste the transcribed text into any application, respectively.

Once you've configured a global hotkey, there are **two recording modes**:

1. **Press-and-hold** the hotkey to begin recording, say whatever you want, and then release the hotkey to start the transcription process. 
2. **Double-tap** the hotkey to *lock recording*, say whatever you want, and then **tap** the hotkey once more to start the transcription process.

## Contributing

For the Rust beta, new features, and current development, use
**[anomalyco/hex](https://github.com/anomalyco/hex)**.
Issues specific to the legacy Swift app can still be reported
[here](https://github.com/kitlangton/Hex/issues). Please discuss substantial legacy
changes before opening a pull request.

### Changelog workflow

- **For AI agents:** Run `bun run changeset:add-ai <type> "summary"` (e.g., `bun run changeset:add-ai patch "Fix clipboard timing"`) to create a changeset non-interactively.
- **For humans:** Run `bunx changeset` when your PR needs release notes. Pick `patch`, `minor`, or `major` and write a short summary—this creates a `.changeset/*.md` fragment.
- Check what will ship with `bunx changeset status --verbose`.
- `npm run sync-changelog` (or `bun run tools/scripts/sync-changelog.ts`) mirrors the root `CHANGELOG.md` into `Hex/Resources/changelog.md` so the in-app sheet always matches GitHub releases.
- The release tool consumes the pending fragments, bumps `package.json` + `Info.plist`, regenerates `CHANGELOG.md`, and feeds the resulting section to GitHub + Sparkle automatically. Releases fail fast if no changesets are queued, so you can't forget.
- If you truly need to ship without pending Changesets (for example, re-running a failed publish), the release script will now prompt you to confirm and choose a `patch`/`minor`/`major` bump interactively before continuing.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
