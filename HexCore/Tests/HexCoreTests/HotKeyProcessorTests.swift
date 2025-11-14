//
//  HotKeyProcessorTests.swift
//  HexCoreTests
//
//  Created by Kit Langton on 1/27/25.
//

import Dependencies
import Foundation
@testable import HexCore
import Sauce
import Testing

struct HotKeyProcessorTests {
    // MARK: - Standard HotKey (key + modifiers) Tests

    // Tests a single key press that matches the hotkey
    @Test
    func pressAndHold_startsRecordingOnHotkey_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    @Test
    func pressAndHold_startsRecordingOnHotkey_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    // Tests releasing the hotkey stops recording
    @Test
    func pressAndHold_stopsRecordingOnHotkeyRelease_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func pressAndHold_stopsRecordingOnHotkeyRelease_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func pressAndHold_stopsRecordingOnHotkeyRelease_multipleModifiers() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option, .command]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: false),
                ScenarioStep(time: 0.1, key: nil, modifiers: [.option, .command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    // Tests pressing a different key cancels recording
    @Test
    func pressAndHold_cancelsOnOtherKeyPress_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // Initial hotkey press
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Different key press within cancel threshold
                ScenarioStep(time: 0.5, key: .b, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    // Cancel hold if release
    @Test
    func pressAndHold_cancelsOnOtherModifierPress_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // Initial hotkey press (option)
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Press a different modifier within cancel threshold
                ScenarioStep(time: 0.5, key: nil, modifiers: [.option, .command], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    // Tests that pressing a different key after threshold doesn't cancel
    @Test
    func pressAndHold_doesNotCancelAfterThreshold_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // Initial hotkey press
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Different key press after cancel threshold
                ScenarioStep(time: 1.5, key: .b, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true),
            ]
        )
    }

    @Test
    func pressAndHold_doesNotCancelAfterThreshold_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // Initial hotkey press
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Different modifier press after cancel threshold
                ScenarioStep(time: 1.5, key: nil, modifiers: [.option, .command], expectedOutput: nil, expectedIsMatched: true),
            ]
        )
    }

    // The user cannot "backslide" into pressing the hotkey. If the user is chording extra modifiers,
    // everything must be released before a hotkey can trigger
    @Test
    func pressAndHold_doesNotTriggerOnBackslide_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // They press the hotkey with an extra modifier
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command, .shift], expectedOutput: nil, expectedIsMatched: false),
                // And then release the extra modifier, nothing should happen
                ScenarioStep(time: 0.1, key: .a, modifiers: [.command], expectedOutput: nil, expectedIsMatched: false),
                // Then if they release everything, the hotkey should trigger
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: false),
                // And try to press the hotkey again, it should start recording
                ScenarioStep(time: 0.3, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    // Tests double-tap to lock recording
    @Test
    func doubleTapLock_startsRecordingOnDoubleTap_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Release all modifiers
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: false),
                // Press modifier again
                ScenarioStep(time: 0.15, key: nil, modifiers: [.command], expectedOutput: nil, expectedIsMatched: false),
                // Second tap within threshold
                ScenarioStep(time: 0.2, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Second release (should stay recording)
                ScenarioStep(time: 0.3, key: nil, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true, expectedState: .doubleTapLock),
            ]
        )
    }

    @Test
    func doubleTapLock_startsRecordingOnDoubleTap_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second tap within threshold
                ScenarioStep(time: 0.2, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Second release (should stay recording)
                ScenarioStep(time: 0.3, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true, expectedState: .doubleTapLock),
            ]
        )
    }

    @Test
    func doubleTapLock_startsRecordingOnDoubleTap_multipleModifiers() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option, .command]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: false),
                ScenarioStep(time: 0.05, key: nil, modifiers: [.option, .command], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [.option], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second tap within threshold
                ScenarioStep(time: 0.2, key: nil, modifiers: [.option, .command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Second release (should stay recording)
                ScenarioStep(time: 0.3, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: true, expectedState: .doubleTapLock),
            ]
        )
    }

    // Tests that a slow double tap doesn't lock recording
    @Test
    func doubleTapLock_ignoresSlowDoubleTap_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second tap after threshold
                ScenarioStep(time: 0.4, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    @Test
    func doubleTapLock_ignoresSlowDoubleTap_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second tap after threshold
                ScenarioStep(time: 0.4, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    // Tests that tapping again after double-tap lock stops recording
    @Test
    func doubleTapLock_stopsRecordingOnNextTap_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second tap within threshold
                ScenarioStep(time: 0.2, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Second release (should stay recording)
                ScenarioStep(time: 0.3, key: nil, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true, expectedState: .doubleTapLock),
                // Third tap to stop recording
                ScenarioStep(time: 1.0, key: .a, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func doubleTapLock_stopsRecordingOnNextTap_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second tap within threshold
                ScenarioStep(time: 0.2, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Second release (should stay recording)
                ScenarioStep(time: 0.3, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true, expectedState: .doubleTapLock),
                // Third tap to stop recording
                ScenarioStep(time: 1.0, key: nil, modifiers: [.option], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    // MARK: - Edge Cases

    // Tests that after pressing a key with option, releasing the key but keeping option pressed
    // does not restart recording due to the "dirty" state
    @Test
    func pressAndHold_stopsRecordingOnKeyPressAndStaysDirty() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // Initial hotkey press (option)
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Press a different modifier within cancel threshold
                ScenarioStep(time: 0.1, key: .c, modifiers: [.option], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Release the C
                ScenarioStep(time: 0.2, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: false),
            ]
        )
    }

    // MARK: - Fn + Arrow Regression

    // After using Fn with another key (e.g., Arrow), then fully releasing,
    // a subsequent standalone Fn press should be recognized and start recording.
    // This guards against the state getting "stuck" after Fn+Arrow usage (Issue #81).
    @Test
    func modifierOnly_fn_triggersAfterFnPlusKeyThenFullRelease() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.fn]),
            steps: [
                // Simulate using an Arrow with Fn held (use .c as a stand-in key for arrows in unit tests)
                ScenarioStep(time: 0.00, key: .c,  modifiers: [.fn], expectedOutput: nil, expectedIsMatched: false),
                // Fully release everything
                ScenarioStep(time: 0.05, key: nil, modifiers: [],    expectedOutput: nil, expectedIsMatched: false),
                // Next standalone Fn press should trigger recording
                ScenarioStep(time: 0.20, key: nil, modifiers: [.fn], expectedOutput: .startRecording, expectedIsMatched: true),
                // Release Fn should stop recording
                ScenarioStep(time: 0.40, key: nil, modifiers: [],    expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    // If the user uses Fn+Key and releases only the key (keeps Fn held),
    // we must NOT trigger — no standalone Fn edge occurred.
    @Test
    func modifierOnly_fn_doesNotTriggerWhenFnRemainsHeldAfterKeyRelease() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.fn]),
            steps: [
                // Use Fn with another key (stand-in for arrow)
                ScenarioStep(time: 0.00, key: .c,  modifiers: [.fn], expectedOutput: nil, expectedIsMatched: false),
                // Release the key but keep Fn held — should not start
                ScenarioStep(time: 0.05, key: nil, modifiers: [.fn], expectedOutput: nil, expectedIsMatched: false),
                // Only once the user fully releases and presses Fn again should it start
                ScenarioStep(time: 0.10, key: nil, modifiers: [],    expectedOutput: nil, expectedIsMatched: false),
                ScenarioStep(time: 0.25, key: nil, modifiers: [.fn], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.45, key: nil, modifiers: [],    expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    // The user presses and holds options, therefore it should start recording and then after two seconds he also presses command, which should not do anything.
    @Test
    func pressAndHold_staysDirtyAfterTwoSeconds() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // Initial hotkey press (option)
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Press command after two seconds
                ScenarioStep(time: 2.0, key: nil, modifiers: [.option, .command], expectedOutput: nil, expectedIsMatched: true),
                // Release command
                ScenarioStep(time: 2.1, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: true),
                // Release option
                ScenarioStep(time: 2.2, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    // Tests that double-tap lock only engages after the second release, not the second press
    @Test
    func doubleTap_onlyLocksAfterSecondRelease() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second tap within threshold - should start a new recording but not lock yet
                ScenarioStep(time: 0.2, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true, expectedState: .pressAndHold(startTime: Date(timeIntervalSince1970: 0.2))),
                // Second release - NOW it should lock
                ScenarioStep(time: 0.3, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true, expectedState: .doubleTapLock),
            ]
        )
    }

    // Tests that if second tap is held too long, it's treated as a new press-and-hold instead of double-tap
    @Test
    func doubleTap_secondTapHeldTooLongBecomesHold() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second press within threshold
                ScenarioStep(time: 0.2, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Hold for 2 seconds (should stay in press-and-hold mode)
                ScenarioStep(time: 2.2, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: true),
                // Release - should stop recording since it was a hold
                ScenarioStep(time: 2.3, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }
    
    // MARK: - Additional Coverage Tests
    
    // Tests ESC cancellation from hold state
    @Test
    func escape_cancelsFromHold() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // Start recording
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Press ESC
                ScenarioStep(time: 0.5, key: .escape, modifiers: [], expectedOutput: .cancel, expectedIsMatched: false),
            ]
        )
    }
    
    // Tests ESC cancellation from lock state
    @Test
    func escape_cancelsFromLock() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // First tap
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // First release
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Second tap (locks)
                ScenarioStep(time: 0.2, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.3, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                // Now locked - press ESC
                ScenarioStep(time: 1.0, key: .escape, modifiers: [], expectedOutput: .cancel, expectedIsMatched: false),
            ]
        )
    }
    
    // Tests that ESC while holding hotkey doesn't restart recording (issue #36)
    @Test
    func escape_whileHoldingHotkey_doesNotRestart() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // Start recording
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Press ESC while still holding hotkey
                ScenarioStep(time: 0.5, key: .escape, modifiers: [.command], expectedOutput: .cancel, expectedIsMatched: false),
                // Hotkey still held - should be ignored (dirty)
                ScenarioStep(time: 0.6, key: .a, modifiers: [.command], expectedOutput: nil, expectedIsMatched: false),
                // Full release
                ScenarioStep(time: 0.7, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: false),
                // Now pressing hotkey should work again
                ScenarioStep(time: 0.8, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }
    
    // Tests that modifier-only hotkey doesn't trigger when used with other keys (issue #87)
    @Test
    func modifierOnly_doesNotTriggerWithOtherKeys() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.command, .option]),
            steps: [
                // User presses cmd-option-T (keyboard shortcut)
                ScenarioStep(time: 0.0, key: .t, modifiers: [.command, .option], expectedOutput: nil, expectedIsMatched: false),
                // Release T but keep modifiers held
                ScenarioStep(time: 0.1, key: nil, modifiers: [.command, .option], expectedOutput: nil, expectedIsMatched: false),
                // Full release
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: false),
                // Now press just cmd-option (no key) - should trigger
                ScenarioStep(time: 0.3, key: nil, modifiers: [.command, .option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Release
                ScenarioStep(time: 0.4, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }
    
    // Tests that partially releasing multiple modifiers counts as full release
    @Test
    func multipleModifiers_partialRelease() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option, .command]),
            steps: [
                // Press both modifiers
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option, .command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Release Command (keep Option) - should stop recording
                ScenarioStep(time: 0.5, key: nil, modifiers: [.option], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }
    
    // Tests that adding extra modifier to multiple-modifier hotkey cancels within 1s
    @Test
    func multipleModifiers_addingExtra_cancelsWithin1s() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option, .command]),
            steps: [
                // Press both required modifiers
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option, .command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Add Shift within 1s
                ScenarioStep(time: 0.5, key: nil, modifiers: [.option, .command, .shift], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }
    
    // Tests that changing modifiers on same key cancels within 1s
    @Test
    func keyModifier_changingModifiers_cancelsWithin1s() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                // Initial hotkey press
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Add Shift modifier while keeping same key, within 1s
                ScenarioStep(time: 0.5, key: .a, modifiers: [.command, .shift], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }
    
    // Tests that dirty state blocks all input until full release
    @Test
    func dirtyState_blocksInputUntilFullRelease() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // Start recording
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Press extra modifier - cancels and goes dirty
                ScenarioStep(time: 0.1, key: nil, modifiers: [.option, .command], expectedOutput: .stopRecording, expectedIsMatched: false),
                // Try pressing hotkey again - should be ignored (dirty)
                ScenarioStep(time: 0.2, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: false),
                // Try pressing different keys - should be ignored (dirty)
                ScenarioStep(time: 0.3, key: .c, modifiers: [.option], expectedOutput: nil, expectedIsMatched: false),
                // Full release - clears dirty
                ScenarioStep(time: 0.4, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: false),
                // Now hotkey works again
                ScenarioStep(time: 0.5, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }
    
    // Tests that you can't activate by releasing extra modifiers (backslide)
    @Test
    func multipleModifiers_noBackslideActivation() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option, .command]),
            steps: [
                // Press with extra modifier (doesn't match)
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option, .command, .shift], expectedOutput: nil, expectedIsMatched: false),
                // Release Shift - now matches hotkey exactly, but should NOT activate (backslide)
                ScenarioStep(time: 0.1, key: nil, modifiers: [.option, .command], expectedOutput: nil, expectedIsMatched: false),
                // Full release
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: false),
                // NOW pressing hotkey should work
                ScenarioStep(time: 0.3, key: nil, modifiers: [.option, .command], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }
}

struct ScenarioStep {
    /// The time offset (in seconds) relative to the scenario start.
    let time: TimeInterval

    /// Which key (if any) is pressed in this chord
    let key: Key?

    /// Which modifiers are held in this chord
    let modifiers: Modifiers

    /// The expected output from `processor.process(...)` at this step,
    /// or `nil` if we expect no output.
    let expectedOutput: HotKeyProcessor.Output?

    /// Whether we expect `processor.isMatched` after this step, or `nil` if we don't care.
    let expectedIsMatched: Bool?

    /// If we want to check the processor's exact `state`.
    /// This is optional; if `nil` we won't check it.
    let expectedState: HotKeyProcessor.State?

    init(
        time: TimeInterval,
        key: Key? = nil,
        modifiers: Modifiers = [],
        expectedOutput: HotKeyProcessor.Output? = nil,
        expectedIsMatched: Bool? = nil,
        expectedState: HotKeyProcessor.State? = nil
    ) {
        self.time = time
        self.key = key
        self.modifiers = modifiers
        self.expectedOutput = expectedOutput
        self.expectedIsMatched = expectedIsMatched
        self.expectedState = expectedState
    }
}

func runScenario(
    hotkey: HotKey,
    steps: [ScenarioStep]
) {
    // Sort steps by time, just in case they're not in ascending order
    let sortedSteps = steps.sorted { $0.time < $1.time }

    // We'll keep track of the "current time" as we simulate
    var currentTime: TimeInterval = 0

    // Create the processor with an initial date
    var processor = withDependencies {
        $0.date.now = Date(timeIntervalSince1970: currentTime)
    } operation: {
        HotKeyProcessor(hotkey: hotkey)
    }

    // We'll step through each event
    for step in sortedSteps {
        // let delta = step.time - currentTime
        currentTime = step.time
        // Sleep or jump time
        withDependencies {
            $0.date.now = Date(timeIntervalSince1970: currentTime)
        } operation: {
            // Build a KeyEvent from step's chord
            let keyEvent = KeyEvent(key: step.key, modifiers: step.modifiers)

            // Process
            let actualOutput = processor.process(keyEvent: keyEvent)

            // If step.expectedOutput != nil, #expect that it matches actualOutput
            if let expected = step.expectedOutput {
                #expect(
                    actualOutput == expected,
                    "\(step.time)s: expected output \(expected), got \(String(describing: actualOutput))"
                )
            } else {
                // We expect no output
                #expect(
                    actualOutput == nil,
                    "\(step.time)s: expected no output, got \(String(describing: actualOutput))"
                )
            }

            // If step.expectedIsMatched != nil, #expect that it matches processor.isMatched
            if let expMatch = step.expectedIsMatched {
                #expect(
                    processor.isMatched == expMatch,
                    "\(step.time)s: expected isMatched=\(expMatch), got \(processor.isMatched)"
                )
            }

            // If we want to test the entire state:
            if let expState = step.expectedState {
                #expect(
                    processor.state == expState,
                    "\(step.time)s: expected state=\(expState), got \(processor.state)"
                )
            }
        }
    }
}
