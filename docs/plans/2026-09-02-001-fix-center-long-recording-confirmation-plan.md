---
title: Center Long Recording Confirmation - Plan
type: fix
date: 2026-09-02
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Center Long Recording Confirmation - Plan

## Goal Capsule

- **Objective:** Show the long-recording cancellation confirmation centered and wholly within the active display instead of clipping it at the edge-anchored recording indicator.
- **Authority:** Preserve the user's requested centered presentation while retaining existing recording, dismiss, and cancellation behavior.
- **Stop conditions:** Do not alter the confirmation threshold, the reducer actions, indicator placement preferences, or unrelated alert behavior.
- **Tail ownership:** Create the required user-facing changeset fragment; do not run tests or a Debug build unless the user explicitly requests either.

## Product Contract

### Summary

The confirmation displayed when cancelling a long recording must be centered in the active display's usable area and fully visible for every indicator location.

### Problem Frame

The current SwiftUI alert is attached to the small borderless `InvisibleWindow` that tracks the recording pill at a screen edge.
When the pill is at the bottom, AppKit positions the alert beyond the host panel and clips the confirmation.

### Requirements

- R1. Present the long-recording cancellation confirmation in the active display's visible frame, centered on both axes.
- R2. Preserve the existing title, explanation, button labels, button roles, and reducer actions for keeping or cancelling the recording.
- R3. Keep the recording-pill panel's normal measured size, edge placement, click-through behavior, and screen tracking unchanged outside the confirmation.
- R4. Include a patch changeset describing the user-visible correction.

### Acceptance Examples

- AE1. Given the recording indicator is at bottom center and a long recording is cancelled, when confirmation is requested, then the entire dialog is visible and centered above the Dock-safe area.
- AE2. Given the confirmation is visible, when the user keeps recording, then the confirmation closes and recording continues.
- AE3. Given the confirmation is visible, when the user cancels recording, then the existing cancellation flow runs without transcription.

## Planning Contract

### Key Technical Decisions

- KTD1. Replace the sheet-style SwiftUI alert attachment with a standalone `NSAlert` presentation so its layout is not bounded by `InvisibleWindow`.
- KTD2. Position the native alert window in the display containing the current pointer, using that screen's `visibleFrame` so menu-bar and Dock space cannot clip the dialog.
- KTD3. Keep alert response mapping in the overlay view and send the existing `dismissLongRecordingCancellationConfirmation` and `confirmLongRecordingCancellation` actions unchanged.

### Assumptions

- `NSAlert.runModal()` provides the existing modal-confirmation interaction without requiring the settings window to be opened or activated as a presentation host.

### Sources and Research

- `Hex/Features/Transcription/TranscriptionIndicatorView.swift` currently attaches the confirmation to the overlay view.
- `Hex/Views/InvisibleWindow.swift` sizes its non-key panel to the recording pill and places bottom indicators with an 18-point inset.
- `Hex/App/HexAppDelegate.swift` hosts this overlay exclusively in `InvisibleWindow`.
- `docs/plans/2026-07-29-001-feat-no-focus-transcript-fallback-plan.md` establishes display-clamped overlay placement as the relevant local pattern.

## Implementation Units

### U1. Present the cancellation alert independently of the recording-pill panel

- **Goal:** Route the existing long-recording confirmation state through a centered, display-clamped native AppKit alert.
- **Requirements:** R1, R2, R3.
- **Dependencies:** None.
- **Files:** `Hex/Features/Transcription/TranscriptionIndicatorView.swift`.
- **Approach:** Introduce a private presentation helper that configures the existing message and actions, centers the alert window in the visible frame of the pointer's display, and returns the selected response. Observe the existing presentation state rather than attaching `.alert` to the overlay panel, then map responses back to the unchanged reducer actions.
- **Patterns to follow:** Retain the existing `Binding`/store action semantics and the `NSScreen.visibleFrame` display-safe placement rule used by overlay planning.
- **Test scenarios:** Covers AE1. Trigger confirmation while the indicator is bottom-aligned and verify the native dialog's frame stays inside the active display's visible frame. Covers AE2. Select Keep Recording and verify the presentation state clears without cancelling. Covers AE3. Select Cancel Recording and verify the existing cancellation action executes.
- **Verification:** Perform the visual interaction check only if the user requests a Debug launch; no unit test is planned because native app-modal geometry is not covered by the current test harness and repository policy makes tests opt-in.

### U2. Record the user-visible correction

- **Goal:** Add the required release-note fragment.
- **Requirements:** R4.
- **Dependencies:** U1.
- **Files:** `.changeset/<generated-name>.md`.
- **Approach:** Use the repository's non-interactive changeset script with a patch-level summary that states the long-recording confirmation no longer appears clipped.
- **Test expectation:** none -- release-note metadata has no runtime behavior.
- **Verification:** Confirm the generated fragment names the Octo package and accurately summarizes the fix.

## Verification Contract

| Scope | Evidence | Applicability |
| --- | --- | --- |
| Alert placement | Confirm the dialog is centered and contained by the active screen's visible frame at a bottom indicator location. | Manual Debug launch only when explicitly requested. |
| Action preservation | Confirm Keep Recording dismisses and Cancel Recording dispatches the existing cancellation action. | Manual Debug launch only when explicitly requested. |
| Release metadata | Inspect the new patch changeset fragment. | Required. |

## Definition of Done

- U1 presents the existing confirmation through a standalone alert centered within the active display's usable bounds.
- The Keep Recording and Cancel Recording choices preserve their current reducer actions and recording behavior.
- Normal `InvisibleWindow` sizing and indicator placement are unchanged when confirmation is not presented.
- U2 adds the required patch changeset fragment.
- The diff contains no abandoned presentation experiments.
