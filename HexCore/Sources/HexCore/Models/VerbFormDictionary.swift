//
//  VerbFormDictionary.swift
//  HexCore
//

import Foundation

/// Lookup table for irregular verb conjugation.
///
/// Loaded from `verb_forms.json`, which maps each known conjugated form
/// to its full set of Penn Treebank verb forms (VB, VBD, VBG, VBN, VBP, VBZ).
public struct VerbFormDictionary: Sendable {
  /// Maps lowercase word → { "VBD": "went", "VBZ": "goes", ... }
  private let forms: [String: [String: String]]

  public init(jsonData: Data) throws {
    guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: [String: String]] else {
      throw VerbFormError.invalidJSON
    }
    self.forms = dict
  }

  /// Conjugate a word to the target verb form.
  /// Returns `nil` if the word is not in the dictionary or the target form is unavailable.
  public func conjugate(_ word: String, to form: VerbTransform) -> String? {
    let lower = word.lowercased()
    guard let wordForms = forms[lower] else { return nil }
    guard let conjugated = wordForms[form.rawValue] else { return nil }

    // Preserve original capitalization pattern
    if word.first?.isUppercase == true {
      return conjugated.prefix(1).uppercased() + conjugated.dropFirst()
    }
    return conjugated
  }
}

// MARK: - Regular Verb Fallback

extension VerbFormDictionary {
  /// Apply regular English verb conjugation rules as a fallback.
  /// Only handles common regular patterns; returns nil for irregular verbs.
  public static func conjugateRegular(_ word: String, to form: VerbTransform) -> String? {
    let lower = word.lowercased()
    guard !lower.isEmpty else { return nil }

    switch form {
    case .vb, .vbP:
      // Base form — can't reliably reverse from other forms
      return nil
    case .vbZ:
      // 3rd person singular: add -s/-es/-ies
      if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("z")
          || lower.hasSuffix("ch") || lower.hasSuffix("sh") {
        return lower + "es"
      } else if lower.hasSuffix("y") && lower.count > 1 {
        let beforeY = lower[lower.index(lower.endIndex, offsetBy: -2)]
        if !"aeiou".contains(beforeY) {
          return String(lower.dropLast()) + "ies"
        }
      }
      return lower + "s"
    case .vbG:
      // Gerund: add -ing
      if lower.hasSuffix("ie") {
        return String(lower.dropLast(2)) + "ying"
      } else if lower.hasSuffix("e") && !lower.hasSuffix("ee") {
        return String(lower.dropLast()) + "ing"
      }
      return lower + "ing"
    case .vbD, .vbN:
      // Past tense / past participle: add -ed/-d/-ied
      if lower.hasSuffix("e") {
        return lower + "d"
      } else if lower.hasSuffix("y") && lower.count > 1 {
        let beforeY = lower[lower.index(lower.endIndex, offsetBy: -2)]
        if !"aeiou".contains(beforeY) {
          return String(lower.dropLast()) + "ied"
        }
      }
      return lower + "ed"
    }
  }
}

// MARK: - Errors

public enum VerbFormError: Error, LocalizedError {
  case invalidJSON

  public var errorDescription: String? {
    switch self {
    case .invalidJSON: return "Failed to parse verb forms JSON"
    }
  }
}
