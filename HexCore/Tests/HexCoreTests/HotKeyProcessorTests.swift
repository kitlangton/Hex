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

    @Test
    func pressAndHold_releasingModifierBeforeKeyStillStops() throws {
        runScenario(
            hotkey: HotKey(key: .u, modifiers: [.option]),
            steps: [
                // Press modifier first (Option)
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: nil, expectedIsMatched: false),
                // Then press the key to start recording
                ScenarioStep(time: 0.05, key: .u, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Release the modifier while holding the key
                ScenarioStep(time: 1.5, key: .u, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                // Release the key a beat later — should stop recording automatically
                ScenarioStep(time: 1.55, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
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

    // For modifier-only hotkeys, extra modifiers after threshold are ignored
    @Test
    func pressAndHold_ignoresExtraModifierAfterThreshold_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                // Initial hotkey press (option)
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Press a different modifier after threshold (0.5s > 0.3s) - should be ignored
                ScenarioStep(time: 0.5, key: nil, modifiers: [.option, .command], expectedOutput: nil, expectedIsMatched: true),
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
                // Press a different key within cancel threshold - should discard silently since < minimumKeyTime
                ScenarioStep(time: 0.1, key: .c, modifiers: [.option], expectedOutput: .discard, expectedIsMatched: false),
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
    
    // Tests that adding extra modifier to multiple-modifier hotkey after threshold is ignored
    @Test
    func multipleModifiers_addingExtra_ignoredAfterThreshold() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option, .command]),
            steps: [
                // Press both required modifiers
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option, .command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Add Shift after threshold (0.5s > 0.3s) - should be ignored
                ScenarioStep(time: 0.5, key: nil, modifiers: [.option, .command, .shift], expectedOutput: nil, expectedIsMatched: true),
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
                // Press extra modifier - discards silently since < minimumKeyTime and goes dirty
                ScenarioStep(time: 0.1, key: nil, modifiers: [.option, .command], expectedOutput: .discard, expectedIsMatched: false),
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

// MARK: - Recording Decision Tests

struct RecordingDecisionTests {
    private func makeContext(
        hotkey: HotKey,
        minimumKeyTime: TimeInterval = 0.2,
        duration: TimeInterval?
    ) -> RecordingDecisionEngine.Context {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let start = duration.map { now.addingTimeInterval(-$0) }
        return RecordingDecisionEngine.Context(
            hotkey: hotkey,
            minimumKeyTime: minimumKeyTime,
            recordingStartTime: start,
            currentTime: now
        )
    }

    @Test
    func modifierOnlyShortPressIsDiscarded() {
        let ctx = makeContext(hotkey: HotKey(key: nil, modifiers: [.command]), duration: 0.1)
        #expect(RecordingDecisionEngine.decide(ctx) == .discardShortRecording)
    }

    @Test
    func printableKeyShortPressStillProceeds() {
        let ctx = makeContext(hotkey: HotKey(key: .quote, modifiers: [.command]), duration: 0.1)
        #expect(RecordingDecisionEngine.decide(ctx) == .proceedToTranscription)
    }

    @Test
    func longPressModifierOnlyProceeds() {
        let ctx = makeContext(hotkey: HotKey(key: nil, modifiers: [.option]), duration: 0.3)
        #expect(RecordingDecisionEngine.decide(ctx) == .proceedToTranscription)
    }

    @Test
    func missingStartTimeDefaultsToShort() {
        let ctx = RecordingDecisionEngine.Context(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            minimumKeyTime: 0.2,
            recordingStartTime: nil,
            currentTime: Date(timeIntervalSinceReferenceDate: 0)
        )
        #expect(RecordingDecisionEngine.decide(ctx) == .discardShortRecording)
    }
    
    // MARK: - Modifier-Only Minimum Duration Tests
    
    @Test
    func modifierOnly_enforcesMinimumDuration_0_3s() {
        // User sets minimumKeyTime to 0.1s, but modifier-only should still require 0.3s
        let ctx = makeContext(hotkey: HotKey(key: nil, modifiers: [.option]), minimumKeyTime: 0.1, duration: 0.25)
        #expect(RecordingDecisionEngine.decide(ctx) == .discardShortRecording)
    }
    
    @Test
    func modifierOnly_proceedsWhenAboveMinimumDuration() {
        // User sets minimumKeyTime to 0.1s, recording is 0.35s (above 0.3s threshold)
        let ctx = makeContext(hotkey: HotKey(key: nil, modifiers: [.option]), minimumKeyTime: 0.1, duration: 0.35)
        #expect(RecordingDecisionEngine.decide(ctx) == .proceedToTranscription)
    }
    
    @Test
    func modifierOnly_respectsUserPreferenceWhenHigher() {
        // User sets minimumKeyTime to 0.5s (higher than 0.3s default)
        let ctx = makeContext(hotkey: HotKey(key: nil, modifiers: [.option]), minimumKeyTime: 0.5, duration: 0.4)
        #expect(RecordingDecisionEngine.decide(ctx) == .discardShortRecording)
    }
    
    @Test
    func printableKey_doesNotEnforceModifierOnlyMinimum() {
        // Printable key hotkeys should use user's minimumKeyTime, not the 0.3s minimum
        let ctx = makeContext(hotkey: HotKey(key: .a, modifiers: [.command]), minimumKeyTime: 0.1, duration: 0.15)
        #expect(RecordingDecisionEngine.decide(ctx) == .proceedToTranscription)
    }
}

// MARK: - Mouse Click Tests

struct MouseClickTests {
    @Test
    func mouseClick_discardsQuickModifierOnlyRecording() throws {
        var processor = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            HotKeyProcessor(hotkey: HotKey(key: nil, modifiers: [.option]), minimumKeyTime: 0.15)
        }
        
        // Start recording with modifier-only hotkey
        let startOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            processor.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]))
        }
        #expect(startOutput == .startRecording)
        
        // Mouse click 0.25s later (< 0.3s threshold for modifier-only) should discard silently
        let clickOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0.25)
        } operation: {
            processor.processMouseClick()
        }
        #expect(clickOutput == .discard)
    }
    
    @Test
    func mouseClick_ignoredAfterThreshold() throws {
        var processor = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            HotKeyProcessor(hotkey: HotKey(key: nil, modifiers: [.option]), minimumKeyTime: 0.15)
        }
        
        // Start recording with modifier-only hotkey
        let startOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            processor.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]))
        }
        #expect(startOutput == .startRecording)
        
        // Mouse click 0.35s later (> 0.3s threshold) should be ignored - only ESC cancels
        let clickOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0.35)
        } operation: {
            processor.processMouseClick()
        }
        #expect(clickOutput == nil)
    }
    
    @Test
    func mouseClick_ignoredInDoubleTapLock() throws {
        var processor = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            HotKeyProcessor(hotkey: HotKey(key: nil, modifiers: [.option]), minimumKeyTime: 0.15)
        }
        
        // First tap
        _ = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            processor.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]))
        }
        _ = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0.2)
        } operation: {
            processor.process(keyEvent: KeyEvent(key: nil, modifiers: []))
        }
        
        // Second tap within threshold - should lock
        _ = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0.4)
        } operation: {
            processor.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]))
        }
        _ = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0.5)
        } operation: {
            processor.process(keyEvent: KeyEvent(key: nil, modifiers: []))
        }
        
        // Should be in double-tap lock now
        #expect(processor.state == .doubleTapLock)
        
        // Mouse click should be ignored - only ESC cancels locked recordings
        let clickOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0.6)
        } operation: {
            processor.processMouseClick()
        }
        #expect(clickOutput == nil)
    }
    
    @Test
    func mouseClick_ignoresKeyPlusModifierHotkey() throws {
        var processor = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            HotKeyProcessor(hotkey: HotKey(key: .a, modifiers: [.command]), minimumKeyTime: 0.15)
        }
        
        // Start recording with key+modifier hotkey
        let startOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            processor.process(keyEvent: KeyEvent(key: .a, modifiers: [.command]))
        }
        #expect(startOutput == .startRecording)
        
        // Mouse click should be ignored for key+modifier hotkeys
        let clickOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0.1)
        } operation: {
            processor.processMouseClick()
        }
        #expect(clickOutput == nil)
    }
    
    @Test
    func mouseClick_respectsHigherUserPreference() throws {
        var processor = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            HotKeyProcessor(hotkey: HotKey(key: nil, modifiers: [.option]), minimumKeyTime: 0.5)
        }
        
        // Start recording with modifier-only hotkey
        let startOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0)
        } operation: {
            processor.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]))
        }
        #expect(startOutput == .startRecording)
        
        // Mouse click 0.4s later (> 0.3s but < 0.5s user preference) should still discard
        let clickOutput = withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 0.4)
        } operation: {
            processor.processMouseClick()
        }
        #expect(clickOutput == .discard)
    }
}
