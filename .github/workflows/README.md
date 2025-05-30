# GitHub Actions Workflows for Hex

This directory contains the CI/CD workflows for the Hex project.

## Workflows

### 1. CI (`ci.yml`)
- **Trigger**: On every push to main and pull requests
- **Purpose**: Continuous integration for code quality
- **Jobs**:
  - Swift linting with SwiftLint
  - Build and test in both Debug and Release configurations
  - Caches Swift Package Manager dependencies

### 2. Build and Release (`build-and-release.yml`)
- **Trigger**: On push to main and on version tags (v*)
- **Purpose**: Build, test, and create releases
- **Jobs**:
  - Build and test the app
  - Create release artifacts when a tag is pushed
  - Generate DMG installer
  - Create GitHub release with changelog

### 3. Manual Release (`release.yml`)
- **Trigger**: Manual workflow dispatch
- **Purpose**: Create signed and notarized releases
- **Inputs**:
  - Version number (e.g., 0.2.4)
  - Build number (e.g., 37)
- **Features**:
  - Code signing and notarization
  - DMG creation
  - Sparkle appcast update support

## Required Secrets

For the release workflows to work properly, you need to configure these secrets in your GitHub repository:

### For Code Signing (release.yml)
- `MACOS_CERTIFICATE`: Base64 encoded .p12 certificate
- `MACOS_CERTIFICATE_PWD`: Password for the certificate
- `KEYCHAIN_PWD`: Password for the temporary keychain
- `DEVELOPMENT_TEAM`: Your Apple Developer Team ID (QC99C9JE59)

### For Notarization (release.yml)
- `APPLE_ID`: Your Apple ID email
- `APPLE_ID_PASSWORD`: App-specific password for notarization
- `TEAM_ID`: Your Apple Team ID

### For Sparkle Updates (optional)
- `AWS_ACCESS_KEY_ID`: For uploading to S3
- `AWS_SECRET_ACCESS_KEY`: For uploading to S3
- `SPARKLE_PRIVATE_KEY`: For signing Sparkle updates

## Usage

### Creating a Release

1. **Using Tags** (Recommended for releases):
   ```bash
   git tag v0.2.4
   git push origin v0.2.4
   ```
   This will trigger the build-and-release workflow.

2. **Manual Release** (For signed/notarized releases):
   - Go to Actions → Release → Run workflow
   - Enter version and build numbers
   - The workflow will handle signing, notarization, and release creation

### Setting Up Secrets

1. Go to Settings → Secrets and variables → Actions
2. Add each required secret

To create the certificate secret:
```bash
# Export your Developer ID certificate from Keychain Access as .p12
# Then convert to base64:
base64 -i certificate.p12 | pbcopy
```

### Sparkle Integration

The workflows include placeholders for Sparkle appcast updates. To enable:

1. Set up your S3 bucket for hosting updates
2. Configure AWS credentials as secrets
3. Implement the appcast update logic in the workflow

## Notes

- The CI workflow runs on every push and PR for quick feedback
- Release builds are only created for version tags or manual triggers
- All builds target macOS 15+ and Apple Silicon
- SwiftLint is configured but set to continue on error to avoid blocking PRs