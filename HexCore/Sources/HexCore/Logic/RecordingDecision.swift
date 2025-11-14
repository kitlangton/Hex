import Foundation

public struct RecordingDecisionEngine {
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
        let durationIsLongEnough = elapsed >= context.minimumKeyTime
        let includesPrintableKey = context.hotkey.key != nil
        return (durationIsLongEnough || includesPrintableKey) ? .proceedToTranscription : .discardShortRecording
    }
}
