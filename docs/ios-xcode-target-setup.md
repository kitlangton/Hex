# iOS Xcode Target Setup (manual, one-time)

These are the Xcode steps only you can do (creating targets writes correct
project files; signing/entitlements need your Apple ID). After each Part, tell
Claude and it will drop in the Swift code and build/verify.

Open `Hex.xcodeproj` in Xcode. Use **File ▸ New ▸ Target…** (adds to the existing
project — do NOT create a new project).

Conventions used by the code already written:
- App Group id: **`group.co.stonefrontier.hex`**
- App bundle id: **`co.stonefrontier.hex.ios`**
- Keyboard bundle id: **`co.stonefrontier.hex.ios.keyboard`** (must be the app id + suffix)
- URL scheme: **`hexkb`**

> **Account note:** Part A runs on a **free** Apple ID. Part B (keyboard + App
> Group) needs a **paid Apple Developer Program** account — App Groups and
> keyboard Full Access are not available to free personal teams.

---

## Part A — iOS App target `HexiOS`  (→ Milestone M1: standalone record → transcribe)

1. **File ▸ New ▸ Target… ▸ iOS ▸ App.** Product Name: `HexiOS`. Interface:
   **SwiftUI**. Language: **Swift**. Uncheck "Include Tests". Finish.
   (If asked to activate the scheme, do it.)
2. Select the **HexiOS** target ▸ **General ▸ Minimum Deployments** ▸ **iOS 17.0**.
3. **Build Settings** ▸ search "Swift Language Version" ▸ set **Swift 5**
   (matches the existing engine code; avoids a Swift 6 concurrency migration).
4. **Signing & Capabilities** ▸ check **Automatically manage signing** ▸ **Team** =
   your Apple ID ▸ set **Bundle Identifier** = `co.stonefrontier.hex.ios`.
5. **General ▸ Frameworks, Libraries, and Embedded Content ▸ +** ▸ add:
   **HexCore**, **WhisperKit**, **FluidAudio**.
6. Select the **Info** tab for the target (or edit `HexiOS/Info.plist`) and add:
   - **Privacy - Microphone Usage Description**
     (`NSMicrophoneUsageDescription`) = "Hex transcribes your voice on-device."
   - **Signing & Capabilities ▸ + Capability ▸ Background Modes** ▸ check **Audio,
     AirPlay, and Picture in Picture** (needed later for the session; harmless now).
   - **URL Types** (Info tab ▸ URL Types ▸ +): URL Schemes = `hexkb`.
7. ✋ **Tell Claude "Part A done."** It will add the app's Swift sources (record
   screen, history, settings) and wire the engine, then build for your iPhone.

> Skip App Groups in Part A — the standalone app doesn't need it, and adding it
> would force a paid account before you can run anything.

### Running Part A on your iPhone
- Plug in iPhone (or wireless) ▸ pick it as the run destination.
- First run: on iPhone, **Settings ▸ General ▸ VPN & Device Management ▸ trust**
  your developer certificate.
- Free account: the app cert expires after **7 days** — just re-run from Xcode.

---

## Part B — Keyboard extension `HexKeyboard`  (→ Milestone M2: dictation keyboard) — PAID account

1. **File ▸ New ▸ Target… ▸ iOS ▸ Custom Keyboard Extension.** Product Name:
   `HexKeyboard`. Finish. Activate the scheme if prompted.
2. **General ▸ Minimum Deployments ▸ iOS 17.0**; **Build Settings ▸ Swift Language
   Version ▸ Swift 5**.
3. **Signing & Capabilities** ▸ same **Team** ▸ Bundle Identifier =
   `co.stonefrontier.hex.ios.keyboard`.
4. Add **App Groups** capability to **BOTH** targets (HexiOS *and* HexKeyboard):
   **Signing & Capabilities ▸ + Capability ▸ App Groups ▸ +** ▸
   `group.co.stonefrontier.hex` (identical on both).
5. **HexKeyboard ▸ General ▸ Frameworks, Libraries, and Embedded Content ▸ +** ▸
   add **HexCore** only (the keyboard does no ML — no WhisperKit/FluidAudio).
6. Edit `HexKeyboard/Info.plist` ▸ `NSExtension ▸ NSExtensionAttributes` ▸ set
   **`RequestsOpenAccess` = YES** (needed for App Group + network access).
7. ✋ **Tell Claude "Part B done."** It will add the mic-centric keyboard UI and
   wire it to the host app via the IPC layer already in HexCore.

---

## What Claude does after each Part
- After **Part A**: iOS `RecordingClient` (P1-2), app UI + TCA wiring (P1-3),
  engine reuse (P0-4 or shared file membership), build + on-device verify.
- After **Part B**: keyboard UI (P2-2), bounce + swipe-back (P2-4), session
  controller (P3-1), App Intent (P3-2).
