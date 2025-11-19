//
//  KeyboardCommand.swift
//  HexCore
//
//  Created for auto-send feature
//

import Foundation
import Sauce

/// Represents a keyboard command to simulate (e.g., Enter, Cmd+Enter, Shift+Enter)
public struct KeyboardCommand: Codable, Equatable, Sendable {
	public var key: Key?
	public var modifiers: Modifiers
	
	public init(key: Key?, modifiers: Modifiers = .init(modifiers: [])) {
		self.key = key
		self.modifiers = modifiers
	}
	
	/// Human-readable display name using modifier symbols and key
	public var displayName: String {
		let modString = modifiers.sorted.map(\.kind.symbol).joined()
		let keyString = key?.toString ?? ""
		return modString + keyString
	}
	
	// MARK: - Common Presets
	
	/// Plain Enter key
	public static let enter = KeyboardCommand(key: .return)
	
	/// Cmd+Enter
	public static let cmdEnter = KeyboardCommand(key: .return, modifiers: [.command])
	
	/// Shift+Enter
	public static let shiftEnter = KeyboardCommand(key: .return, modifiers: [.shift])
}
