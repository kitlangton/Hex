import Foundation

public struct RecordingDecisionEngine {
    /// Minimum duration for modifier-only hotkeys to avoid OS shortcut conflicts
    /// This is applied regardless of user's minimumKeyTime setting
    public static let modifierOnlyMinimumDuration: TimeInterval = 0.3
    
    public struct Context: Equatable {
        public var hotkey: HotKey
        public var minimumKeyTime: TimeInterval
        public var recordingStartTime: Date?
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

    public enum Decision: Equatable {
        case discardShortRecording
        case proceedToTranscription
    }

    public static func decide(_ context: Context) -> Decision {
        let elapsed = context.recordingStartTime.map { context.currentTime.timeIntervalSince($0) } ?? 0
        let includesPrintableKey = context.hotkey.key != nil
        
        // For modifier-only hotkeys, use the higher of minimumKeyTime or modifierOnlyMinimumDuration
        // to prevent conflicts with system shortcuts
        let effectiveMinimum = includesPrintableKey 
            ? context.minimumKeyTime 
            : max(context.minimumKeyTime, modifierOnlyMinimumDuration)
        
        let durationIsLongEnough = elapsed >= effectiveMinimum
        return (durationIsLongEnough || includesPrintableKey) ? .proceedToTranscription : .discardShortRecording
    }
}
