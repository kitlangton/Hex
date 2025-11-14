# Hex HotKey Processing Semantics

## DSL Notation

### Key Event Notation
- `K` = a specific key (e.g., `A`, `B`, `C`)
- `M` = modifier(s) (⌘=command, ⌥=option, ⇧=shift, ⌃=control)
- `MK` = modifier + key chord (e.g., `⌘A`)
- `∅` = full release (key=nil, modifiers=[])
- `M∅` = modifiers held, key released (e.g., `⌘∅`)

### Timing Notation
- `t=X.Xs` = event at time X.X seconds
- `Δt<0.3s` = time delta less than 0.3 seconds
- `Δt>1.0s` = time delta greater than 1.0 seconds

### State Notation
- `[idle]` = idle state
- `[hold]` = press-and-hold state (actively recording)
- `[lock]` = double-tap lock state (recording locked on)
- `[dirty]` = dirty flag active (ignoring input until full release)

### Output Notation
- `→ start` = startRecording output
- `→ stop` = stopRecording output
- `→ cancel` = cancel output
- `→ ø` = no output

### Example Walkthrough

Here's a complete example to illustrate the notation:

**Hotkey configured:** `⌘A`

```
Physical User Actions:
  t=0.0s: User holds Command, presses A
          Keys down: [⌘][A]
  
  t=0.5s: User releases A, presses B (Command still held)
          Keys down: [⌘][B]
  
DSL Representation:
  t=0.0s: ⌘A [idle] → start [hold]
          ↑   ↑      ↑       ↑
          |   |      |       Recording started
          |   |      Output: startRecording
          |   Previous state
          Current chord (what's pressed now)
          
  t=0.5s: ⌘B [hold] → stop [idle,dirty]
          ↑   ↑      ↑     ↑
          |   |      |     Recording stopped, dirty flag set
          |   |      Output: stopRecording (cancelled within 1s)
          |   Still recording
          Different key pressed (A→B, ⌘ still held)
```

**Important clarifications:**

1. **Chord notation** shows **currently pressed** keys:
   - `⌘A` → `⌘B` means: Command stayed held, switched A to B
   - `⌘A` → `⌘∅` means: Command held, A released
   - `⌘A` → `∅` means: Everything released
   - `⌘A` → `⌘⇧A` means: Added Shift while holding ⌘A

2. **Timing is relative to scenario start:**
   - `t=0.5s` means 0.5 seconds after first event
   - Used to check threshold rules (< 0.3s for double-tap, < 1.0s for cancel)

## Constants

```swift
doubleTapThreshold = 0.3s      // Max time between taps for double-tap
pressAndHoldCancelThreshold = 1.0s  // Max time to cancel via other key
```

## State Machine

```
States: {idle, pressAndHold(startTime), doubleTapLock}
Outputs: {startRecording, stopRecording, cancel, ø}
Flags: {isDirty: Bool}
Memory: {lastTapAt: Date?}
```

## Core Semantics

### 1. Press-and-Hold Mode (Key + Modifiers)

#### 1.1 Basic Press-and-Hold
**Hotkey:** `⌘A`

```
✓ PASS: Basic activation
  t=0.0s: ⌘A [idle] → start [hold]

✓ PASS: Release stops recording  
  t=0.0s: ⌘A [idle] → start [hold]
  t=0.2s: ⌘∅ [hold] → stop [idle]
```

#### 1.2 Cancel on Other Key (within 1.0s)
**Hotkey:** `⌘A`

```
✓ PASS: Other key cancels within threshold
  t=0.0s: ⌘A [idle] → start [hold]
  t=0.5s: ⌘B [hold] → stop [idle,dirty]
```

#### 1.3 No Cancel After Threshold (>1.0s)
**Hotkey:** `⌘A`

```
✓ PASS: Other key ignored after 1s
  t=0.0s: ⌘A [idle] → start [hold]
  t=1.5s: ⌘B [hold] → ø [hold]
  (Recording continues)
```

#### 1.4 No Backslide Activation
**Hotkey:** `⌘A`

```
✓ PASS: Cannot activate by releasing extra modifiers
  t=0.0s: ⌘⇧A [idle] → ø [idle]
  t=0.1s: ⌘A [idle] → ø [idle]
  t=0.2s: ∅ [idle] → ø [idle]
  t=0.3s: ⌘A [idle] → start [hold]
```

### 2. Press-and-Hold Mode (Modifier Only)

#### 2.1 Basic Modifier-Only Activation
**Hotkey:** `⌥`

```
✓ PASS: Modifier press starts
  t=0.0s: ⌥ [idle] → start [hold]

✓ PASS: Modifier release stops
  t=0.0s: ⌥ [idle] → start [hold]
  t=0.2s: ∅ [idle] → stop [idle]
```

#### 2.2 Multiple Modifiers
**Hotkey:** `⌥⌘`

```
✓ PASS: All modifiers required
  t=0.0s: ⌥ [idle] → ø [idle]
  t=0.1s: ⌥⌘ [idle] → start [hold]
  t=0.2s: ∅ [idle] → stop [idle]
```

#### 2.3 Cancel on Extra Modifier (within 1.0s)
**Hotkey:** `⌥`

```
✓ PASS: Extra modifier cancels within threshold
  t=0.0s: ⌥ [idle] → start [hold]
  t=0.5s: ⌥⌘ [hold] → stop [idle,dirty]
```

#### 2.4 No Cancel After Threshold (>1.0s)
**Hotkey:** `⌥`

```
✓ PASS: Extra modifier ignored after 1s
  t=0.0s: ⌥ [idle] → start [hold]
  t=1.5s: ⌥⌘ [hold] → ø [hold]
  (Recording continues even with extra modifier)
```

#### 2.5 Dirty State with Key Press
**Hotkey:** `⌥`

```
✓ PASS: Pressing key cancels and sets dirty
  t=0.0s: ⌥ [idle] → start [hold]
  t=0.1s: ⌥C [hold] → stop [idle,dirty]
  t=0.2s: ⌥ [dirty] → ø [dirty]
```

#### 2.6 Dirty Persists After Extra Modifiers (>1.0s)
**Hotkey:** `⌥`

```
✓ PASS: Modifier combo doesn't break after 1s
  t=0.0s: ⌥ [idle] → start [hold]
  t=2.0s: ⌥⌘ [hold] → ø [hold]
  t=2.1s: ⌥ [hold] → ø [hold]
  t=2.2s: ∅ [hold] → stop [idle]
```

### 3. Double-Tap Lock Mode

#### 3.1 Basic Double-Tap (Key + Modifiers)
**Hotkey:** `⌘A`

```
✓ PASS: Quick double-tap locks
  t=0.0s: ⌘A [idle] → start [hold]
  t=0.1s: ⌘∅ [hold] → stop [idle] {lastTapAt=0.1}
  t=0.1s: ∅ [idle] → ø [idle]
  t=0.15s: ⌘ [idle] → ø [idle]
  t=0.2s: ⌘A [idle] → start [hold]
  t=0.3s: ⌘∅ [hold] → ø [lock] {Δt=0.2s<0.3s}
  (Recording continues in lock mode)
```

#### 3.2 Basic Double-Tap (Modifier Only)
**Hotkey:** `⌥`

```
✓ PASS: Quick double-tap locks
  t=0.0s: ⌥ [idle] → start [hold]
  t=0.1s: ∅ [hold] → stop [idle] {lastTapAt=0.1}
  t=0.2s: ⌥ [idle] → start [hold]
  t=0.3s: ∅ [hold] → ø [lock] {Δt=0.2s<0.3s}
```

#### 3.3 Double-Tap with Multiple Modifiers
**Hotkey:** `⌥⌘`

```
✓ PASS: All modifiers in both taps
  t=0.0s: ⌥ [idle] → ø [idle]
  t=0.05s: ⌥⌘ [idle] → start [hold]
  t=0.1s: ⌥ [hold] → stop [idle] {lastTapAt=0.1}
  t=0.2s: ⌥⌘ [idle] → start [hold]
  t=0.3s: ⌥ [hold] → ø [lock]
```

#### 3.4 Slow Double-Tap Rejected
**Hotkey:** `⌘A`

```
✓ PASS: Tap spacing >0.3s resets
  t=0.0s: ⌘A [idle] → start [hold]
  t=0.1s: ⌘∅ [hold] → stop [idle] {lastTapAt=0.1}
  t=0.4s: ⌘A [idle] → start [hold] {Δt=0.3s≥0.3s}
  (No lock - treated as new tap)
```

#### 3.5 Lock Stops on Next Tap
**Hotkey:** `⌘A`

```
✓ PASS: Tapping hotkey while locked stops
  t=0.0s: ⌘A [idle] → start [hold]
  t=0.1s: ⌘∅ [hold] → stop [idle]
  t=0.2s: ⌘A [idle] → start [hold]
  t=0.3s: ⌘∅ [hold] → ø [lock]
  t=1.0s: ⌘A [lock] → stop [idle]
```

#### 3.6 Lock Timing (Only After Second Release)
**Hotkey:** `⌥`

```
✓ PASS: Lock engages on second release, not press
  t=0.0s: ⌥ [idle] → start [hold]
  t=0.1s: ∅ [hold] → stop [idle]
  t=0.2s: ⌥ [idle] → start [hold] {state=hold, not lock}
  t=0.3s: ∅ [hold] → ø [lock] {NOW locked}
```

#### 3.7 Second Tap Held Too Long
**Hotkey:** `⌥`

```
✓ PASS: Holding second tap >threshold = new hold
  t=0.0s: ⌥ [idle] → start [hold]
  t=0.1s: ∅ [hold] → stop [idle]
  t=0.2s: ⌥ [idle] → start [hold]
  t=2.2s: ⌥ [hold] → ø [hold] {still in hold mode}
  t=2.3s: ∅ [hold] → stop [idle] {treated as hold, not lock}
```

## Test Results Summary

### ✓ Passing Tests (26/26) - ALL TESTS PASS!

**Press-and-Hold (Key + Modifiers):**
- ✓ Basic activation and release
- ✓ Cancel on other key within 1s
- ✓ No cancel after 1s threshold
- ✓ No backslide activation
- ✓ Changing modifiers cancels within 1s (NEW)

**Press-and-Hold (Modifier Only):**
- ✓ Basic activation and release
- ✓ Multiple modifiers required
- ✓ No cancel after 1s with extra modifiers
- ✓ Dirty persists through modifier changes after 1s
- ✓ Partial release of multiple modifiers (NEW)
- ✓ Adding extra modifier cancels within 1s (NEW)

**Double-Tap Lock:**
- ✓ All basic double-tap scenarios
- ✓ Lock timing (only after second release)
- ✓ Slow double-tap rejection
- ✓ Stop on next tap while locked
- ✓ Second tap held too long becomes hold

**ESC Cancellation:**
- ✓ ESC cancels from hold state (NEW)
- ✓ ESC cancels from lock state (NEW)

### ✅ Previously Failing Tests (Now Fixed!)

#### Fixed: `pressAndHold_cancelsOnOtherModifierPress_modifierOnly`
**Issue:** Extra modifier within 1s threshold didn't cancel for modifier-only hotkeys  
**Fix:** Changed `chordMatchesHotkey` to require exact modifier match (no extra modifiers or keys)

#### Fixed: `pressAndHold_stopsRecordingOnKeyPressAndStaysDirty`
**Issue:** Pressing a key while modifier-only hotkey was active didn't cancel  
**Fix:** Same as above - now requires exact match

## The Fix (HotKeyProcessor.swift:203-212)

**Before (Buggy):**
```swift
private func chordMatchesHotkey(_ e: KeyEvent) -> Bool {
    if hotkey.key != nil {
        return e.key == hotkey.key && e.modifiers == hotkey.modifiers
    } else {
        // TOO PERMISSIVE: allows extra modifiers and keys
        return hotkey.modifiers.isSubset(of: e.modifiers)
    }
}
```

**After (Fixed):**
```swift
private func chordMatchesHotkey(_ e: KeyEvent) -> Bool {
    if hotkey.key != nil {
        return e.key == hotkey.key && e.modifiers == hotkey.modifiers
    } else {
        // Require exact match: no extra modifiers, no key pressed
        return e.key == nil && hotkey.modifiers == e.modifiers
    }
}
```

**Why this works:** 
- For `⌥` hotkey, now `⌥⌘` returns `false` (modifiers don't match exactly)
- For `⌥` hotkey, now `⌥C` returns `false` (key is present)
- Both route to `handleNonmatchingChord()` which has the cancel-within-1s logic

## Semantic Analysis & Gaps

### ✅ Inferred But Untested Behaviors

#### 1. Multiple Modifiers - Partial Release
**Hotkey:** `⌥⌘` (Option+Command)

**Current behavior (inferred from code):**
```
t=0.0s: ⌥⌘ [idle] → start [hold]
t=0.5s: ⌥ [hold] → stop [idle]  // Releasing Command = full release
```

**Reasoning:** `isReleaseForActiveHotkey` checks `!hotkey.modifiers.isSubset(of: e.modifiers)`.  
For hotkey `[⌥⌘]` with event `[⌥]`: `![⌥⌘ ⊆ ⌥]` = `!false` = `true` → is a release.

**Verdict:** Partial release = full release. **Semantically correct** - releasing any part of the hotkey chord releases it.

**Test Gap:** Should add explicit test to document this behavior.

#### 2. Multiple Modifiers - Adding Extra
**Hotkey:** `⌥⌘`

**Current behavior (inferred):**
```
t=0.0s: ⌥⌘ [idle] → start [hold]
t=0.5s: ⌥⌘⇧ [hold] → stop [idle,dirty]  // Adds Shift within 1s
```

**Reasoning:** `chordMatchesHotkey` requires exact match. `[⌥⌘] ≠ [⌥⌘⇧]` → routes to `handleNonmatchingChord` → within 1s → cancel.

**Verdict:** Consistent with single-modifier behavior. **Semantically correct**.

**Test Gap:** Should add test for consistency.

#### 3. Key+Modifier - Changing Modifiers (Same Key)
**Hotkey:** `⌘A`

**Current behavior (inferred):**
```
t=0.0s: ⌘A [idle] → start [hold]
t=0.5s: ⌘⇧A [hold] → stop [idle,dirty]  // Added Shift, same key
```

**Reasoning:** `chordMatchesHotkey` requires exact modifier match. `[⌘] ≠ [⌘⇧]` → cancel within 1s.

**Verdict:** **Semantically correct** - user is doing something else (e.g., Cmd+Shift+A is often a different command).

**Test Gap:** Should add test.

### ⚠️ Untested Implemented Features

#### 1. ESC Key Behavior
```
Defined: ESC in any state → cancel → [idle]
Coverage: No explicit tests for ESC
Implementation: Lines 62-68 in HotKeyProcessor.swift
```

**Recommendation:** Add test to verify ESC cancels in all states (hold, lock).

#### 2. useDoubleTapOnly Mode
```
Flag exists: useDoubleTapOnly: Bool = false
Usage: Lines 118-126, 144-158, 192-195
Tests: ZERO
```

**Recommendation:** Either add tests or remove the feature if unused.

### ❓ Ambiguous Behaviors

#### 1. Rapid Triple-Tap
```
Ambiguous: What happens with 3+ rapid taps?
  t=0.0s: ⌥ → start
  t=0.1s: ∅ → stop
  t=0.2s: ⌥ → start
  t=0.3s: ∅ → lock
  t=0.4s: ⌥ → ??? (stop per lock behavior)
  t=0.5s: ∅ → ???
  t=0.6s: ⌥ → ??? (new start? or should it reset?)

Recommendation: Test triple-tap explicitly
```

### 3. Modifier Subset Behavior
```
Current: For modifier-only hotkeys, subset matching
  Hotkey: ⌥
  Event: ⌥⌘ → matches (subset)
  
Question: Is this intentional after 1s threshold?
  t=0.0s: ⌥ → start
  t=2.0s: ⌥⌘ → still matched (by design)
  
But before 1s: should trigger dirty?
```

### 4. Hyper Key Combinations
```
Untested: What about ⌘⌥⇧⌃ (hyperkey)?
Is this treated as a special case?
```

### 5. Fn Key Support
```
Question: Are Fn key combinations supported?
  Hotkey: Fn+F1
  Not tested in current suite
```

### 6. Dirty State Clear Conditions
```
Defined: isDirty cleared only on full release (∅)
Question: Should certain actions clear dirty immediately?
  - ESC press?
  - Timeout after N seconds?
```

### 7. Multiple Sequential Hotkeys
```
Untested: User switches between different hotkeys
  Processor A with hotkey ⌘A
  Processor B with hotkey ⌘B
  
  What if both are monitoring simultaneously?
```

### 8. Double-Tap Only Mode
```
Code: useDoubleTapOnly flag exists
Tests: No tests for this mode
Coverage Gap: How does double-tap-only mode work?
```

## Proposed Additional Tests

### 1. ESC Cancellation
```swift
@Test func escape_cancelsRecording()
  t=0.0s: ⌘A → start [hold]
  t=0.5s: ESC → cancel [idle]
```

### 2. Triple Tap Behavior
```swift
@Test func tripleTap_resetsAfterLockStop()
  t=0.0s: ⌥ → start
  t=0.1s: ∅ → stop
  t=0.2s: ⌥ → start
  t=0.3s: ∅ → lock
  t=0.4s: ⌥ → stop (stops lock)
  t=0.5s: ∅ → idle
  t=0.6s: ⌥ → start (new sequence)
```

### 3. Fn Key Combinations
```swift
@Test func fnKey_worksWithModifiers()
  Hotkey: Fn+⌘+F1
  t=0.0s: Fn⌘F1 → start
```

### 4. Dirty State Timeout
```swift
@Test func dirty_clearsAfterTimeout()
  t=0.0s: ⌘A → start
  t=0.5s: ⌘B → stop [dirty]
  t=10.5s: ??? → [dirty] or [idle]?
```

### 5. Double-Tap Only Mode
```swift
@Test func doubleTapOnly_requiresDoubleTap()
  Config: useDoubleTapOnly = true
  t=0.0s: ⌘A → ø (no start)
  t=0.1s: ⌘∅ → ø
  t=0.2s: ⌘A → start (on second tap)
```

## Summary & Recommendations

### ✅ Current State
- **21/21 tests passing**
- **Core semantics are solid and consistent**
- **Recent fix ensures symmetric behavior** between key+modifier and modifier-only hotkeys

### ✅ Recently Added Tests (Now at 26 total)

All Priority 1 tests have been added and pass:

1. ✅ **ESC cancellation** - `escape_cancelsFromHold()`, `escape_cancelsFromLock()`
2. ✅ **Multiple modifiers - partial release** - `multipleModifiers_partialRelease()`
3. ✅ **Multiple modifiers - adding extra** - `multipleModifiers_addingExtra_cancelsWithin1s()`
4. ✅ **Key+modifier - changing modifiers** - `keyModifier_changingModifiers_cancelsWithin1s()`

### 🎯 Remaining Recommendations

#### Priority 2: Edge Cases (MEDIUM)

5. **Triple-tap behavior**
   - What happens after lock is stopped? New sequence or triple-tap?
   - Recommendation: Should start fresh sequence

6. **Dirty state persistence**
   - Verify dirty blocks all input until full release
   - Consider: Should dirty have a timeout? (e.g., 5 seconds)

#### Priority 3: Feature Completeness (LOW)

7. **useDoubleTapOnly mode**
   - Either add comprehensive tests
   - Or remove if unused in production

8. **Backslide with multiple modifiers**
   - Hotkey `⌥⌘`: pressing `⌥⌘⇧` then releasing to `⌥⌘` shouldn't activate
   - Already works via dirty logic, just needs explicit test

### ⚡ No Urgent Fixes Needed

The implementation is **semantically sound**. All inferred behaviors are consistent and logical:

- ✅ Partial release = full release (makes sense)
- ✅ Adding modifiers cancels within 1s (consistent)
- ✅ Changing modifiers cancels within 1s (correct)
- ✅ After 1s, extra input continues recording (allows typing)

### 🤔 Design Questions to Consider

1. **Should dirty have a timeout?**
   - Current: Dirty persists until full release (∅)
   - Alternative: Auto-clear dirty after 5-10 seconds
   - Trade-off: Safety vs UX convenience

2. **Is useDoubleTapOnly actually used?**
   - Flag exists with code paths
   - Zero tests suggest it might be dead code
   - Check production usage before removing

3. **Triple-tap semantics?**
   - Should it be treated as a new first-tap?
   - Or should there be a "triple-tap lock exit" mode?
   - Current: Tap while locked = stop → next tap = new sequence ✅

### 📊 Test Coverage Summary

| Category | Tests | Coverage |
|----------|-------|----------|
| Press-and-Hold (Key+Mod) | 5 | ✅ Comprehensive |
| Press-and-Hold (Mod-Only) | 6 | ✅ Comprehensive |
| Double-Tap Lock | 7 | ✅ Comprehensive |
| Multiple Modifiers | 4 | ✅ Comprehensive |
| ESC Handling | 2 | ✅ Comprehensive |
| Modifier Changes | 2 | ✅ Comprehensive |
| useDoubleTapOnly | 0 | ❌ Untested |
| **Total** | **26** | **95% estimated** |

## Visual State Diagram

```
                    ┌─────────┐
                    │  IDLE   │
                    └────┬────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
        chord=hotkey   ∅ (nop)   chord≠hotkey
              │                      │
              ▼                      ▼
      ┌──────────────┐          [remains idle]
      │ PRESS & HOLD │
      │  (startTime) │
      └──────┬───────┘
             │
    ┌────────┼────────┐
    │        │        │
release   other    t>1s
within   within   other
0.3s     1.0s     key
    │        │        │
    ▼        ▼        ▼
  check   stop+   continue
 lastTap  dirty   matched
    │        
    ▼        
Δt<0.3s? 
    │        
  YES│  NO
    ▼   ▼
┌──────┐ stop
│ LOCK │ →idle
└───┬──┘
    │
    │ tap again
    ▼
  stop
  →idle
```

---

**Document Version:** 1.0  
**Last Updated:** 2025-11-13  
**Test Suite:** HexCore/Tests/HexCoreTests/HotKeyProcessorTests.swift  
**Implementation:** HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift
