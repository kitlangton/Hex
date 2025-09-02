# Repository Guidelines

## Project Structure & Module Organization
- Root app code lives in `Hex/`:
  - `App/` (`HexApp.swift`, `HexAppDelegate.swift`), `Assets.xcassets`, `Info.plist`, `Hex.entitlements`.
  - `Features/` (TCA features, e.g., `Transcription`, `History`).
  - `Clients/` (side‑effect wrappers, e.g., `PasteboardClient.swift`, `RecordingClient.swift`).
  - `Models/`, `Views/`, `Resources/` (audio, changelog, localization), `Preview Content/`.
- Tests are in `HexTests/` (uses Swift Testing via `import Testing`, `@Test`).
- Xcode project: `Hex.xcodeproj` (targets: `Hex`, `HexTests`).

## Build, Test, and Development Commands
- Open in Xcode: `open Hex.xcodeproj`.
- Debug build: `xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug build`.
- Run tests (macOS): `xcodebuild test -project Hex.xcodeproj -scheme Hex -destination "platform=macOS"`.
- Lint: `swiftlint` (config at `.swiftlint.yml`).
- Release (installs to `/Applications`): `bash ./build_release.sh`.

## Coding Style & Naming Conventions
- Swift, 2‑space indentation; types `UpperCamelCase`, methods/properties `lowerCamelCase`.
- TCA pattern: prefer `@Reducer` with nested `State` and `Action`; keep side effects in `Clients/` and inject via `Dependencies`.
- File names match primary type (e.g., `HistoryFeature.swift`, `PasteboardClient.swift`, `InvisibleWindow.swift`).
- SwiftLint rules enforced (see `.swiftlint.yml`): practical line length (150 warn/200 err), function/file length caps, cyclomatic complexity checks. Run lint before pushing.

## Testing Guidelines
- Use Swift Testing (`import Testing`, `@Test`). Add tests in `HexTests/`.
- Name tests for behavior, e.g., `pressAndHold_stopsRecordingOnHotkeyRelease()`.
- Prefer deterministic tests; inject time/dependencies with `withDependencies { $0.date.now = ... }`.
- Run locally with the `xcodebuild test` command above.

## Commit & Pull Request Guidelines
- Commits: imperative, scoped, concise. Optional prefix (`feat:`, `fix:`, `chore:`). Examples: `fix: clean up state on cancel`, `refactor: simplify RecordingClient`.
- Branches: `feature/...`, `fix/...`, or `release/vX.Y.Z`.
- PRs: clear description, linked issues, screenshots/GIFs for UI changes, test plan (commands run), and note any migrations/entitlement changes.

## Security & Configuration Tips
- macOS app with microphone and accessibility permissions; avoid committing secrets or signing identities.
- Entitlements live in `Hex/Hex.entitlements`. Release script performs ad‑hoc signing; adjust if using a real team identity.
