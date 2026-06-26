# [P0-1] Make HexCore `Package.swift` multiplatform

- **Phase:** 0 — Multiplatform HexCore
- **Depends on:** —
- **Blocks:** P0-2, P0-3, P0-4, X-2
- **Size:** S
- **Risk:** Low

## Goal
HexCore declares both macOS and iOS, with macOS-only deps/frameworks linked
conditionally, so the package can later compile for iOS.

## Tasks
- [ ] `platforms: [.macOS(.v14), .iOS(.v17)]`.
- [ ] Keep the `Sauce` package dependency, but link only on macOS:
      `.product(name: "Sauce", package: "Sauce", condition: .when(platforms: [.macOS]))`.
- [ ] `IOKit` framework macOS-only: `.linkedFramework("IOKit", .when(platforms: [.macOS]))`.
- [ ] (Coordinated with P0-4) prepare to add WhisperKit + FluidAudio deps.

## Acceptance criteria
- [ ] `swift build` succeeds on macOS.
- [ ] Package resolves for an iOS destination (compile errors from un-gated code are
      expected and handled in P0-2/P0-3 — this issue is just the manifest).

## Files
- `HexCore/Package.swift`
