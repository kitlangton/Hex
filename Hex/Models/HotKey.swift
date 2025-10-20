//
//  Modifier.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//
import Cocoa
import Sauce

// MARK: - Modifier Side
public enum ModifierSide: String, Codable, Equatable {
  case left
  case right
  case either
}

// MARK: - Modifier
public enum Modifier: Identifiable, Codable, Equatable, Hashable, Comparable {
  case command(ModifierSide = .either)
  case option(ModifierSide = .either)
  case shift(ModifierSide = .either)
  case control(ModifierSide = .either)
  case fn

  // For backward compatibility during decoding
  private enum CodingKeys: String, CodingKey {
    case type, side
  }

  public enum ModifierType: String, Codable {
    case command, option, shift, control, fn
  }

  public init(from decoder: Decoder) throws {
    // Try to decode as a single value string first (old format)
    do {
      let singleValue = try decoder.singleValueContainer()
      let oldValue = try singleValue.decode(String.self)

      // Handle old format
      switch oldValue {
      case "command": self = .command()
      case "option": self = .option()
      case "shift": self = .shift()
      case "control": self = .control()
      case "fn": self = .fn
      default:
        throw DecodingError.dataCorruptedError(
          in: singleValue,
          debugDescription: "Unknown modifier: \(oldValue)"
        )
      }
      return
    } catch {
      // If single value decode failed, try keyed container (new format)
    }

    // Handle new format with side information
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(ModifierType.self, forKey: .type)
    let side = try container.decodeIfPresent(ModifierSide.self, forKey: .side) ?? .either

    switch type {
    case .command: self = .command(side)
    case .option: self = .option(side)
    case .shift: self = .shift(side)
    case .control: self = .control(side)
    case .fn: self = .fn
    }
  }

  public func encode(to encoder: Encoder) throws {
    // For backward compatibility, encode as simple string when side is .either
    switch self {
    case .command(let side) where side == .either:
      var container = encoder.singleValueContainer()
      try container.encode("command")
    case .option(let side) where side == .either:
      var container = encoder.singleValueContainer()
      try container.encode("option")
    case .shift(let side) where side == .either:
      var container = encoder.singleValueContainer()
      try container.encode("shift")
    case .control(let side) where side == .either:
      var container = encoder.singleValueContainer()
      try container.encode("control")
    case .fn:
      var container = encoder.singleValueContainer()
      try container.encode("fn")
    default:
      // For specific left/right sides, use the new format
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .command(let side):
        try container.encode(ModifierType.command, forKey: .type)
        try container.encode(side, forKey: .side)
      case .option(let side):
        try container.encode(ModifierType.option, forKey: .type)
        try container.encode(side, forKey: .side)
      case .shift(let side):
        try container.encode(ModifierType.shift, forKey: .type)
        try container.encode(side, forKey: .side)
      case .control(let side):
        try container.encode(ModifierType.control, forKey: .type)
        try container.encode(side, forKey: .side)
      case .fn:
        try container.encode(ModifierType.fn, forKey: .type)
      }
    }
  }

  public var id: String {
    switch self {
    case .command(let side): return "command_\(side.rawValue)"
    case .option(let side): return "option_\(side.rawValue)"
    case .shift(let side): return "shift_\(side.rawValue)"
    case .control(let side): return "control_\(side.rawValue)"
    case .fn: return "fn"
    }
  }

  public var baseType: ModifierType {
    switch self {
    case .command: return .command
    case .option: return .option
    case .shift: return .shift
    case .control: return .control
    case .fn: return .fn
    }
  }

  public var side: ModifierSide? {
    switch self {
    case .command(let side), .option(let side), .shift(let side), .control(let side):
      return side
    case .fn:
      return nil
    }
  }

  public var stringValue: String {
    let baseSymbol: String
    switch self {
    case .option: baseSymbol = "⌥"
    case .shift: baseSymbol = "⇧"
    case .command: baseSymbol = "⌘"
    case .control: baseSymbol = "⌃"
    case .fn: return "fn"
    }

    // Add L/R prefix for specific sides
    if let side = self.side, side != .either {
      return "\(side == .left ? "L" : "R")\(baseSymbol)"
    }
    return baseSymbol
  }

  // For Comparable conformance
  public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
    // First compare by base type
    if lhs.baseType != rhs.baseType {
      return lhs.baseType.rawValue < rhs.baseType.rawValue
    }
    // Then by side (either < left < right)
    let lhsSide = lhs.side?.rawValue ?? "either"
    let rhsSide = rhs.side?.rawValue ?? "either"
    return lhsSide < rhsSide
  }

  // Check if this modifier matches another (considering sides)
  public func matches(_ other: Modifier) -> Bool {
    // Must be same base type
    guard self.baseType == other.baseType else { return false }

    // Handle fn key (no sides)
    if case .fn = self { return true }

    // Check side compatibility
    guard let thisSide = self.side, let otherSide = other.side else { return false }

    // Either matches everything
    if thisSide == .either || otherSide == .either { return true }

    // Otherwise must be exact match
    return thisSide == otherSide
  }
}

public struct Modifiers: Codable, Equatable, ExpressibleByArrayLiteral {
  var modifiers: Set<Modifier>

  // Custom Codable implementation for backward compatibility
  private enum CodingKeys: String, CodingKey {
    case modifiers
  }

  public init(from decoder: Decoder) throws {
    // First try to decode as a direct array (old format)
    if let singleContainer = try? decoder.singleValueContainer(),
       let modifierArray = try? singleContainer.decode([Modifier].self) {
      self.modifiers = Set(modifierArray)
    } else {
      // Otherwise decode as object with modifiers key (new format)
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let modifierArray = try container.decode([Modifier].self, forKey: .modifiers)
      self.modifiers = Set(modifierArray)
    }
  }

  public func encode(to encoder: Encoder) throws {
    // Always encode as a direct array for simplicity and backward compatibility
    var singleContainer = encoder.singleValueContainer()
    try singleContainer.encode(Array(modifiers))
  }

  var sorted: [Modifier] {
    // If this is a hyperkey combination (all four modifiers), 
    // return an empty array as we'll display a special symbol
    if isHyperkey {
      return []
    }
    return modifiers.sorted()
  }
  
  public var isHyperkey: Bool {
    return containsBaseType(.command) &&
           containsBaseType(.option) &&
           containsBaseType(.shift) &&
           containsBaseType(.control)
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

  // Check if any modifier with the same base type exists
  public func containsBaseType(_ baseType: Modifier.ModifierType) -> Bool {
    modifiers.contains { $0.baseType == baseType }
  }

  // Check if this set matches another considering side compatibility
  public func matches(_ other: Modifiers) -> Bool {
    // For each modifier in self, there must be a matching one in other
    for modifier in modifiers {
      var found = false
      for otherModifier in other.modifiers {
        if modifier.matches(otherModifier) {
          found = true
          break
        }
      }
      if !found { return false }
    }

    // And vice versa - each modifier in other must match one in self
    for otherModifier in other.modifiers {
      var found = false
      for modifier in modifiers {
        if otherModifier.matches(modifier) {
          found = true
          break
        }
      }
      if !found { return false }
    }

    return true
  }

  // Check if this is a subset considering side compatibility
  public func isSubset(of other: Modifiers) -> Bool {
    // For modifier-only hotkeys, check if all our modifiers match something in other
    for modifier in modifiers {
      var found = false
      for otherModifier in other.modifiers {
        if modifier.matches(otherModifier) {
          found = true
          break
        }
      }
      if !found { return false }
    }
    return true
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
    // For Cocoa flags, we default to .either since NSEvent doesn't provide side info
    if cocoa.contains(.option) {
      modifiers.insert(.option(.either))
    }
    if cocoa.contains(.shift) {
      modifiers.insert(.shift(.either))
    }
    if cocoa.contains(.command) {
      modifiers.insert(.command(.either))
    }
    if cocoa.contains(.control) {
      modifiers.insert(.control(.either))
    }
    if cocoa.contains(.function) {
      modifiers.insert(.fn)
    }
    return .init(modifiers: modifiers)
  }

  // Device-specific modifier masks from IOKit
  // These allow us to detect left vs right modifiers
  private static let NX_DEVICELCTLKEYMASK: UInt64    = 0x00000001
  private static let NX_DEVICELSHIFTKEYMASK: UInt64  = 0x00000002
  private static let NX_DEVICERSHIFTKEYMASK: UInt64  = 0x00000004
  private static let NX_DEVICELCMDKEYMASK: UInt64    = 0x00000008
  private static let NX_DEVICERCMDKEYMASK: UInt64    = 0x00000010
  private static let NX_DEVICELALTKEYMASK: UInt64    = 0x00000020
  private static let NX_DEVICERALTKEYMASK: UInt64    = 0x00000040
  private static let NX_DEVICERCTLKEYMASK: UInt64    = 0x00002000

  public static func from(carbonFlags: CGEventFlags) -> Modifiers {
    var modifiers: Set<Modifier> = []
    let rawFlags = carbonFlags.rawValue

    // Check for Shift keys
    if carbonFlags.contains(.maskShift) {
      // Try to determine left/right from device-specific flags
      let hasLeftShift = (rawFlags & NX_DEVICELSHIFTKEYMASK) != 0
      let hasRightShift = (rawFlags & NX_DEVICERSHIFTKEYMASK) != 0

      if hasLeftShift && !hasRightShift {
        modifiers.insert(.shift(.left))
      } else if hasRightShift && !hasLeftShift {
        modifiers.insert(.shift(.right))
      } else {
        // Either both or indeterminate - use either
        modifiers.insert(.shift(.either))
      }
    }

    // Check for Control keys
    if carbonFlags.contains(.maskControl) {
      let hasLeftControl = (rawFlags & NX_DEVICELCTLKEYMASK) != 0
      let hasRightControl = (rawFlags & NX_DEVICERCTLKEYMASK) != 0

      if hasLeftControl && !hasRightControl {
        modifiers.insert(.control(.left))
      } else if hasRightControl && !hasLeftControl {
        modifiers.insert(.control(.right))
      } else {
        modifiers.insert(.control(.either))
      }
    }

    // Check for Option/Alt keys
    if carbonFlags.contains(.maskAlternate) {
      let hasLeftAlt = (rawFlags & NX_DEVICELALTKEYMASK) != 0
      let hasRightAlt = (rawFlags & NX_DEVICERALTKEYMASK) != 0

      if hasLeftAlt && !hasRightAlt {
        modifiers.insert(.option(.left))
      } else if hasRightAlt && !hasLeftAlt {
        modifiers.insert(.option(.right))
      } else {
        modifiers.insert(.option(.either))
      }
    }

    // Check for Command keys
    if carbonFlags.contains(.maskCommand) {
      let hasLeftCmd = (rawFlags & NX_DEVICELCMDKEYMASK) != 0
      let hasRightCmd = (rawFlags & NX_DEVICERCMDKEYMASK) != 0

      if hasLeftCmd && !hasRightCmd {
        modifiers.insert(.command(.left))
      } else if hasRightCmd && !hasLeftCmd {
        modifiers.insert(.command(.right))
      } else {
        modifiers.insert(.command(.either))
      }
    }

    // Check for Function key
    if carbonFlags.contains(.maskSecondaryFn) {
      modifiers.insert(.fn)
    }

    return .init(modifiers: modifiers)
  }
}

public struct HotKey: Codable, Equatable {
  public var key: Key?
  public var modifiers: Modifiers
}

extension Key {
  var toString: String {
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
