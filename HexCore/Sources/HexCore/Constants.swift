import Foundation

/// Central repository for timing thresholds and magic numbers used throughout HexCore.
///
/// These values have been carefully tuned based on user testing and OS behavior.
/// Changing these values may affect hotkey responsiveness and conflict with system shortcuts.
public enum HexCoreConstants {
    
    // MARK: - Hotkey Timing Thresholds
    
    /// Maximum time between two hotkey taps to be considered a double-tap.
    ///
    /// **Value:** 0.3 seconds
    ///
    /// **Rationale:** This feels responsive for intentional double-taps while being
    /// long enough to avoid accidental triggers. Tested to align with standard
    /// UI double-click timing expectations.
    ///
    /// **Used in:**
    /// - `HotKeyProcessor`: Double-tap lock detection
    /// - Tests: Verifying double-tap vs two separate taps
    public static let doubleTapWindow: TimeInterval = 0.3
    
    /// Minimum duration for modifier-only hotkeys to avoid conflicts with OS shortcuts.
    ///
    /// **Value:** 0.3 seconds
    ///
    /// **Rationale:** macOS uses modifier keys for many shortcuts:
    /// - Option+click = duplicate in Finder
    /// - Cmd+click = open in new tab
    /// - etc.
    ///
    /// A 0.3s minimum prevents accidental transcription when users perform these
    /// system actions. This value is enforced regardless of user's `minimumKeyTime` setting
    /// (though user can set higher if desired).
    ///
    /// **Used in:**
    /// - `RecordingDecisionEngine`: Discard short modifier-only recordings
    /// - `HotKeyProcessor`: Mouse click cancellation threshold
    public static let modifierOnlyMinimumDuration: TimeInterval = 0.3
    
    /// Time window for canceling press-and-hold on different key press.
    ///
    /// **Value:** 1.0 second
    ///
    /// **Rationale:** For key+modifier hotkeys (e.g., Cmd+A), if user presses a different
    /// key within 1 second, it's likely accidental (fat-finger, muscle memory for different shortcut).
    /// After 1 second, we assume the user wants to type while recording.
    ///
    /// Does NOT apply to modifier-only hotkeys (they use `modifierOnlyMinimumDuration` instead).
    ///
    /// **Used in:**
    /// - `HotKeyProcessor`: Accidental key press detection for key+modifier hotkeys
    public static let pressAndHoldCancelWindow: TimeInterval = 1.0
    
    // MARK: - Default Settings
    
    /// Default minimum time a key must be held to register as valid press.
    ///
    /// **Value:** 0.2 seconds
    ///
    /// **Rationale:** Prevents very quick accidental taps while still feeling responsive.
    /// User-configurable in Settings. Modifier-only hotkeys override this with
    /// `modifierOnlyMinimumDuration` if higher.
    ///
    /// **Used in:**
    /// - `HexSettings`: Default value for user preference
    /// - `HotKeyProcessor`: Validation for printable-key hotkeys
    public static let defaultMinimumKeyTime: TimeInterval = 0.2
    
    /// Base volume for sound effects (before user multiplier applied).
    ///
    /// **Value:** 0.2 (20%)
    ///
    /// **Rationale:** Quiet enough to not be jarring, loud enough to provide clear feedback.
    /// User can adjust via soundEffectsVolume multiplier.
    ///
    /// **Used in:**
    /// - `HexSettings`: Default sound effects volume
    /// - Sound effect playback: Base volume before scaling
    public static let baseSoundEffectsVolume: Double = 0.2
}
