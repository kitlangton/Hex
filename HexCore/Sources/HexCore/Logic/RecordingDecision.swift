import Foundation

/// Determines whether a recording should be kept or discarded based on duration and hotkey type.
///
/// This engine enforces minimum recording durations to prevent accidental activations
/// and conflicts with system shortcuts.
public struct RecordingDecisionEngine {
    /// Minimum duration for modifier-only hotkeys to avoid OS shortcut conflicts.
    ///
    /// Kept for reference; no longer enforced as a floor.
    /// See `HexCoreConstants.modifierOnlyMinimumDuration` for rationale.
    public static let modifierOnlyMinimumDuration: TimeInterval = HexCoreConstants.modifierOnlyMinimumDuration
    
    /// Context information needed to make a recording decision.
    public struct Context: Equatable {
        /// The hotkey configuration that triggered this recording
        public var hotkey: HotKey
        
        /// User's configured minimum key time preference
        public var minimumKeyTime: TimeInterval
        
        /// When recording started (nil if no recording)
        public var recordingStartTime: Date?
        
        /// Current timestamp
        public var currentTime: Date

        public init(
            hotkey: HotKey,
            minimumKeyTime: TimeInterval,
            recordingStartTime: Date?,
            currentTime: Date
        ) {
            self.hotkey = hotkey
            self.minimumKeyTime = minimumKeyTime
            self.recordingStartTime = recordingStartTime
            self.currentTime = currentTime
        }
    }

    /// The decision outcome for a recording.
    public enum Decision: Equatable {
        /// Recording was too short or accidental - discard silently
        case discardShortRecording
        
        /// Recording meets minimum requirements - proceed with transcription
        case proceedToTranscription
    }

    /// Determines whether to keep or discard a recording based on duration and hotkey type.
    ///
    /// # Decision Logic
    ///
    /// **Modifier-only hotkeys** (e.g., Option):
    /// - Must meet `minimumKeyTime` (user configured)
    /// - Default of 0.2s provides a reasonable guard against accidental triggers;
    ///   users with obscure hotkeys (e.g. right Option) can lower it further
    ///
    /// **Key+modifier hotkeys** (e.g., Cmd+A):
    /// - Always proceeds to transcription (duration checked elsewhere)
    /// - User's minimumKeyTime preference applies
    ///
    /// - Parameter context: Recording context with timing and configuration
    /// - Returns: Decision to discard or proceed
    public static func decide(_ context: Context) -> Decision {
        let elapsed = context.recordingStartTime.map { context.currentTime.timeIntervalSince($0) } ?? 0
        let includesPrintableKey = context.hotkey.key != nil
        
        // Respect the user's minimumKeyTime setting directly.
        // Previously enforced a 0.3s floor for modifier-only hotkeys, but users with
        // obscure hotkeys (e.g. right Option) may want faster response.
        let effectiveMinimum = context.minimumKeyTime
        
        let durationIsLongEnough = elapsed >= effectiveMinimum
        return (durationIsLongEnough || includesPrintableKey) ? .proceedToTranscription : .discardShortRecording
    }
}
