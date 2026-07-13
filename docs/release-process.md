# GitHub Release Process

Hex publishes downloadable installers through GitHub Releases. There is no S3 upload or in-app update feed.

## One-time repository setup

Add these GitHub Actions secrets under **Settings → Secrets and variables → Actions**:

- `MACOS_CERTIFICATE`: base64-encoded Developer ID Application `.p12`
- `MACOS_CERTIFICATE_PWD`: password for that certificate
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_ID_PASSWORD`: Apple app-specific password
- `TEAM_ID`: Apple Developer Team ID (`QC99C9JE59` for this project)

The same Apple certificate and notarization credentials can be used for another app, but GitHub secrets must be added to this repository separately. Never commit certificates, passwords, or API keys.

## Publish a release

Create and push a version tag:

```bash
git tag v0.8.4
git push origin v0.8.4
```

The `.github/workflows/release.yml` workflow will:

1. Import the Developer ID certificate.
2. Archive and export the Release app.
3. Submit the app to Apple notarization and staple the ticket.
4. Create a DMG and ZIP installer.
5. Attach both installers to the GitHub Release.

The workflow can also be run manually for an existing tag from the GitHub Actions tab.
