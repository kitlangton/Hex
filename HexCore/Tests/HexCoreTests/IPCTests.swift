import Foundation
import Testing
@testable import HexCore

@Suite struct AppGroupMailboxTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexcore-ipc-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func read_returnsNil_whenEmpty() throws {
        let mailbox = AppGroupMailbox<DictationResult>(directory: tempDir(), filename: "r.json")
        #expect(try mailbox.read() == nil)
    }

    @Test func write_then_read_roundTrips() throws {
        let mailbox = AppGroupMailbox<DictationResult>(directory: tempDir(), filename: "r.json")
        let result = DictationResult(text: "hello world", createdAt: Date(timeIntervalSince1970: 1000))
        try mailbox.write(result)
        #expect(try mailbox.read() == result)
    }

    @Test func write_overwrites_previous() throws {
        let mailbox = AppGroupMailbox<DictationResult>(directory: tempDir(), filename: "r.json")
        try mailbox.write(DictationResult(text: "first", createdAt: Date(timeIntervalSince1970: 1)))
        let second = DictationResult(text: "second", createdAt: Date(timeIntervalSince1970: 2))
        try mailbox.write(second)
        #expect(try mailbox.read() == second)
    }

    @Test func clear_removesValue() throws {
        let mailbox = AppGroupMailbox<DictationResult>(directory: tempDir(), filename: "r.json")
        try mailbox.write(DictationResult(text: "x", createdAt: Date()))
        mailbox.clear()
        #expect(try mailbox.read() == nil)
    }

    @Test func sessionMailbox_isIndependentOfResultMailbox() throws {
        let ipc = KeyboardIPC(directory: tempDir())
        try ipc.resultMailbox.write(DictationResult(text: "t", createdAt: Date(timeIntervalSince1970: 5)))
        try ipc.sessionMailbox.write(DictationSessionState(isActive: true, expiresAt: nil))
        #expect(try ipc.resultMailbox.read()?.text == "t")
        #expect(try ipc.sessionMailbox.read()?.isActive == true)
    }
}

@Suite struct DictationSessionStateTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func inactive_isNotUsable() {
        #expect(DictationSessionState.inactive.isUsable(at: now) == false)
    }

    @Test func active_withoutExpiry_isUsable() {
        let state = DictationSessionState(isActive: true, expiresAt: nil)
        #expect(state.isUsable(at: now) == true)
    }

    @Test func active_beforeExpiry_isUsable() {
        let state = DictationSessionState(isActive: true, expiresAt: now.addingTimeInterval(60))
        #expect(state.isUsable(at: now) == true)
    }

    @Test func active_afterExpiry_isNotUsable() {
        let state = DictationSessionState(isActive: true, expiresAt: now.addingTimeInterval(-1))
        #expect(state.isUsable(at: now) == false)
    }
}

@Suite struct IPCSignalTests {
    @Test func signalNames_areUnique() {
        let names = Set(IPCSignal.allCases.map(\.rawValue))
        #expect(names.count == IPCSignal.allCases.count)
    }
}
