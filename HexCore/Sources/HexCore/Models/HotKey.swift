//
//  Modifier.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//
import Cocoa
import Sauce

public struct Modifier: Identifiable, Codable, Equatable, Hashable, Comparable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Comparable, Sendable {
    case command
    case option
    case shift
    case control
    case fn

    var order: Int {
      switch self {
      case .command: return 0
      case .option: return 1
      case .shift: return 2
      case .control: return 3
      case .fn: return 4
      }
    }

    public var displayName: String {
      switch self {
      case .command: return "Command"
      case .option: return "Option"
      case .shift: return "Shift"
      case .control: return "Control"
      case .fn: return "fn"
      }
    }

    public var symbol: String {
      switch self {
      case .option: return "⌥"
      case .shift: return "⇧"
      case .command: return "⌘"
      case .control: return "⌃"
      case .fn: return "fn"
      }
    }

    public var supportsSideSelection: Bool {
      switch self {
      case .fn:
        return false
      default:
        return true
      }
    }

    public static func < (lhs: Kind, rhs: Kind) -> Bool {
      lhs.order < rhs.order
    }
  }

  public enum Side: String, Codable, CaseIterable, Comparable, Sendable {
    case either
    case left
    case right

    var order: Int {
      switch self {
      case .left: return 0
      case .either: return 1
      case .right: return 2
      }
    }

    public var displayName: String {
      switch self {
      case .either: return "Either"
      case .left: return "Left"
      case .right: return "Right"
      }
    }

    public static func < (lhs: Side, rhs: Side) -> Bool {
      lhs.order < rhs.order
    }
  }

  public var kind: Kind
  public var side: Side

  public var id: String { "\(kind.rawValue)-\(side.rawValue)" }

  public init(kind: Kind, side: Side = .either) {
    self.kind = kind
    self.side = side
  }

  public static let command = Modifier(kind: .command)
  public static let option = Modifier(kind: .option)
  public static let shift = Modifier(kind: .shift)
  public static let control = Modifier(kind: .control)
  public static let fn = Modifier(kind: .fn)

  public func with(side: Side) -> Modifier {
    Modifier(kind: kind, side: side)
  }

  public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
    if lhs.kind == rhs.kind {
      return lhs.side.order < rhs.side.order
    }
    return lhs.kind.order < rhs.kind.order
  }

  public var stringValue: String {
    switch side {
    case .either:
      return kind.symbol
    case .left:
      return "\(kind.symbol)L"
    case .right:
      return "\(kind.symbol)R"
    }
  }

  func matches(_ other: Modifier) -> Bool {
    guard kind == other.kind else { return false }
    if side == .either || other.side == .either { return true }
    return side == other.side
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case side
  }

  public init(from decoder: Decoder) throws {
    if let single = try? decoder.singleValueContainer() {
      if let legacyRaw = try? single.decode(String.self), let kind = Kind(rawValue: legacyRaw) {
        self.init(kind: kind, side: .either)
        return
      }
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    let side = try container.decodeIfPresent(Side.self, forKey: .side) ?? .either
    self.init(kind: kind, side: side)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(side, forKey: .side)
  }
}

public struct Modifiers: Codable, Equatable, ExpressibleByArrayLiteral, Sendable {
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
    return contains(kind: .command) &&
      contains(kind: .option) &&
      contains(kind: .shift) &&
      contains(kind: .control)
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
    modifiers.contains(where: { $0.matches(modifier) })
  }

  public func contains(kind: Modifier.Kind) -> Bool {
    modifiers.contains(where: { $0.kind == kind })
  }

  public var kinds: [Modifier.Kind] {
    Array(Set(modifiers.map { $0.kind })).sorted()
  }

  public func isSubset(of other: Modifiers) -> Bool {
    modifiers.allSatisfy { element in
      other.contains(element)
    }
  }

  public func isDisjoint(with other: Modifiers) -> Bool {
    modifiers.allSatisfy { element in
      !other.contains(element)
    }
  }

  public func union(_ other: Modifiers) -> Modifiers {
    Modifiers(modifiers: modifiers.union(other.modifiers))
  }

  public func intersection(_ other: Modifiers) -> Modifiers {
    Modifiers(modifiers: modifiers.intersection(other.modifiers))
  }

  public func matchesExactly(_ expected: Modifiers) -> Bool {
    guard expected.modifiers.allSatisfy({ requirement in self.contains(requirement) }) else {
      return false
    }

    let allowedKinds = Set(expected.modifiers.map { $0.kind })

    return modifiers.allSatisfy { candidate in
      guard allowedKinds.contains(candidate.kind) else { return false }
      guard let requirement = expected.modifiers.first(where: { $0.kind == candidate.kind }) else {
        return false
      }
      return candidate.matches(requirement)
    }
  }

  public func side(for kind: Modifier.Kind) -> Modifier.Side? {
    modifiers.first(where: { $0.kind == kind })?.side
  }

  public func setting(kind: Modifier.Kind, to side: Modifier.Side) -> Modifiers {
    var updated = modifiers
    for element in modifiers where element.kind == kind {
      updated.remove(element)
    }
    updated.insert(Modifier(kind: kind, side: side))
    return Modifiers(modifiers: updated)
  }

  public func erasingSides() -> Modifiers {
    Modifiers(modifiers: Set(modifiers.map { Modifier(kind: $0.kind, side: .either) }))
  }

  public func removing(kind: Modifier.Kind) -> Modifiers {
    Modifiers(modifiers: modifiers.filter { $0.kind != kind })
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

    func insert(kind: Modifier.Kind, general: CGEventFlags, leftMask: UInt64?, rightMask: UInt64?) {
      var insertedSpecific = false
      if let leftMask, carbonFlags.rawValue & leftMask != 0 {
        modifiers.insert(Modifier(kind: kind, side: .left))
        insertedSpecific = true
      }
      if let rightMask, carbonFlags.rawValue & rightMask != 0 {
        modifiers.insert(Modifier(kind: kind, side: .right))
        insertedSpecific = true
      }

      if !insertedSpecific, carbonFlags.contains(general) {
        modifiers.insert(Modifier(kind: kind, side: .either))
      }
    }

    insert(kind: .shift, general: .maskShift, leftMask: DeviceModifierMask.leftShift, rightMask: DeviceModifierMask.rightShift)
    insert(kind: .control, general: .maskControl, leftMask: DeviceModifierMask.leftControl, rightMask: DeviceModifierMask.rightControl)
    insert(kind: .option, general: .maskAlternate, leftMask: DeviceModifierMask.leftOption, rightMask: DeviceModifierMask.rightOption)
    insert(kind: .command, general: .maskCommand, leftMask: DeviceModifierMask.leftCommand, rightMask: DeviceModifierMask.rightCommand)

    if carbonFlags.contains(.maskSecondaryFn) {
      modifiers.insert(.fn)
    }

    return .init(modifiers: modifiers)
  }
}

private enum DeviceModifierMask {
  static let leftControl: UInt64 = 0x00000001
  static let leftShift: UInt64 = 0x00000002
  static let rightShift: UInt64 = 0x00000004
  static let leftCommand: UInt64 = 0x00000008
  static let rightCommand: UInt64 = 0x00000010
  static let leftOption: UInt64 = 0x00000020
  static let rightOption: UInt64 = 0x00000040
  static let rightControl: UInt64 = 0x00002000
}

public struct HotKey: Codable, Equatable, Sendable {
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
    case .leftArrow:
      return "←"
    case .rightArrow:
      return "→"
    case .upArrow:
      return "↑"
    case .downArrow:
      return "↓"
    default:
      return rawValue.uppercased()
    }
  }
}
