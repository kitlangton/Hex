//
//  AppGroupMailbox.swift
//  HexCore
//
//  A tiny file-backed "mailbox" for passing a single Codable value between the
//  iOS host app and the keyboard extension through their shared App Group
//  container.
//
//  Keyboard extensions cannot record audio, so the host app does the work and
//  drops the result here; the keyboard reads it and inserts the text. Darwin
//  notifications (see DarwinSignal) tell the other side when to look.
//
//  The directory is injected rather than resolved internally so the type is
//  unit-testable against a temp directory without a real App Group entitlement.
//

import Foundation

public struct AppGroupMailbox<Value: Codable & Sendable>: Sendable {
    private let fileURL: URL

    /// - Parameters:
    ///   - directory: the container directory (App Group container in production,
    ///     a temp directory in tests).
    ///   - filename: the file the value is stored under (e.g. "dictation-result.json").
    public init(directory: URL, filename: String) {
        self.fileURL = directory.appendingPathComponent(filename)
    }

    /// Resolve the App Group container for `groupIdentifier`, returning nil if the
    /// entitlement is missing/misconfigured.
    public static func appGroupDirectory(_ groupIdentifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    /// Atomically write `value`, encoded as JSON.
    public func write(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Read the stored value, or nil if nothing has been written yet.
    public func read() throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// Remove the stored value, if any.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
