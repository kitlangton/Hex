# Hex — Voice → Text

Press-and-hold a hotkey to transcribe your voice and paste the result wherever you're typing.

**[Download Hex for macOS](https://hex-updates.s3.us-east-1.amazonaws.com/hex-latest.dmg)**
> **Note:** Hex is currently only available for **Apple Silicon** Macs.

I've opened-sourced the project in the hopes that others will find it useful! Hex supports both [Parakeet TDT v3](https://github.com/FluidInference/FluidAudio) via the awesome [FluidAudio](https://github.com/FluidInference/FluidAudio) (the default—it's frickin' unbelievable: fast, multilingual, and cloud-optimized) and the awesome [WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device transcription. We use the incredible [Swift Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) for structuring the app. Please open issues with any questions or feedback! ❤️

## Contributing

**Issue reports are welcome!** If you encounter bugs or have feature requests, please [open an issue](https://github.com/kitlangton/Hex/issues).

**Note on Pull Requests:** At this stage, I'm not actively reviewing code contributions for significant features or core logic changes. The project is evolving rapidly and it's easier for me to work directly from issue reports. Bug fixes and documentation improvements are still appreciated, but please open an issue first to discuss before investing time in a large PR. Thanks for understanding!

### Changelog workflow

- Run `bunx changeset` when your PR needs release notes. Pick `patch`, `minor`, or `major` and write a short summary—this creates a `.changeset/*.md` fragment.
- Check what will ship with `bunx changeset status --verbose`.
- `npm run sync-changelog` (or `bun run tools/scripts/sync-changelog.ts`) mirrors the root `CHANGELOG.md` into `Hex/Resources/changelog.md` so the in-app sheet always matches GitHub releases.
- The release tool consumes the pending fragments, bumps `package.json` + `Info.plist`, regenerates `CHANGELOG.md`, and feeds the resulting section to GitHub + Sparkle automatically. Releases fail fast if no changesets are queued, so you can’t forget.

## Instructions

Once you open Hex, you'll need to grant it microphone and accessibility permissions—so it can record your voice and paste the transcribed text into any application, respectively.

Once you've configured a global hotkey, there are **two recording modes**:

1. **Press-and-hold** the hotkey to begin recording, say whatever you want, and then release the hotkey to start the transcription process. 
2. **Double-tap** the hotkey to *lock recording*, say whatever you want, and then **tap** the hotkey once more to start the transcription process.
 
> 💡 **Note:** The first time you run Hex, it will auto-download the Parakeet model in the background. This is incredibly fast and optimized for the cloud—you'll be up and running in no time!

## License

This project is licensed under the MIT License. See `LICENSE` for details.
