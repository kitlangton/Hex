# Swift / iOS Engineering Guidelines (Hex)

House style for `HexCore` (Swift 6, strict concurrency), the macOS app (`Hex`, Swift 5 mode + TCA), and `HexIOS`. Opinionated and specific to our stack: SwiftUI + Observation, TCA, `swift-dependencies`, Swift Testing, on-device ML (WhisperKit / FluidAudio), AVFoundation. Keep new shared logic in `HexCore` and write it Swift-6-clean.

## Quick checklist (PR self-review)

- [ ] New shared logic lives in `HexCore`, not the app target. Public API surface is minimal and documented.
- [ ] No data races: cross-domain types are `Sendable`; UI/`@Observable` types are `@MainActor`; no new `@unchecked Sendable` / `nonisolated(unsafe)` without a comment justifying it.
- [ ] Side effects go through a `@DependencyClient` (clock, uuid, FS, audio, network) — never called inline in logic.
- [ ] Pure logic is separated from effects and unit-tested with **Swift Testing** (`@Test`/`#expect`), not XCTest.
- [ ] TCA reducers tested with `TestStore` (exhaustive); state & actions are `Equatable`; actions named for *what happened*.
- [ ] Platform-specific code is gated with `#if os(...)`; shared types compile on both macOS and iOS.
- [ ] Diagnostics use `HexLog` (never `print`); sensitive values use `privacy: .private`.
- [ ] A `.changeset/*.md` exists for any user-facing change (see CLAUDE.md).

---

## 1. Swift 6 Concurrency

`HexCore` is Swift 6 / complete concurrency checking. Write everything new there to that bar even though `Hex`/`HexIOS` still build in Swift 5 mode.

**Sendable — let the compiler guide you.** Value types (struct/enum of `Sendable` members) are `Sendable` for free. Don't blanket-annotate; the compiler only flags real races ([Apple migration guide](https://www.swift.org/migration/documentation/migrationguide/)).

```swift
// DO: value-type models cross actor boundaries safely
public struct Meter: Sendable, Equatable { var averagePower: Double; var peakPower: Double }

// DON'T: silence the compiler instead of fixing the race
final class Cache: @unchecked Sendable { var items: [String: Data] = [:] } // ⚠️ data race
```

**Use actors for shared mutable reference state.** Prefer an `actor` over a lock-guarded class.

```swift
// DO
actor ModelCache { private var models: [String: MLModel] = [:]
  func model(for id: String) -> MLModel? { models[id] } }
```

**Isolate UI to `@MainActor`; mark off-thread work `nonisolated`.**

```swift
@MainActor @Observable final class RecorderModel {
  var isRecording = false
  nonisolated func encode(_ buf: AVAudioPCMBuffer) -> Data { /* pure, off-main */ }
}
```

**`async`/`await` over completion handlers; `AsyncStream` for event sequences.** This is already our client style (`PermissionClient.observeAppActivation() -> AsyncStream`). Bridge legacy callbacks with `withCheckedThrowingContinuation`.

```swift
// DO: expose a stream, not a delegate
public var observeMeter: @Sendable () -> AsyncStream<Meter>
```

**Isolating legacy / non-Sendable APIs.** Use `@preconcurrency import` for frameworks not yet annotated; confine the legacy object to one actor and expose a `Sendable` surface. Treat `@unchecked Sendable` / `nonisolated(unsafe)` as a last resort that requires a justifying comment ([Approachable Concurrency, avanderlee](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)).

```swift
@preconcurrency import SomeLegacyAudioKit
```

**Swift 5 → 6 migration (per target):** flip strict-concurrency to *warnings* first (`SWIFT_STRICT_CONCURRENCY = targeted` → `complete`), migrate leaf modules before dependents (HexCore is already done — keep it that way), `@MainActor`-annotate view models, replace Combine/`@Published` with async + `@Observable`, then bump `SWIFT_VERSION` to 6.0 once warning-clean ([migration for multi-module apps](https://medium.com/@rozeri.dilar/swift-6-migration-for-multi-module-apps-015676dc1f6b), [Swift 6 strict concurrency guide](https://www.mycuppa.io/learning/swift-6-strict-concurrency-explained)).

---

## 2. SwiftUI Architecture: `@Observable` vs TCA

**Which to use:**
- **TCA reducer** — for app *features* with non-trivial state, effects, and navigation. This is the macOS app's standard (`TranscriptionFeature`, `SettingsFeature`, …). Use `@Reducer` + `@ObservableState`.
- **`@Observable` view model** — for local/leaf UI state with no shared effects (small `HexIOS` screens, isolated components). Don't introduce a parallel `@Observable` layer inside an existing TCA feature.

**Observation framework (iOS 17+ / macOS 14+), not `ObservableObject`** ([Apple Observation; nilcoalescing](https://nilcoalescing.com/blog/ObservableInSwiftUI/)):

```swift
// DO
@MainActor @Observable final class SettingsModel { var micGain: Double = 1.0 }
struct V: View { @State private var model = SettingsModel() }        // owns it
struct Child: View { @Bindable var model: SettingsModel }            // needs $bindings
func read(_ m: SettingsModel) -> some View { Text("\(m.micGain)") }  // read-only: no wrapper

// DON'T: legacy stack
class SettingsModel: ObservableObject { @Published var micGain = 1.0 } // ⚠️
@StateObject / @ObservedObject / @EnvironmentObject                    // ⚠️ avoid in new code
```

`@Observable` re-renders only views that read a changed property — keep `body` small to benefit.

**Avoid massive views.** Extract subviews and `@ViewBuilder` helpers; push logic into the reducer/model, not `body`. A view's job is to render state and send actions.

**Previews:** use `#Preview`; rely on `.dependency`/test values so previews never touch real audio/ML/FS.

---

## 3. Dependency Injection (`swift-dependencies`)

Every side effect is a client. This is *the* reason our logic is testable — see `PermissionClient`, `RecordingClient`, `TranscriptPersistenceClient`.

**Design `@DependencyClient` interfaces** as `Sendable` structs of `@Sendable` closure endpoints. Closures get safe defaults so unimplemented endpoints fail loudly in tests.

```swift
@DependencyClient
public struct RecordingClient: Sendable {
  public var start: @Sendable () async throws -> Void
  public var stop:  @Sendable () async -> URL?
  public var meter: @Sendable () -> AsyncStream<Meter> = { .finished }
}
extension RecordingClient: DependencyKey {
  public static let liveValue = RecordingClient(/* AVFoundation impl */)
  public static let testValue = RecordingClient()   // unimplemented → test fails if called unexpectedly
}
extension DependencyValues {
  public var recording: RecordingClient {
    get { self[RecordingClient.self] } set { self[RecordingClient.self] = newValue }
  }
}
```

**Consume via `@Dependency`; override in tests/previews.** Inject controllable system dependencies — `@Dependency(\.continuousClock)`, `\.uuid`, `\.date` — rather than calling `Date()`/`Task.sleep` inline ([Point-Free TCA](https://github.com/pointfreeco/swift-composable-architecture)).

```swift
@Dependency(\.recording) var recording
@Dependency(\.continuousClock) var clock
```

```swift
// DON'T
let id = UUID(); try await Task.sleep(for: .seconds(1))  // ⚠️ unmockable, slow, flaky tests
```

---

## 4. Designing Testable Code

- **Deep modules, narrow interfaces.** A client/reducer exposes a small surface over substantial behavior. Public API in `HexCore` is a contract — keep it intentional.
- **Pure logic, separated from effects.** Decision-making (e.g. `HotKeyProcessor`, word-remapping, live-preview logic) is pure and synchronous; effects (audio, FS, ML) live behind clients. Our `HexCoreTests` test exactly these pure cores fast and deterministically.
- **Inject the world.** Clock, uuid, date, randomness, network, FS — never reach for them directly inside logic.

```swift
// DO: pure decision in, effect out
func nextAction(for event: KeyEvent, at time: Double) -> HotKeyAction  // pure → trivially testable
```

---

## 5. Testing (Swift Testing)

Use **Swift Testing** (`import Testing`) for unit/logic/reducer tests — matches existing `HexCoreTests`. Keep **XCTest** only for UI tests and `measure` performance tests ([Apple Swift Testing](https://developer.apple.com/xcode/swift-testing/), [WWDC24 "Go further"](https://developer.apple.com/videos/play/wwdc2024/10195/)).

**Structure & naming:** Arrange-Act-Assert; `struct` suites (value semantics → fresh state per test); function names say behavior + scenario (`pressAndHold_startsRecordingOnHotkey_standard`).

```swift
@Suite("Word remapping")
struct WordRemappingTests {
  @Test("applies longest match first")
  func appliesLongestMatch() {
    let out = remap("hello world", rules: [...])   // Arrange + Act
    #expect(out == "hi world")                       // Assert
  }
}
```

**`#expect` vs `#require`:** `#expect` records and continues; `#require` (throws) halts when later steps depend on the value.

```swift
let url = try #require(client.lastSavedURL)   // stop if nil
#expect(url.pathExtension == "wav")
```

**Parameterized tests** instead of loops/copy-paste; `zip` to avoid a Cartesian blowup.

```swift
@Test(arguments: [Flavor.vanilla, .chocolate, .mintChip])
func hasNoNuts(_ f: Flavor) { #expect(!f.containsNuts) }
```

**Async / callbacks:** `await` directly; use `confirmation(expectedCount:)` for callbacks fired N times; bridge legacy callbacks with continuations.

**Traits & tags:** `.disabled("reason")`, `.enabled(if:)`, `@Tag` for cross-suite slices (e.g. `.tags(.ml)` for slow model tests), `.serialized` only when state truly can't parallelize ([Test Traits, jano.dev](https://jano.dev/apple/swift/2025/02/24/Scoping-Traits.html)).

**Testing TCA reducers — `TestStore`, exhaustive:** assert every state mutation and effect; override deps; drive time with a test clock. Make `State`/`Action` `Equatable`.

```swift
@Test func startRecording() async {
  let clock = TestClock()
  let store = TestStore(initialState: TranscriptionFeature.State()) { TranscriptionFeature() }
    withDependencies: { $0.recording = .testValue; $0.continuousClock = clock }
  await store.send(.recordButtonTapped) { $0.isRecording = true }
  await clock.advance(by: .seconds(1))
  await store.receive(\.meterUpdated) { $0.meter = .init(averagePower: 1, peakPower: 1) }
}
```

**Flake-free & fast:** no real sleeps, network, or disk — inject `TestClock` and test values. Tests run in parallel and in random order, which surfaces hidden state coupling; don't fight it with shared global state.

**What to test / not:** test pure logic, reducer behavior, client wiring, edge cases & error paths. Don't test SwiftUI layout, the framework itself, or trivial getters. Put sample audio/JSON under `Tests/HexCoreTests/Fixtures` (already wired via `.copy("Fixtures")`).

```swift
// DON'T
@Test func slow() async throws { try await Task.sleep(for: .seconds(2)) } // ⚠️ flaky + slow
```

---

## 6. Core Swift Style

**Errors:** typed `enum` errors conforming to `Error`; `throws` for recoverable failures; reserve optionals for "absent," not "failed." Avoid `try?` that swallows context — log via `HexLog` if you discard.

```swift
public enum TranscriptionError: Error, Equatable { case modelMissing(String), audioTooShort }
```

**Optionals:** prefer `guard let … else { return }` early exits; never force-unwrap (`!`) outside tests/`#require`.

**Value vs reference:** default to `struct`/`enum`. Use `class`/`actor` only for identity or shared mutable state; make reference types `final`.

**Access control / module boundaries:** default `internal`; mark `public` only deliberately in `HexCore` — every `public` symbol is API you must keep working. Use `private`/`fileprivate` aggressively inside features.

**Naming ([Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)):** clarity at the call site; methods read as phrases (`remove(at:)`); booleans assert (`isRecording`); avoid abbreviations & redundant type names. TCA actions describe *what happened* (`didTapRecord`), not the effect (`startRecording`).

---

## 7. Project-Specific Conventions

**Keep shared logic in `HexCore`.** Anything used by both `Hex` and `HexIOS`, or any pure logic, belongs in the package — it's Swift 6 and unit-tested. The app targets are thin shells (UI + platform glue).

**Platform gating** with `#if os(...)`. Provide a shim so shared types compile everywhere (pattern: `HexKeyCompat.swift` — an iOS stand-in `Key` mirroring Sauce's wire format so `HexSettings` round-trips identically). Gate macOS-only deps in `Package.swift` with `.when(platforms:)`, as Sauce/IOKit already are.

```swift
#if os(macOS)
import Sauce            // Carbon keyboard lib, macOS-only
#else
// Key shim stands in (Models/HexKeyCompat.swift)
#endif
```

**Public API discipline:** when adding to `HexCore`, ask "does this need to be `public`?" Document public types with `///` (see `PermissionClient`). Preserve Codable wire formats for settings — they sync across platforms.

**Logging:** `HexLog.<category>` only; `privacy: .private` for transcript text and file paths (CLAUDE.md). No `print`.

---

### Sources
- [Apple — Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) · [Swift.org Migration Guide](https://www.swift.org/migration/documentation/migrationguide/)
- [Apple — Swift Testing](https://developer.apple.com/xcode/swift-testing/) · [WWDC24: Go further with Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10195/) · [swiftlang/swift-testing](https://github.com/swiftlang/swift-testing)
- [Point-Free — Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) · [TCA Best Practices, Krzysztof Zabłocki](https://www.merowing.info/the-composable-architecture-best-practices/)
- [Approachable Concurrency in Swift 6.2 — Antoine van der Lee](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/) · [@Observable performance — avanderlee](https://www.avanderlee.com/swiftui/observable-macro-performance-increase-observableobject/)
- [Swift 6 Strict Concurrency Explained](https://www.mycuppa.io/learning/swift-6-strict-concurrency-explained) · [Swift 6 Migration for Multi-Module Apps](https://medium.com/@rozeri.dilar/swift-6-migration-for-multi-module-apps-015676dc1f6b)
- [Using @Observable in SwiftUI views — Nil Coalescing](https://nilcoalescing.com/blog/ObservableInSwiftUI/) · [Swift Testing Test Traits — jano.dev](https://jano.dev/apple/swift/2025/02/24/Scoping-Traits.html)
