//
//  HexTests.swift
//  HexTests
//
//  Created by Kit Langton on 1/27/25.
//

import Dependencies
import Foundation
@testable import Hex
import Sauce
import Testing

struct HexTests {
    // MARK: - Hold-to-Record Mode Tests
    // These tests verify the Hold-to-Record mode behavior (default recording mode).
    // In this mode, users press and hold the hotkey to record, then release to stop.
    // The mode includes a 1-second cancel threshold and minimumKeyTime delay for modifier-only hotkeys.
    // Note: These tests use the default recordingMode (.holdToRecord) and were originally
    // written as "pressAndHold" tests, which is the same behavior as Hold-to-Record mode.

    // Tests a single key press that matches the hotkey
    @Test
    func holdToRecord_startsRecordingOnHotkey_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    @Test
    func holdToRecord_startsRecordingOnHotkey_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    // Tests releasing the hotkey stops recording
    @Test
    func holdToRecord_stopsRecordingOnHotkeyRelease_standard() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            steps: [
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func holdToRecord_stopsRecordingOnHotkeyRelease_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            steps: [
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                ScenarioStep(time: 0.2, key: nil, modifiers: [], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func holdToRecord_stopsRecordingOnHotkeyRelease_multipleModifiers() throws {
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
    func holdToRecord_cancelsOnOtherKeyPress_standard() throws {
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
    func holdToRecord_cancelsOnOtherModifierPress_modifierOnly() throws {
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
    func holdToRecord_doesNotCancelAfterThreshold_standard() throws {
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
    func holdToRecord_doesNotCancelAfterThreshold_modifierOnly() throws {
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
    func holdToRecord_doesNotTriggerOnBackslide_standard() throws {
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

    // Tests that pressing ESC cancels recording in Hold-to-Record mode
    @Test
    func holdToRecord_cancelsOnEscKey() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            recordingMode: .holdToRecord,
            steps: [
                // Start recording
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Press ESC to cancel
                ScenarioStep(time: 0.5, key: .escape, modifiers: [], expectedOutput: .cancel, expectedIsMatched: false),
            ]
        )
    }

    // MARK: - Tap-to-Toggle Mode Tests

    @Test
    func tapToToggle_startsImmediatelyOnFirstTap_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            recordingMode: .tapToToggle,
            steps: [
                // First tap starts recording immediately
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    @Test
    func tapToToggle_startsImmediatelyOnFirstTap_keyModifier() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            recordingMode: .tapToToggle,
            steps: [
                // First tap starts recording immediately
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
            ]
        )
    }

    @Test
    func tapToToggle_stopsOnSecondTap_modifierOnly() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            recordingMode: .tapToToggle,
            steps: [
                // First tap starts recording
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Release (should stay recording in tap-to-toggle mode)
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                // Second tap stops recording
                ScenarioStep(time: 1.0, key: nil, modifiers: [.option], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func tapToToggle_stopsOnSecondTap_keyModifier() throws {
        runScenario(
            hotkey: HotKey(key: .a, modifiers: [.command]),
            recordingMode: .tapToToggle,
            steps: [
                // First tap starts recording
                ScenarioStep(time: 0.0, key: .a, modifiers: [.command], expectedOutput: .startRecording, expectedIsMatched: true),
                // Release (should stay recording in tap-to-toggle mode)
                ScenarioStep(time: 0.1, key: nil, modifiers: [.command], expectedOutput: nil, expectedIsMatched: true),
                // Second tap stops recording
                ScenarioStep(time: 1.0, key: .a, modifiers: [.command], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    @Test
    func tapToToggle_ignoresNonMatchingChords() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            recordingMode: .tapToToggle,
            steps: [
                // First tap starts recording
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Release - stays recording
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                // Pressing other keys should be ignored
                ScenarioStep(time: 0.2, key: .a, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                // Second tap of hotkey stops recording
                ScenarioStep(time: 1.0, key: nil, modifiers: [.option], expectedOutput: .stopRecording, expectedIsMatched: false),
            ]
        )
    }

    // Tests that pressing ESC cancels recording in Tap-to-Toggle mode
    @Test
    func tapToToggle_cancelsOnEscKey() throws {
        runScenario(
            hotkey: HotKey(key: nil, modifiers: [.option]),
            recordingMode: .tapToToggle,
            steps: [
                // Start recording
                ScenarioStep(time: 0.0, key: nil, modifiers: [.option], expectedOutput: .startRecording, expectedIsMatched: true),
                // Release hotkey (should stay recording in toggle mode)
                ScenarioStep(time: 0.1, key: nil, modifiers: [], expectedOutput: nil, expectedIsMatched: true),
                // Press ESC to cancel
                ScenarioStep(time: 0.5, key: .escape, modifiers: [], expectedOutput: .cancel, expectedIsMatched: false),
            ]
        )
    }

    // MARK: - Settings Migration Tests

    @Test
    func settingsMigration_useDoubleTapOnlyTrue_becomesToggleMode() throws {
        // Create a JSON with old useDoubleTapOnly setting
        let json = """
        {
            "useDoubleTapOnly": true,
            "soundEffectsEnabled": true
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let settings = try decoder.decode(HexSettings.self, from: data)

        #expect(settings.recordingMode == .tapToToggle)
    }

    @Test
    func settingsMigration_useDoubleTapOnlyFalse_becomesHoldMode() throws {
        // Create a JSON with old useDoubleTapOnly setting
        let json = """
        {
            "useDoubleTapOnly": false,
            "soundEffectsEnabled": true
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let settings = try decoder.decode(HexSettings.self, from: data)

        #expect(settings.recordingMode == .holdToRecord)
    }

    @Test
    func settingsMigration_missingRecordingMode_defaultsToHoldMode() throws {
        // Create a JSON without recordingMode or useDoubleTapOnly
        let json = """
        {
            "soundEffectsEnabled": true
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let settings = try decoder.decode(HexSettings.self, from: data)

        #expect(settings.recordingMode == .holdToRecord)
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
    recordingMode: RecordingMode = .holdToRecord,
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
        HotKeyProcessor(hotkey: hotkey, recordingMode: recordingMode)
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
