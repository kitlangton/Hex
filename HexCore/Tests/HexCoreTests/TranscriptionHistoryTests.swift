import XCTest
@testable import HexCore

final class TranscriptionHistoryTests: XCTestCase {
    func testLegacyEntryWithoutStatusDecodesAsCompleted() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "timestamp": 720000000.0,
            "text": "Hello world",
            "audioPath": "file:///tmp/x.wav",
            "duration": 1.5,
            "sourceAppBundleID": "com.example.app",
            "sourceAppName": "Example"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Transcript.self, from: legacyJSON)

        XCTAssertNil(decoded.status, "Legacy entries should decode with nil status")
        XCTAssertEqual(decoded.resolvedStatus, .completed, "Nil status must resolve to .completed for back-compat")
        XCTAssertEqual(decoded.text, "Hello world")
        XCTAssertEqual(decoded.duration, 1.5)
    }

    func testRoundTripWithCompletedStatus() throws {
        let original = makeTranscript(status: .completed)
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.resolvedStatus, .completed)
    }

    func testRoundTripWithCancelledStatus() throws {
        let original = makeTranscript(text: "", status: .cancelled)
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.resolvedStatus, .cancelled)
    }

    func testRoundTripWithFailedStatus() throws {
        let original = makeTranscript(text: "", status: .failed)
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.resolvedStatus, .failed)
    }

    func testTranscriptEquatableHoldsAcrossStatusValues() {
        let a = makeTranscript(status: .completed)
        let b = makeTranscript(status: .completed)
        let c = makeTranscript(status: .failed)

        XCTAssertEqual(a, b, "Transcripts with identical fields and same status are equal")
        XCTAssertNotEqual(a, c, "Transcripts differing only in status are not equal")
    }

    func testInitializerDefaultsStatusToNil() {
        let transcript = Transcript(
            timestamp: Date(),
            text: "hello",
            audioPath: URL(fileURLWithPath: "/tmp/x.wav"),
            duration: 1.0
        )
        XCTAssertNil(transcript.status, "Default initializer status should be nil")
        XCTAssertEqual(transcript.resolvedStatus, .completed)
    }

    func testHistoryRoundTripPreservesStatuses() throws {
        let history = TranscriptionHistory(history: [
            makeTranscript(id: UUID(), status: .completed),
            makeTranscript(id: UUID(), text: "", status: .cancelled),
            makeTranscript(id: UUID(), text: "", status: .failed),
        ])

        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(TranscriptionHistory.self, from: data)

        XCTAssertEqual(decoded, history)
        XCTAssertEqual(decoded.history.map(\.resolvedStatus), [.completed, .cancelled, .failed])
    }

    // MARK: - Helpers

    private func makeTranscript(
        id: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        text: String = "sample",
        status: TranscriptStatus?
    ) -> Transcript {
        Transcript(
            id: id,
            timestamp: Date(timeIntervalSince1970: 720_000_000),
            text: text,
            audioPath: URL(fileURLWithPath: "/tmp/test.wav"),
            duration: 2.0,
            sourceAppBundleID: "com.example.app",
            sourceAppName: "Example",
            status: status
        )
    }

    private func roundTrip(_ transcript: Transcript) throws -> Transcript {
        let data = try JSONEncoder().encode(transcript)
        return try JSONDecoder().decode(Transcript.self, from: data)
    }
}
