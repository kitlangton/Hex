# Hex Build Tools (Effect/TypeScript)

Modern TypeScript/Effect implementation of Hex build and release automation with proper service-oriented architecture.

## Prerequisites

### 1. Notarization credentials
```bash
xcrun notarytool store-credentials "AC_PASSWORD"
```

### 2. AWS credentials
```bash
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret
```

### 3. Dependencies
```bash
cd tools
bun install
```

## CLI Usage

The tool provides a CLI with multiple commands:

### Check Current Version
```bash
bun run src/cli.ts version
```

Output:
```
Version: 0.2.10
Build: 43
```

### List S3 Versions
```bash
bun run src/cli.ts list [--prefix Hex-]
```

Lists all available versions in S3 with download URLs and metadata.

### Release (Full Pipeline)
```bash
bun run src/cli.ts release [--bump patch|minor|major]
```

Runs the complete release pipeline:
1. Bumps version (default: patch)
2. Increments build number
3. **Cleans DerivedData** (prevents stale entitlements!)
4. Archives with xcodebuild
5. Exports and signs with Developer ID
6. Notarizes app
7. Creates and signs DMG
8. Notarizes DMG
9. Generates Sparkle appcast
10. Uploads to S3 (versioned + latest)

### Global Options

All commands accept:
- `--bucket`: S3 bucket name (default: hex-updates)
- `--region`: AWS region (default: us-east-1)
- `--scheme`: Xcode scheme (default: Hex)
- `--plist`: Path to Info.plist (default: Hex/Info.plist)
- `--export-options`: Export options plist (default: ExportOptions.plist)

Example:
```bash
bun run src/cli.ts release --bucket my-bucket --region us-west-2 --bump minor
```

## Architecture

### Services (Dependency Injection)

The codebase uses **proper Effect services** with Context/Layer pattern:

```
src/
├── services/          # Service interfaces (Tags)
│   ├── Config.ts       - Configuration service
│   ├── S3.ts           - AWS S3 operations
│   ├── VersionManager.ts - Version/build number management
│   ├── XcodeBuild.ts   - Xcode build operations
│   └── CodeSign.ts     - Signing and notarization
│
├── layers/            # Service implementations (Layers)
│   ├── S3Live.ts
│   ├── VersionManagerLive.ts
│   ├── XcodeBuildLive.ts
│   ├── CodeSignLive.ts
│   └── index.ts        - Layer composition
│
├── commands/          # CLI commands
│   ├── version.ts
│   ├── list.ts
│   └── release.ts
│
└── cli.ts            # CLI entry point
```

### Why This Architecture?

**Before (release.ts):**
```typescript
// ❌ Direct instantiation, no DI
const client = new S3Client({ region })
const content = await readFile(filePath)  // Node.js directly
```

**After (Services + Layers):**
```typescript
// ✅ Proper service dependency injection
class S3 extends Context.Tag("hex/S3")<S3, S3>() {}

const S3Live = Layer.effect(S3, Effect.gen(function* () {
  const config = yield* Config
  const fs = yield* FileSystem.FileSystem
  // ...
}))

// Usage in commands
const upload = Effect.gen(function* () {
  const s3 = yield* S3  // Injected!
  yield* s3.upload(path, key)
})
```

### Benefits

1. **Testability**: Mock services easily
```typescript
const S3Test = Layer.succeed(S3, {
  upload: () => Effect.void,
  listVersions: () => Effect.succeed([]),
  // ...
})
```

2. **Composition**: Services compose declaratively
```typescript
const AppLayer = Layer.mergeAll(
  S3Live,
  VersionManagerLive,
  XcodeBuildLive,
  CodeSignLive
)
```

3. **Type Safety**: All dependencies tracked at compile time
```typescript
// Effect<void, Error, S3 | VersionManager>
//                     ^--- Dependencies visible in type
```

4. **No Escape Hatches**: No `process.exit()`, all errors as Effects

## Key Improvements Over Python Version

### 1. Explicit DerivedData Cleaning
```typescript
// Before: xcodebuild clean archive (didn't clean DerivedData)
// After: rm -rf DerivedData && xcodebuild clean archive
```
Fixes the stale entitlements caching bug!

### 2. Service-Oriented Architecture
- Config is a service (not imperative parsing)
- All platform operations through Effect services
- Proper dependency injection
- Fully testable/mockable

### 3. Type Safety
- AWS SDK v3 (fully typed)
- Effect platform services (FileSystem, Command, Path)
- No `any` in production code
- Compile-time dependency checking

### 4. Structured Concurrency
Effect handles parallelism, cancellation, resource cleanup automatically.

## Effect Stack

- **effect**: Core runtime, Context, Layer
- **@effect/platform**: Command, FileSystem, Path (cross-platform)
- **@effect/platform-node**: Node.js implementations
- **@effect/cli**: Type-safe CLI with subcommands
- **@effect/schema**: Runtime validation (not used yet, but available)

## Development

### Adding a New Command

1. Create command file in `src/commands/`
2. Use services via Context.Tag
3. Add to `hexCommand` subcommands in `cli.ts`

Example:
```typescript
// src/commands/download.ts
export const downloadCommand = Command.make(
  "download",
  { version: Args.text({ name: "version" }) },
  ({ version }) =>
    Effect.gen(function* () {
      const s3 = yield* S3
      yield* s3.download(`Hex-${version}.dmg`, "./downloads")
    })
)
```

### Adding a New Service

1. Define interface + Tag in `src/services/`
2. Implement Layer in `src/layers/`
3. Add to `AllServicesLive` in `layers/index.ts`

## Troubleshooting

### "Service not found" error
Ensure all layers are provided:
```typescript
const appLayer = AllServicesLive.pipe(
  Layer.provide(configLayer),
  Layer.provideMerge(NodeContext.layer)
)
```

### S3 upload fails
Check AWS credentials:
```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
```

### Build fails
Run from project root, not tools folder:
```bash
cd /path/to/Hex
bun run tools/src/cli.ts release
```
