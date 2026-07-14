# GitHub Releases

`release.yml` publishes notarized Hex installers directly to GitHub Releases. It runs when a `v*` tag is pushed or from Actions with an existing tag.

Configure these repository Actions secrets once. They are the same kinds of values used by other signed macOS apps; the values themselves never belong in this repository:

- `MACOS_CERTIFICATE`: base64-encoded Developer ID Application `.p12`
- `MACOS_CERTIFICATE_PWD`: certificate password
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_ID_PASSWORD`: Apple app-specific password
- `TEAM_ID`: Apple Developer Team ID (`QC99C9JE59` for the current project)

To publish, create and push a version tag:

```bash
git tag v0.8.4
git push origin v0.8.4
```

The workflow archives the app, notarizes and staples it, creates a DMG and ZIP, and attaches both files to the GitHub Release. It does not upload to S3 and does not maintain an appcast.
