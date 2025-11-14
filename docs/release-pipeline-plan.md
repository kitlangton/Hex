# Hex Release Pipeline - GitHub Actions Plan

## Context

Need to set up automated release pipeline for macOS app distribution via:
- **Sparkle** (in-app updates via S3)
- **Homebrew Cask** (requires ZIP artifact)
- **GitHub Releases** (visibility/download page)

## Current State

### What Works ✅
- `scripts/tool.py` - Python script, works locally
- `tools/release.ts` - TypeScript/Effect version, works locally
- Both use local notarytool keychain profile (`AC_PASSWORD`)
- Both upload to S3, generate Sparkle appcast

### What's Broken ❌
- `.github/workflows/release.yml` - Incomplete, has TODO stubs
- No ZIP creation (Homebrew needs this)
- No GitHub release integration

## Standard Approaches (2025)

### Option A: Pure GitHub Actions YAML
**How most projects do it:**
```yaml
- uses: apple-actions/import-codesign-certs@v2
- run: xcodebuild ...
- uses: lando/notarize-action@v2
- run: create-dmg ...
- uses: actions/create-release@v1
```

**Pros:** Standard, lots of examples, community actions
**Cons:** Verbose YAML, hard to test locally, logic spread across steps

### Option B: Call Local Script (What You Have)
**Use existing `release.ts` from workflow:**
```yaml
- uses: oven-sh/setup-bun@v2
- run: bun run tools/release.ts --bucket hex-updates
```

**Pros:** Test locally, type-safe, reusable, Effect composability
**Cons:** Need env var auth fallback for CI

### Option C: Hybrid
Use actions for signing/notarization, script for build/upload

## Recommended: Option B (Enhanced)

Why? You already built a complete, working TypeScript tool. Just need CI auth.

### Architecture

```
GitHub Actions Workflow
  ├─ Setup (checkout, certs, Bun)
  ├─ Call: bun run tools/release.ts
  │   ├─ Detects CI via env
  │   ├─ Uses APPLE_ID/PASSWORD instead of keychain
  │   ├─ Builds, signs, notarizes
  │   ├─ Creates DMG + ZIP
  │   ├─ Uploads to S3 (Sparkle)
  │   └─ Returns artifacts paths
  └─ Create GitHub Release (upload DMG + ZIP)
```

### Required Changes

#### 1. Modify `release.ts`
**Add CI detection:**
```typescript
const getNotarizeArgs = () => {
  if (process.env.GITHUB_ACTIONS) {
    return [
      "--apple-id", process.env.APPLE_ID!,
      "--password", process.env.APPLE_ID_PASSWORD!,
      "--team-id", process.env.TEAM_ID!
    ]
  }
  return ["--keychain-profile", "AC_PASSWORD"]
}
```

**Add ZIP creation:**
```typescript
// After DMG creation
yield* runCommandCheck("ditto", "-c", "-k", "--keepParent",
  appBundle, join(updatesDir, `Hex-${newVersion}.zip`))
```

#### 2. Update Workflow
Replace `.github/workflows/release.yml` with:
```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      version_bump:
        type: choice
        options: [patch, minor, major]
        default: patch

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Setup Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.2.app

      - name: Setup Bun
        uses: oven-sh/setup-bun@v2

      - name: Install dependencies
        run: cd tools && bun install

      - name: Import signing certificate
        env:
          MACOS_CERTIFICATE: ${{ secrets.MACOS_CERTIFICATE }}
          MACOS_CERTIFICATE_PWD: ${{ secrets.MACOS_CERTIFICATE_PWD }}
        run: |
          # Decode and import cert to default keychain
          echo "$MACOS_CERTIFICATE" | base64 --decode > /tmp/cert.p12
          security import /tmp/cert.p12 -P "$MACOS_CERTIFICATE_PWD" -A
          security set-key-partition-list -S apple-tool:,apple: -s -k "" login.keychain-db
          rm /tmp/cert.p12

      - name: Build and release
        run: bun run tools/release.ts --bucket hex-updates
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_ID_PASSWORD: ${{ secrets.APPLE_ID_PASSWORD }}
          TEAM_ID: ${{ secrets.TEAM_ID }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

      - name: Create GitHub Release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION=$(cat Hex/Info.plist | grep -A1 CFBundleShortVersionString | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
          gh release create "v$VERSION" \
            --title "Hex v$VERSION" \
            --generate-notes \
            updates/Hex-$VERSION.dmg \
            updates/Hex-$VERSION.zip
```

### Required Secrets (9)

Set via: `gh secret set SECRET_NAME`

```bash
# Apple Developer
APPLE_ID                    # your@email.com
APPLE_ID_PASSWORD          # xxxx-xxxx-xxxx-xxxx (app-specific)
TEAM_ID                     # QC99C9JE59
DEVELOPMENT_TEAM           # QC99C9JE59 (same as TEAM_ID)

# Code Signing
MACOS_CERTIFICATE          # base64 encoded .p12
MACOS_CERTIFICATE_PWD      # .p12 password

# S3 / Sparkle
AWS_ACCESS_KEY_ID          # S3 access
AWS_SECRET_ACCESS_KEY      # S3 secret

# Auto-provided
GITHUB_TOKEN               # Auto-available in actions
```

#### How to Generate

**App-specific password:**
```bash
# 1. Go to appleid.apple.com
# 2. Sign in > Security > App-Specific Passwords
# 3. Generate for "Hex GitHub Actions"
# 4. Copy xxxx-xxxx-xxxx-xxxx
```

**Certificate base64:**
```bash
# Export from Keychain Access as .p12
base64 -i DeveloperID.p12 | pbcopy
# Paste into secret
```

## Comparison: What Others Do

### Electron Apps (Sparkle, DMG)
- **VSCode**: Custom Azure Pipelines + scripts
- **Obsidian**: Electron-builder in Actions
- **Raycast**: Similar to our Option B (script from workflow)

### Native macOS Apps
- **Bartender**: Manual releases
- **Alfred**: Private infrastructure
- **Rectangle**: GitHub Actions with notarize action

**Trend:** Moving toward script-based (easier to test/debug locally)

## Homebrew Cask Setup

After first release:

```bash
# 1. Create cask
brew create --cask hex

# 2. Test
brew install --cask hex

# 3. Submit PR to homebrew/cask
# OR create personal tap: homebrew-hex
```

**Cask needs:**
- ZIP artifact (not DMG) - universal convention
- GitHub release URL
- SHA256 (auto-calculated by brew)

## Testing Strategy

### Local Testing
```bash
# Full release (dry-run flag needed?)
bun run tools/release.ts --bucket hex-updates-test

# Test specific steps
bun run tools/release.ts --skip-upload
```

### CI Testing
```bash
# Trigger workflow
gh workflow run release.yml

# Monitor
gh run list
gh run view <run-id>
```

## Migration Path

1. ✅ Modify `release.ts` - add CI auth
2. ✅ Add ZIP creation to `release.ts`
3. ✅ Replace workflow YAML
4. ✅ Set all 9 secrets
5. ✅ Test release to staging S3 bucket
6. ✅ First real release
7. ✅ Submit Homebrew cask

## ✅ IMPLEMENTED (Tag-Based Approach)

### Version Management
**Solved:** Git tags determine version
- Push `v0.2.12` → builds version `0.2.12`
- Auto-increments build number
- Updates all version files

### Configuration
**Solved:** Effect Config system
- Auto-detects CI vs local environment
- Uses keychain locally, env vars in CI
- Type-safe configuration

### Artifacts
**Solved:** Creates both DMG + ZIP
- DMG for direct download / Sparkle
- ZIP for Homebrew cask
- Both notarized and signed

## Remaining Questions

1. **Changelog:** Auto-generate from commits? (currently using `--generate-notes`)
2. **S3 bucket:** Staging bucket for pre-release testing?
3. **Rollback:** Failed notarization handling?
4. **Certificate expiry:** Track and rotate Developer ID cert

## Completed Tasks

- [x] Update `release.ts` with Effect Config
- [x] Add CI detection (Apple creds optional)
- [x] Add ZIP creation for Homebrew
- [x] Rewrite workflow for tag-based releases
- [x] Document release process
- [ ] Configure secrets (manual step)
- [ ] First release test
- [ ] Submit Homebrew cask
