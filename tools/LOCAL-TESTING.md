# Local Testing Guide

## ✅ Committed & Safe

**Security audit passed:**
- ✅ No hardcoded secrets
- ✅ No API keys
- ✅ No passwords
- ✅ Only configuration code

## Dual Mode Support

The release tool automatically detects your environment:

### 🏠 Local Mode (No Env Vars Needed)

```bash
cd tools
bun run release.ts
```

**Uses:**
- ✅ **Apple credentials:** AC_PASSWORD keychain profile
- ✅ **AWS credentials:** ~/.aws/credentials (from `aws configure`)
- ✅ **Version:** Auto-bumps patch version

**Perfect for testing the full release pipeline locally!**

### ☁️ CI Mode (GitHub Actions)

```bash
VERSION=v0.2.12 \
  APPLE_ID="your@email.com" \
  APPLE_ID_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
  TEAM_ID="QC99C9JE59" \
  AWS_ACCESS_KEY_ID="..." \
  AWS_SECRET_ACCESS_KEY="..." \
  bun run release.ts
```

**Uses:**
- ✅ Explicit credentials from env vars
- ✅ Version from git tag

## Test Without Uploading

If you want to test build/sign/notarize without uploading to S3:

1. **Comment out S3 uploads** in `release.ts` (lines 504-509)
2. **Or use a test bucket:**
   ```bash
   BUCKET=hex-updates-test bun run release.ts
   ```

## Quick Test Command

```bash
# Test with specific version (doesn't modify git)
VERSION=v0.2.11-test bun run release.ts
```

This will:
1. ✅ Build Hex
2. ✅ Sign with your Developer ID
3. ✅ Notarize with Apple (uses AC_PASSWORD)
4. ✅ Create DMG + ZIP
5. ✅ Upload to S3 (uses ~/.aws/credentials)
6. ✅ Generate Sparkle appcast

## Cleanup

Artifacts are created in:
- `build/` - Build artifacts
- `updates/` - Final DMG + ZIP + appcast.xml

To clean:
```bash
rm -rf build/ updates/
```
