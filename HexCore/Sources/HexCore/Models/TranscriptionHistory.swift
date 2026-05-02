import Foundation

public enum TranscriptStatus: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var text: String
    public var audioPath: URL
    public var duration: TimeInterval
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var status: TranscriptStatus?

    public var resolvedStatus: TranscriptStatus { status ?? .completed }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        text: String,
        audioPath: URL,
        duration: TimeInterval,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        status: TranscriptStatus? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.audioPath = audioPath
        self.duration = duration
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.status = status
    }
}

public struct TranscriptionHistory: Codable, Equatable, Sendable {
    public var history: [Transcript] = []

    public init(history: [Transcript] = []) {
        self.history = history
    }
}
