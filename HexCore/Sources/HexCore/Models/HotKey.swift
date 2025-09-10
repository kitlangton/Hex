//
//  Modifier.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//
import Cocoa
import Sauce

public enum Modifier: Identifiable, Codable, Equatable, Hashable, Comparable {
  case command
  case option
  case shift
  case control
  case fn

  public var id: Self { self }

  public var stringValue: String {
    switch self {
    case .option:
      return "⌥"
    case .shift:
      return "⇧"
    case .command:
      return "⌘"
    case .control:
      return "⌃"
    case .fn:
      return "fn"
    }
  }
}

public struct Modifiers: Codable, Equatable, ExpressibleByArrayLiteral {
  var modifiers: Set<Modifier>

  public var sorted: [Modifier] {
    // If this is a hyperkey combination (all four modifiers), 
    // return an empty array as we'll display a special symbol
    if isHyperkey {
      return []
    }
    return modifiers.sorted()
  }
  
  public var isHyperkey: Bool {
    return modifiers.contains(.command) && 
           modifiers.contains(.option) && 
           modifiers.contains(.shift) && 
           modifiers.contains(.control)
  }

  public var isEmpty: Bool {
    modifiers.isEmpty
  }

  public init(modifiers: Set<Modifier>) {
    self.modifiers = modifiers
  }

  public init(arrayLiteral elements: Modifier...) {
    modifiers = Set(elements)
  }

  public func contains(_ modifier: Modifier) -> Bool {
    modifiers.contains(modifier)
  }

  public func isSubset(of other: Modifiers) -> Bool {
    modifiers.isSubset(of: other.modifiers)
  }

  public func isDisjoint(with other: Modifiers) -> Bool {
    modifiers.isDisjoint(with: other.modifiers)
  }

  public func union(_ other: Modifiers) -> Modifiers {
    Modifiers(modifiers: modifiers.union(other.modifiers))
  }

  public func intersection(_ other: Modifiers) -> Modifiers {
    Modifiers(modifiers: modifiers.intersection(other.modifiers))
  }

  public static func from(cocoa: NSEvent.ModifierFlags) -> Self {
    var modifiers: Set<Modifier> = []
    if cocoa.contains(.option) {
      modifiers.insert(.option)
    }
    if cocoa.contains(.shift) {
      modifiers.insert(.shift)
    }
    if cocoa.contains(.command) {
      modifiers.insert(.command)
    }
    if cocoa.contains(.control) {
      modifiers.insert(.control)
    }
    if cocoa.contains(.function) {
      modifiers.insert(.fn)
    }
    return .init(modifiers: modifiers)
  }

  public static func from(carbonFlags: CGEventFlags) -> Modifiers {
    var modifiers: Set<Modifier> = []
    if carbonFlags.contains(.maskShift) { modifiers.insert(.shift) }
    if carbonFlags.contains(.maskControl) { modifiers.insert(.control) }
    if carbonFlags.contains(.maskAlternate) { modifiers.insert(.option) }
    if carbonFlags.contains(.maskCommand) { modifiers.insert(.command) }
    if carbonFlags.contains(.maskSecondaryFn) { modifiers.insert(.fn) }
    return .init(modifiers: modifiers)
  }
}

public struct HotKey: Codable, Equatable {
  public var key: Key?
  public var modifiers: Modifiers

  // Public memberwise initializer so external modules can construct HotKey
  public init(key: Key?, modifiers: Modifiers) {
    self.key = key
    self.modifiers = modifiers
  }
}

extension Key {
  public var toString: String {
    switch self {
    case .escape:
      return "⎋"
    case .zero:
      return "0"
    case .one:
      return "1"
    case .two:
      return "2"
    case .three:
      return "3"
    case .four:
      return "4"
    case .five:
      return "5"
    case .six:
      return "6"
    case .seven:
      return "7"
    case .eight:
      return "8"
    case .nine:
      return "9"
    case .period:
      return "."
    case .comma:
      return ","
    case .slash:
      return "/"
    case .quote:
      return "\""
    case .backslash:
      return "\\"
    default:
      return rawValue.uppercased()
    }
  }
}
