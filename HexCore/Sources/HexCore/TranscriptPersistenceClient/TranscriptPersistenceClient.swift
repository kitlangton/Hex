import Dependencies
import Foundation

public struct TranscriptPersistenceClient: Sendable {
    public var save: @Sendable (
        _ result: String,
        _ audioURL: URL,
        _ duration: TimeInterval,
        _ sourceAppBundleID: String?,
        _ sourceAppName: String?
    ) async throws -> Transcript
    
    public var deleteAudio: @Sendable (_ transcript: Transcript) async throws -> Void
}

extension TranscriptPersistenceClient: DependencyKey {
    public static let liveValue: TranscriptPersistenceClient = {
        return TranscriptPersistenceClient(
            save: { result, audioURL, duration, sourceAppBundleID, sourceAppName in
                let fm = FileManager.default
                let recordingsFolder = try URL.hexApplicationSupport.appendingPathComponent("Recordings", isDirectory: true)
                try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
                
                let filename = "\(Date().timeIntervalSince1970).wav"
                let finalURL = recordingsFolder.appendingPathComponent(filename)
                try fm.moveItem(at: audioURL, to: finalURL)
                
                return Transcript(
                    timestamp: Date(),
                    text: result,
                    audioPath: finalURL,
                    duration: duration,
                    sourceAppBundleID: sourceAppBundleID,
                    sourceAppName: sourceAppName
                )
            },
            deleteAudio: { transcript in
                FileManager.default.removeItemIfExists(at: transcript.audioPath)
            }
        )
    }()
    
    public static let testValue = TranscriptPersistenceClient(
        save: { _, _, _, _, _ in
            Transcript(timestamp: Date(), text: "", audioPath: URL(fileURLWithPath: "/"), duration: 0)
        },
        deleteAudio: { _ in }
    )
}

public extension DependencyValues {
    var transcriptPersistence: TranscriptPersistenceClient {
        get { self[TranscriptPersistenceClient.self] }
        set { self[TranscriptPersistenceClient.self] = newValue }
    }
}
