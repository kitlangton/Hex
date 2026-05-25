# HexCoach — v1 Design Document

**Status:** Draft
**Owner:** Conglei
**Last updated:** 2026-05-13
**Repo (planned):** `github.com/<you>/HexCoach`
**Upstream:** `github.com/kitlangton/Hex` (MIT)

---

## 0. Repo-grounded notes

This revision corrects technical claims from the original draft against the actual Hex codebase. Significant changes:

- **Code lives in `Hex/Features/Coach/` and `Hex/Clients/`**, not `Sources/Coach/`. Hex uses an app target (`Hex/`) plus a Swift package (`HexCore/`), not a flat `Sources/` layout.
- **Audio is WAV** (16 kHz, mono, float32), not `.m4a`.
- **Hex already persists audio post-transcription** via `TranscriptPersistenceClient` under `~/Library/Application Support/Hex/Recordings/`. HexCoach does not need to add audio retention; it reuses the existing files. Open Question #1 in the original draft is now resolved.
- **No `recordingCompleted` event needs to be added** to `TranscriptionFeature`. CoachFeature observes `@Shared(.transcriptionHistory)` for new entries instead. This drops upstream modifications from ~4 files to ~2.
- **No Keychain access exists in Hex today**; HexCoach must add the `com.apple.security.keychain` entitlement.
- **Settings use a single `HexSettings` struct** via `@Shared(.hexSettings)` + `.fileStorage`. UserDefaults is not used; coach fields are added as a nested struct.
- **Unified logging via `HexLog`** is mandatory per CLAUDE.md; coach code adds `case coach` and uses `HexLog.coach` rather than `print`.
- **Changeset workflow inherited from upstream:** `bun run changeset:add-ai patch "…"` for every user-facing change.

---

## 1. Summary

HexCoach is a **fork of Hex** that adds an AI English-pronunciation coach to the existing voice-to-text workflow. The user dictates as they normally would; if the recording is longer than a configurable threshold, HexCoach sends the captured audio to a cloud LLM (Gemini or OpenAI) and surfaces concise, actionable pronunciation feedback in the menu bar and as a macOS notification.

Everything Hex already does — hotkey-driven dictation, Parakeet/WhisperKit transcription, auto-paste — is preserved. HexCoach is additive.

## 2. Goals (v1)

1. **Zero-effort feedback.** Users keep dictating exactly the way they do in Hex. The coach runs in the background when recordings exceed the configured duration.
2. **High-quality feedback for ESL speakers.** Three to five concrete, actionable suggestions per session — not generic "work on intonation" advice.
3. **Bring-your-own-key (BYOK).** Users provide their own Gemini or OpenAI API key. No HexCoach-operated backend in v1.
4. **Mac-only, Apple Silicon-only.** Same constraints as upstream Hex (macOS 14+, Xcode 16+).
5. **First-class transparency.** Clear in-app disclosure that audio leaves the device when the coach is enabled (Hex is private-by-default; the fork must not hide this change).
6. **Survives upstream tracking.** Architected so rebasing on Hex `main` doesn't constantly break.

## 3. Non-Goals (v1)

- Local / on-device LLM analysis (deferred to v2; tracked in Open Questions).
- Languages other than English-as-target.
- Anki export, spaced repetition, drills (v2).
- Cross-platform support (Windows, Linux).
- A hosted / managed backend with HexCoach's own keys.
- Real-time / live coaching during the recording — feedback is post-recording only.

## 4. Relationship to Upstream Hex

The hardest part of this project is not the code; it's the long-term relationship to upstream. The fork must be a *good citizen* and minimize confusion.

### 4.1 Attribution

- README opens with: *"HexCoach is a fork of [Hex](https://github.com/kitlangton/Hex) by Kit Langton, adding an AI English pronunciation coach to Hex's voice-to-text flow. All credit for the underlying app belongs to Kit."*
- LICENSE retains the original MIT notice. A `NOTICE.md` documents the fork point (commit SHA) and modifications.
- App icon and bundle identifier are distinct. Upstream bundle is `com.kitlangton.Hex`; HexCoach uses **`com.conglei.HexCoach`**. Menu bar icon visually differentiated so a user with both installed can tell them apart.

### 4.2 Naming and discoverability

- Working name **HexCoach**. The README is explicit that this is a fork, not the original Hex.
- App display name: "HexCoach". Tagline: "Hex + an AI pronunciation coach."
- Homebrew cask name: `hexcoach` (not `kitlangton-hex`).
- Sparkle update feed uses HexCoach's own S3 / hosting. Upstream's `SUFeedURL` in [Hex/Info.plist](../Hex/Info.plist) currently points at `https://hex-updates.s3.amazonaws.com/appcast.xml`; HexCoach **must** replace this with its own feed URL before shipping.
- Avoid posting HexCoach to channels where it'd be mistaken for an official Hex feature. Where ambiguity is possible, lead with "Fork of Hex —".

### 4.3 Upstream tracking strategy

- `main` branch tracks our fork's release line.
- `upstream-main` branch mirrors Hex's `main`. Synced weekly.
- Merge from `upstream-main` into `main` on a planned cadence (~every 2 weeks, or after each Hex release).
- All HexCoach-specific changes live in a small, well-named set of files (see §6) to minimize merge conflicts. Most code is **net-new under `Hex/Features/Coach/` and `Hex/Clients/Coach*.swift`**, which touches no upstream files. The few upstream-file edits are additive and localized.
- Where a HexCoach change is also useful to upstream Hex (bug fixes, perf improvements, refactors that don't depend on the coach), open a small targeted PR to Hex. Do not bundle our coach feature into upstream PRs.

### 4.4 What we don't change in upstream code (if avoidable)

- TCA reducers we don't own.
- The `Transcript` schema in `@Shared(.transcriptionHistory)`.
- Existing `HexSettings` fields (we add fields; we don't reshape existing ones).
- Hotkey handling.
- `RecordingClient` and `TranscriptionFeature` (CoachFeature observes shared state instead of being wired into the transcription pipeline).

When we must modify upstream files (compose a child reducer, host a new settings panel, add a log category), we add the **smallest possible** additive hook rather than weaving coach logic through the reducer.

### 4.5 Privacy disclosure (critical)

Hex is on-device-first. A fork that sends audio to a cloud LLM **must not** silently invert that posture. Therefore:

- Coach is **disabled by default**. The user must enable it during onboarding or in Settings.
- The enable flow shows: "Enabling the coach uploads your dictated audio to {provider}. Audio is sent only when recordings exceed {threshold}s. See Privacy →."
- A privacy page in Settings shows: which provider is configured, what is sent (audio + intended transcript + L1/target accent), what is *not* sent (clipboard contents, other app data, microphone outside an active recording), and a link to the provider's privacy policy.
- The menu bar icon shows a small distinct badge ("●") when the coach is enabled, so the user is always aware.
- Current entitlements in [Hex/Hex.entitlements](../Hex/Hex.entitlements) are listed in §10; HexCoach adds exactly one new entitlement (`com.apple.security.keychain`).

## 5. User Stories

1. **Sarah (Mandarin L1, software engineer)** dictates code comments and Slack messages all day with HexCoach. Each evening she opens the menu bar, sees a 30-second digest of the day's pronunciation patterns, and notices she's been mispronouncing "specific" as "pacific" — she practices it the next morning.
2. **Diego (Spanish L1)** turns the coach off when he's in deep work mode and only enables it when he wants feedback before a presentation. He uses Hex's existing UX and just toggles the coach via a menu bar switch.
3. **Aiko (privacy-conscious)** tries HexCoach but is uncomfortable with cloud uploads. She sees the in-app disclosure, decides not to enable the coach, and continues using HexCoach as a drop-in Hex (which is a fine outcome).
4. **Open-source contributor** wants to add an Anthropic provider. They open `Hex/Clients/Providers/`, copy `GeminiProvider.swift`, implement the protocol, register it. PR merged.

## 6. Architecture

### 6.1 Components inherited from Hex (unchanged behavior)

| Component | Role | Source |
|---|---|---|
| `AppFeature` | Root TCA reducer | [Hex/Features/App/AppFeature.swift](../Hex/Features/App/AppFeature.swift) |
| `TranscriptionFeature` | Recording + ASR coordination | [Hex/Features/Transcription/TranscriptionFeature.swift](../Hex/Features/Transcription/TranscriptionFeature.swift) |
| `RecordingClient` | `AVAudioRecorder` wrapper (writes WAV) | [Hex/Clients/RecordingClient.swift](../Hex/Clients/RecordingClient.swift) |
| `TranscriptionClient` | WhisperKit / FluidAudio | `Hex/Clients/TranscriptionClient.swift` |
| `HistoryFeature` | Transcript history | [Hex/Features/History/HistoryFeature.swift](../Hex/Features/History/HistoryFeature.swift) |
| `TranscriptPersistenceClient` | Moves audio to app-support, writes JSON | [HexCore/Sources/HexCore/TranscriptPersistenceClient/TranscriptPersistenceClient.swift](../HexCore/Sources/HexCore/TranscriptPersistenceClient/TranscriptPersistenceClient.swift) |
| `@Shared(.transcriptionHistory)` | File-backed shared state holding all completed `Transcript` rows | declared via HexCore + HistoryFeature |
| `PasteboardClient` | Clipboard ops; canonical example of a `@DependencyClient` | [Hex/Clients/PasteboardClient.swift](../Hex/Clients/PasteboardClient.swift) |
| `KeyEventMonitorClient` | Global hotkey via Sauce | `Hex/Clients/KeyEventMonitorClient.swift` |
| `SettingsFeature` | User preferences | [Hex/Features/Settings/SettingsFeature.swift](../Hex/Features/Settings/SettingsFeature.swift) |
| `HexSettings` | Single Codable struct, persisted via `@Shared(.hexSettings) + .fileStorage(.hexSettingsURL)` | [HexCore/Sources/HexCore/Settings/HexSettings.swift](../HexCore/Sources/HexCore/Settings/HexSettings.swift) |
| `HexLog` | Unified `os.Logger` wrapper with category enum | [HexCore/Sources/HexCore/Logging.swift](../HexCore/Sources/HexCore/Logging.swift) |

### 6.2 New components (HexCoach-specific)

| Component | File |
|---|---|
| `CoachFeature` (TCA reducer: enabled, in-flight, history) | `Hex/Features/Coach/CoachFeature.swift` |
| `CoachPopoverView` (SwiftUI: latest feedback + history) | `Hex/Features/Coach/CoachPopoverView.swift` |
| `CoachSettingsView` (SwiftUI: provider, key, profile, threshold, privacy panel) | `Hex/Features/Coach/CoachSettingsView.swift` |
| `CoachClient` (`@DependencyClient`: takes `(audioURL, transcript, profile)` → `Feedback`) | `Hex/Clients/CoachClient.swift` |
| `PronunciationProvider` (protocol: `analyze(audio:transcript:profile:) async throws -> Feedback`) | `Hex/Clients/PronunciationProvider.swift` |
| `GeminiProvider` (uses `gemini-2.5-flash`, audio-capable) | `Hex/Clients/Providers/GeminiProvider.swift` |
| `OpenAIProvider` (uses `gpt-4o-audio-preview`) | `Hex/Clients/Providers/OpenAIProvider.swift` |
| `KeychainClient` (`@DependencyClient`; thin `Security.framework` wrapper) | `Hex/Clients/KeychainClient.swift` |
| `CoachNotifier` (`UserNotifications` wrapper for the toast) | `Hex/Clients/CoachNotifier.swift` |
| `Pricing` (per-provider rate cards + monthly estimator) | `Hex/Clients/Pricing.swift` |
| `CoachFeedback` model (Codable, persisted via `@Shared(.fileStorage(...))`) | `Hex/Features/Coach/CoachFeedback.swift` |

All new `@DependencyClient` types follow the [PasteboardClient.swift](../Hex/Clients/PasteboardClient.swift) pattern: protocol-shaped struct, `liveValue` registered via `DependencyKey`, exposed on `DependencyValues`.

### 6.3 Modified upstream components (minimal touch)

| Component | Modification |
|---|---|
| `AppFeature` | Add `var coach: CoachFeature.State` and `Scope(state: \.coach, action: \.coach) { CoachFeature() }`. |
| `SettingsFeature` | Add a "Coach" section that hosts `CoachSettingsView`. |
| `HexSettings` | Add a nested `CoachSettings` Codable struct (additive). Default values keep coach disabled. |
| `HexLog` | Add `case coach = "Coach"` to `Category`, and `public static let coach = logger(.coach)`. |
| `Hex.entitlements` | Add `com.apple.security.keychain`. `network.client` already present in upstream (for HuggingFace downloads + Sparkle); no new entitlement *category* is needed for outbound HTTPS. |
| `Info.plist` | Replace `SUFeedURL` with HexCoach's own appcast URL. Update display name. Xcode project handles bundle ID change. |

Net upstream-file diff: **6 files, all additive edits**. None of these reshape existing behavior.

### 6.4 Data flow

```
[User holds hotkey]
        ↓
RecordingClient (unchanged) → writes /tmp/hex-capture-<uuid>.wav, returns URL
        ↓
TranscriptionFeature runs ASR → emits .transcriptionResult(text, audioURL)
        ↓
TranscriptionFeature pastes text, plays sound (unchanged)
        ↓
TranscriptPersistenceClient.save() moves audio to
  ~/Library/Application Support/Hex/Recordings/<timestamp>.wav
and appends a Transcript row to @Shared(.transcriptionHistory)
        ↓
CoachFeature observes @Shared(.transcriptionHistory) for new IDs
        ↓
CoachFeature: enabled? duration ≥ threshold? has API key?
        ↓ yes
CoachClient.analyze(audioURL, text, profile) async throws -> Feedback
        ↓
PronunciationProvider (Gemini | OpenAI) → Feedback
        ↓
CoachFeature appends to @Shared(.coachFeedback) (fileStorage)
CoachNotifier posts UNNotification
CoachPopoverView reflects latest item
```

### 6.5 Why this shape

- All HexCoach-specific logic lives under `Hex/Features/Coach/` and `Hex/Clients/`. We touch **six** upstream files and each edit is additive. Rebases stay manageable.
- CoachFeature observes `@Shared(.transcriptionHistory)` — the same mechanism the rest of the app uses to react to new transcripts. This avoids weaving coach logic through `TranscriptionFeature` and means zero changes to the transcription pipeline.
- `PronunciationProvider` is a protocol so adding a new provider is a self-contained PR. Good for OSS contributors.
- We never reach into Hex's transcription internals — we observe the *finished* row in shared state.

## 7. Data & State

### 7.1 Audio retention

Hex already retains audio: `TranscriptPersistenceClient` moves the WAV from temp to `~/Library/Application Support/Hex/Recordings/<timestamp>.wav` (sandbox-mapped under the HexCoach container, `~/Library/Containers/com.conglei.HexCoach/Data/Library/Application Support/Hex/Recordings/`). Audio lifecycle is tied to the `Transcript` row in `@Shared(.transcriptionHistory)`: deleting a transcript also deletes the audio file (see `HistoryFeature.deleteAudio` and trim logic in `TranscriptionFeature`).

HexCoach **reuses** these files. There is no separate coach-owned retention mechanism in v1.

- Optional Setting: **"Delete audio after successful coach analysis"** (default: off). When on, CoachFeature deletes the WAV via `transcriptPersistence.deleteAudio(transcript)` after a successful response, and Hex's history retains only the transcript text.
- Optional Setting: **"Skip coach for transcripts older than N days"** — coach only analyzes fresh sessions.
- "Clear all stored audio" is already provided by Hex's history-clear UX; HexCoach does not add a parallel control.

If analysis fails, the audio remains in place (because the transcript remains in history) and the popover surfaces a "Retry" action.

### 7.2 API key storage

HexCoach is the **first** consumer of macOS Keychain in this codebase. This requires:

- Adding `com.apple.security.keychain` to [Hex/Hex.entitlements](../Hex/Hex.entitlements).
- A new `KeychainClient` (`@DependencyClient`) wrapping `Security.framework` `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`.

Conventions:

- Service identifier: `com.conglei.HexCoach`, account = provider name (`"gemini"`, `"openai"`).
- Never written to disk in plaintext, never logged.
- Settings UI shows the last 4 chars of the saved key, never the full key.
- "Remove key" button in Settings.

### 7.3 Feedback history

Persisted via `@Shared(.fileStorage(coachFeedbackURL))` mirroring how `transcriptionHistory` works. The file path resolves to `~/Library/Application Support/Hex/coach_feedback.json` (sandbox-mapped under the HexCoach container).

Schema:

```json
{
  "version": 1,
  "items": [
    {
      "id": "uuid",
      "transcript_id": "uuid (joins to Transcript.id)",
      "timestamp": "ISO8601",
      "transcript": "string (intended text, copied for resilience)",
      "duration_sec": 12.4,
      "provider": "gemini" | "openai",
      "model": "gemini-2.5-flash",
      "feedback": { /* see §9.3 */ },
      "cost_usd_estimate": 0.0008
    }
  ]
}
```

`transcript_id` lets the popover deep-link to the source transcript and re-play audio if it still exists. History capped at 500 items; oldest evicted. User can export to JSON or delete from Settings.

### 7.4 User profile

User settings live in `HexSettings.coach` (a new nested Codable struct on the existing [HexCore/Sources/HexCore/Settings/HexSettings.swift](../HexCore/Sources/HexCore/Settings/HexSettings.swift) struct), persisted automatically via `@Shared(.hexSettings) + .fileStorage(.hexSettingsURL)`. **UserDefaults is not used** — Hex's convention is a single JSON-backed settings file.

```swift
struct CoachSettings: Codable, Equatable {
    var enabled: Bool                 // default: false
    var provider: Provider            // default: .gemini
    var thresholdSec: Int             // default: 10, range 3–120
    var l1Language: String            // e.g. "zh-Hans", "es", "ja"
    var targetAccent: TargetAccent    // .generalAmerican / .rp / .australian / .neutral
    var userGoal: String?             // optional free text
    var deleteAudioAfterAnalysis: Bool // default: false
}
```

Adding `var coach: CoachSettings = .init()` to `HexSettings` is the only schema change.

## 8. UX

### 8.1 Onboarding (new in HexCoach)

After the normal Hex onboarding (mic permission, accessibility permission, hotkey), HexCoach adds **one** screen:

> **Enable the Coach? (optional)**
>
> HexCoach can give you English pronunciation feedback after long recordings.
> This is opt-in. When enabled, your dictated audio is uploaded to the LLM provider you choose.
>
> [Skip — I just want dictation]   [Set up the Coach →]

The "Set up the Coach" path collects: provider choice (Gemini default), API key, L1 language, target accent. Threshold defaults to 10s; surfaces a one-line note "You can change all of this in Settings later."

### 8.2 Menu bar

- Icon: Hex's existing icon with a small dot indicator when coach is enabled.
- Click → popover.
- Popover sections:
  - **Latest feedback** (most recent analysis): score, top 3 suggestions, "play recording" button if the linked audio still exists.
  - **Recent sessions** (last 7 days): collapsed list of timestamps + one-line summaries; click to expand.
  - **Today's pattern** (only if 3+ sessions today): a 1-paragraph synthesis written by the same LLM, summarizing the day's recurring issues. Generated lazily on popover open.
  - Footer: "Coach: ON [toggle]   Settings…   Quit"

### 8.3 Settings → Coach panel

Rendered as a new section within the existing Settings window managed by [SettingsFeature.swift](../Hex/Features/Settings/SettingsFeature.swift). Fields:

- Coach enabled (toggle)
- Provider (segmented: Gemini / OpenAI)
- API key (secure field; shows last 4 chars when saved; "Test" button verifies the key with a 1-second dummy audio call)
- Target accent (dropdown: General American, British RP, Australian, Neutral)
- Native language (dropdown of common L1s + free-text)
- Trigger threshold (slider: 3–120 sec, default 10)
- Delete audio after successful analysis (toggle, default off)
- "Export history" button
- Privacy panel (expandable): "Here's exactly what's sent on each call, and what isn't."

### 8.4 Notifications

- On successful analysis: macOS notification, title "Pronunciation tip", body = first suggestion (truncated). Click → opens popover.
- On error (network, bad key, rate limit): one-time toast on first occurrence per session, then quiet. Detailed errors visible in popover and Settings.

### 8.5 Error states

| Condition | UX |
|---|---|
| No API key | Coach disabled; setting up Coach prompts the user when toggled on |
| Network failure | Transcript+audio remain in history, "Retry" surface in popover |
| Provider returns invalid JSON | Show raw text response in popover, log via `HexLog.coach.error`, retry once silently |
| Rate limit | Notification + 1-minute backoff; subsequent recordings analyzed normally |
| Audio file missing (e.g., user deleted transcript first) | Skip silently, log |

## 9. Prompt Design & Feedback Schema

### 9.1 Inputs to the provider

- The audio file (WAV 16 kHz mono float32 from `RecordingClient`; transcoded to `audio/mp4` if the provider requires; ≤ ~10MB; if longer / larger, send the first 60s only)
- The intended transcript (from Hex's local ASR — this is the ground truth of what the user *meant* to say)
- User profile: L1 language, target accent, optional user-stated goal

### 9.2 Prompt (Gemini)

```
You are a focused, kind English pronunciation coach for a {L1_LANGUAGE} speaker
targeting a {TARGET_ACCENT} accent. The user has just dictated the following:

Intended transcript: """{TRANSCRIPT}"""
{USER_GOAL_LINE_IF_PRESENT}

Listen to the attached audio. Identify the user's most impactful pronunciation
issues — issues common to {L1_LANGUAGE} speakers targeting {TARGET_ACCENT}, AND
issues you actually hear in this specific recording.

Produce JSON matching this schema exactly. No prose outside the JSON.

{
  "overall_score": <integer 1–10, calibrated against {TARGET_ACCENT} as 10>,
  "summary": "<one sentence, what stood out most>",
  "issues": [
    {
      "word_or_phrase": "<exact text from the transcript that was mispronounced>",
      "what_you_said": "<phonetic approximation of what you heard, e.g. 'puh-SIH-fik'>",
      "what_to_say": "<phonetic target, e.g. 'spuh-SIH-fik'>",
      "tip": "<one sentence drill or memory device>"
    }
  ],
  "wins": ["<one or two things the user did well>"]
}

Constraints:
- At most 3 issues, prioritized by impact (intelligibility > naturalness > finesse).
- Skip issues you can't clearly hear. Better to return zero issues than guess.
- "tip" should be a concrete drill, not vague advice.
- Be warm and direct. No filler.
```

### 9.3 Output schema

Strongly-typed in Swift via `Codable`:

```swift
struct Feedback: Codable, Equatable {
    let overallScore: Int           // 1–10
    let summary: String
    let issues: [Issue]
    let wins: [String]
}

struct Issue: Codable, Equatable {
    let wordOrPhrase: String
    let whatYouSaid: String
    let whatToSay: String
    let tip: String
}
```

The provider response is validated against this schema. Invalid responses trigger one silent retry with a "return valid JSON" reminder appended; if still invalid, the raw response is shown in the popover with an error badge.

### 9.4 Cost estimate

- **Gemini 2.5 Flash** with audio: roughly $0.075 / 1M input tokens; 10s audio is ~200–300 tokens. Per-session cost ≈ **$0.0001–0.001**. 100 sessions/day ≈ a few cents.
- **OpenAI gpt-4o-audio-preview**: meaningfully pricier, ~$100/1M audio input tokens. Per-session ≈ $0.01. 100 sessions/day ≈ $1.

*Pricing rates current as of 2026-05; verify against provider rate cards before shipping.* Centralize the per-provider rate cards in `Hex/Clients/Pricing.swift`. Settings shows a running monthly cost estimate based on session count + provider rate.

## 10. Privacy & Security

- **Default off.** User must opt in.
- **TLS only.** Default ATS posture is preserved (`NSAllowsArbitraryLoads = NO`).
- **No telemetry.** HexCoach phones home for Sparkle update checks only (configurable). No analytics, no error reporting service.
- **Audio path discipline.** Audio files are created by `RecordingClient`, moved by `TranscriptPersistenceClient` into the container, uploaded directly to the configured provider, and deleted per the optional post-analysis toggle. There is no third party "in the middle."
- **Keychain.** API keys never leave Keychain except for the in-memory provider client.
- **Permissions diff vs. Hex.** Current entitlements in [Hex/Hex.entitlements](../Hex/Hex.entitlements): `app-sandbox`, `automation.apple-events`, `device.audio-input`, `files.user-selected.read-write`, `network.client`, `cs.disable-library-validation`, Sparkle mach lookups. **Only addition for HexCoach: `com.apple.security.keychain`** for API-key storage. Network entitlement already present (used for HuggingFace model downloads and Sparkle update checks).
- **Audit log (optional, off by default).** When enabled, logs `(timestamp, audio_bytes_sent, provider, model, response_bytes, cost_estimate)` via `HexLog.coach` with `, privacy: .private` annotations on sensitive fields. No transcript or response content logged.

## 11. Open Questions

1. ~~Does Hex actually persist audio after transcription?~~ **Resolved:** yes, via `TranscriptPersistenceClient.save()` to `~/Library/Application Support/Hex/Recordings/`. HexCoach reuses these files.
2. **Should the popover include a "play audio" affordance?** Useful for learning ("hear what you said vs. what you should say"), available whenever the linked `Transcript` still has its audio file on disk.
3. **First-call latency tolerance.** Gemini Flash should respond in 1–3 seconds for 10s of audio. Acceptable? Or should we batch and run async on idle?
4. **Cost ceiling.** Should HexCoach refuse to call the API after, say, $5 of cost in a day, to protect the user? Soft warning vs. hard limit.
5. **Should we expose the raw model response in the popover for power users?** Helps debugging, but clutters the UI.
6. **Localization of the UI itself.** v1 ships English UI only, but consider whether "Coach for X" makes sense for Spanish/Mandarin learners later.
7. **Should "Today's pattern" synthesis be a separate, more expensive call (e.g., Gemini Pro)?** Or just Flash with the day's items concatenated?

## 12. Milestones

| M | Scope | Duration |
|---|---|---|
| **M1: Plumbing** | Fork Hex, set up upstream tracking, add `case coach` to `HexLog`, scaffold `CoachFeature` skeleton observing `@Shared(.transcriptionHistory)`, hardcoded Gemini call from a CLI test, log feedback via `HexLog.coach`. | 1 week |
| **M2: UI** | Full `CoachFeature`, popover, Settings → Coach panel via `SettingsFeature`, onboarding screen, `CoachNotifier`. | 1 week |
| **M3: Second provider + polish** | OpenAI provider, retry/error states, history view, cost estimator, "Today's pattern" synthesis. | 1 week |
| **M4: Release** | DMG signing/notarization (reuse Hex's release tooling under `tools/`), Homebrew cask, README, demo GIF, ship to /r/macapps. Replace Sparkle feed URL and S3 bucket. | 3 days |

Total v1: **~4 weeks** if part-time.

## 13. Out of scope / future versions

- **v1.1:** Anki export of issue words, personal mispronunciation dictionary, spaced repetition.
- **v1.2:** Local backend via phoneme alignment (wav2vec2-phoneme) + local text LLM (Ollama). Privacy-first mode.
- **v2:** Multilingual coaching (Spanish/Mandarin/etc. as target language).
- **v2:** iOS companion that syncs feedback for review.

## 14. Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-05-13 | Fork Hex rather than build standalone | Owner's call after weighing tradeoffs. Trade-off: long-term rebase cost vs. faster v1. |
| 2026-05-13 | Swift + SwiftUI (match Hex) | Forking demands matching upstream's stack. |
| 2026-05-13 | Gemini default, OpenAI second | Gemini Flash is cheapest audio-native option; OpenAI for users who already have keys. |
| 2026-05-13 | Coach OFF by default | Hex is privacy-first; the fork must not silently invert that posture. |
| 2026-05-13 | All coach code under `Hex/Features/Coach/` + `Hex/Clients/Coach*.swift` | Minimize merge conflict surface with upstream. |
| 2026-05-13 | Observe `@Shared(.transcriptionHistory)` rather than emit a new TCA event from `TranscriptionFeature` | Zero changes to upstream's transcription pipeline. CoachFeature reacts to new `Transcript` rows via shared state. Smaller rebase surface. |
| 2026-05-13 | Coach settings nested into `HexSettings`, not UserDefaults | Match Hex's single-source-of-truth JSON settings convention. |
| 2026-05-13 | Reuse Hex's audio retention (no parallel system) | `TranscriptPersistenceClient` already persists WAVs under `Application Support/Hex/Recordings/`. Coach reuses; optional "delete after analysis" toggle satisfies privacy-conscious users without duplicating tracking. |

## 15. Appendix: minimal fork rebase workflow

```bash
# one-time
git remote add upstream https://github.com/kitlangton/Hex.git

# weekly
git fetch upstream
git checkout upstream-main
git reset --hard upstream/main
git checkout main
git merge upstream-main      # resolve any conflicts in the six touched files
git push origin main upstream-main
```

If conflicts grow over time, consider rewriting upstream modifications as Swift extensions or wrapper types so the original files stay untouched. Note that `HexCore` is a separate Swift package consumed by the `Hex` target — coach changes that touch `HexCore/Sources/HexCore/Logging.swift` (one line) and `HexCore/Sources/HexCore/Settings/HexSettings.swift` (one additive field) should be the only `HexCore` changes. Most coach code lives in `Hex/Features/Coach/` and `Hex/Clients/`, keeping `HexCore` conflict surface near zero.

## 16. Workflow inheritance from Hex

HexCoach inherits Hex's project conventions documented in [CLAUDE.md](../CLAUDE.md):

- **Changesets.** Every user-facing change adds a `.changeset/*.md` fragment via the non-interactive script:
  ```bash
  bun run changeset:add-ai patch "Your summary here"
  ```
  Agents only create fragments; the release tool processes them.
- **Logging.** All diagnostics go through `HexLog` with the appropriate category and `, privacy: .private` annotations for sensitive data. Coach adds `case coach` and uses `HexLog.coach`.
- **Release pipeline.** Reuse `bun run tools/src/cli.ts release` for build → notarize → DMG → S3 → Sparkle → GitHub release. HexCoach must:
  - Replace the S3 bucket (`hex-updates`) with its own.
  - Replace `SUFeedURL` in `Info.plist` with HexCoach's appcast URL.
  - Notarize under the HexCoach signing identity.
  - Use a distinct Homebrew cask name (`hexcoach`).
- **Commits.** Concise subject lines (50–70 chars) describing user-facing impact; full rationale and reproduction steps in the body; link related GitHub issues.

---

*End of document.*
