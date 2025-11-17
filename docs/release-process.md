# Hex Release Process

## Overview

Releases are triggered by pushing git tags. The system automatically:
- Builds & signs the app
- Notarizes with Apple
- Creates DMG + ZIP artifacts
- Uploads to S3 for Sparkle updates
- Creates GitHub release

## Quick Start

```bash
# Create and push a tag
git tag v0.2.12
git push origin v0.2.12

# GitHub Actions will automatically:
# 1. Build Hex v0.2.12
# 2. Notarize with Apple
# 3. Upload to S3 (Sparkle)
# 4. Create GitHub release with DMG + ZIP
```

## Architecture

**Tag-based versioning:**
- Tag `v0.2.12` → builds version `0.2.12`
- Updates `Info.plist` and `project.pbxproj`
- Auto-increments build number

**Effect Config system:**
```typescript
// Reads from environment variables
BUCKET=hex-updates              // Default
VERSION=v0.2.12                  // From git tag
APPLE_ID=your@email.com         // CI only
APPLE_ID_PASSWORD=xxxx-xxxx     // CI only
AWS_ACCESS_KEY_ID=...           // Required
AWS_SECRET_ACCESS_KEY=...       // Required
```

**Local vs CI:**
- **Local**: Uses keychain profile `AC_PASSWORD`
- **CI**: Uses `APPLE_ID` / `APPLE_ID_PASSWORD` env vars

## Local Testing

```bash
# Setup keychain profile (one-time)
xcrun notarytool store-credentials "AC_PASSWORD"

# Test release locally (doesn't upload)
cd tools
VERSION=v0.2.12-test \
  AWS_ACCESS_KEY_ID=... \
  AWS_SECRET_ACCESS_KEY=... \
  bun run release.ts
```

## Required Secrets

Set via: `gh secret set SECRET_NAME`

### Apple (Notarization)
```bash
APPLE_ID                    # your@email.com
APPLE_ID_PASSWORD          # App-specific password from appleid.apple.com
TEAM_ID                     # QC99C9JE59
```

### Code Signing
```bash
MACOS_CERTIFICATE          # base64 -i cert.p12 | pbcopy
MACOS_CERTIFICATE_PWD      # Certificate password
```

### AWS (S3 / Sparkle)
```bash
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

## Artifacts

Each release creates:
- `Hex-{version}.dmg` - Signed, notarized DMG
- `Hex-{version}.zip` - For Homebrew cask
- `hex-latest.dmg` - Always points to latest
- `appcast.xml` - Sparkle update feed

## Homebrew Cask

After first release, update `hex.rb`:

```bash
# Get SHA256
curl -L https://github.com/kitlangton/Hex/releases/download/v0.2.12/Hex-v0.2.12.zip -o Hex.zip
shasum -a 256 Hex.zip

# Update hex.rb with version and SHA
```

Submit to:
- **Personal tap**: `homebrew-hex` (easier)
- **Official cask**: PR to `homebrew/homebrew-cask`

## Critical Constraints

### CFBundleVersion Requirements

**NEVER manually edit CFBundleVersion or reuse build numbers.** The release pipeline automatically increments CFBundleVersion with each release to ensure Sparkle can properly generate the appcast feed.

- `updates/` directory must only contain DMGs with strictly increasing CFBundleVersion values
- Duplicate build numbers will block appcast generation and break updates for existing users
- The release script preserves the last 3 DMGs in `updates/` for delta generation
- Older versions are automatically moved to `updates/old_updates/`

If you accidentally create a release with a duplicate CFBundleVersion:
1. Delete the problematic DMG from `updates/`
2. Move any other old DMGs to `updates/old_updates/`
3. Regenerate appcast: `./bin/generate_appcast --maximum-deltas 3 updates`
4. Re-upload cleaned artifacts to S3

## Troubleshooting

### Notarization fails
- Check Apple ID credentials
- Verify app-specific password
- Ensure `TEAM_ID` is correct

### S3 upload fails
- Verify AWS credentials
- Check bucket permissions
- Ensure bucket exists

### Build fails
- Check Xcode version (16.2)
- Verify code signing setup
- Check certificate validity

### Sparkle updates not appearing
- Verify appcast.xml lists versions in descending CFBundleVersion order
- Check that CFBundleVersion values are unique and strictly increasing
- Ensure no duplicate build numbers exist in updates/
- Test feed URL: https://hex-updates.s3.amazonaws.com/appcast.xml

## Files

- `tools/release.ts` - Main release script (Effect)
- `.github/workflows/release.yml` - CI workflow
- `bin/generate_appcast` - Sparkle appcast generator
- `hex.rb` - Homebrew cask formula
