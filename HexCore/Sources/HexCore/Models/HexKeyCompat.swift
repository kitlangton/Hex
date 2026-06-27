//
//  HexKeyCompat.swift
//  HexCore
//
//  iOS stand-in for Sauce's `Key`.
//
//  On macOS, `Key` comes from the Sauce package (a Carbon-based keyboard
//  library that does not build on iOS). The hotkey concept is meaningless on
//  iOS, but shared types — `HotKey`, `KeyEvent`, `KeyboardCommand`, and through
//  them `HexSettings` — still embed a `Key?`, so the type must exist on iOS for
//  those to compile and to round-trip through Codable.
//
//  `Sauce.Key` is a `String`-raw-value enum conforming to `Codable`, which the
//  compiler encodes as its raw value inside a single-value container (e.g.
//  `Key.a` <-> "a"). This shim mirrors that exact wire format so settings stay
//  byte-compatible across platforms — important for future iCloud sync.
//

#if !os(macOS)
import Foundation

public struct Key: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Best-effort display string. The rich macOS mapping (symbols for arrows,
    /// space, escape, …) lives in the macOS-only `Key.toString` extension.
    public var toString: String { rawValue.uppercased() }

    // Presets referenced by cross-platform code (KeyboardCommand defaults, the
    // default paste hotkey, …). Raw values match Sauce's case names so they
    // round-trip across platforms.
    public static let `return` = Key(rawValue: "return")
    public static let v = Key(rawValue: "v")
    public static let escape = Key(rawValue: "escape")
}
#endif
