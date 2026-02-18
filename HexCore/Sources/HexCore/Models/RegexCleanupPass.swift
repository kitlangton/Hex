//
//  RegexCleanupPass.swift
//  Hex
//

import Foundation

/// Deterministic regex-based transcript cleanup. Chains multiple passes:
/// filler removal → stutter collapsing → punctuation fix → whitespace → capitalization → terminal punctuation.
public enum RegexCleanupPass {
  public static func apply(_ text: String) -> String {
    guard !text.isEmpty else { return text }

    var output = text
    output = removeFillers(output)
    output = collapseStutters(output)
    output = fixPunctuation(output)
    output = normalizeWhitespace(output)
    output = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else { return "" }
    output = capitalizeSentences(output)
    output = ensureTerminalPunctuation(output)
    return output
  }

  // MARK: - Filler Removal

  /// Unconditional fillers: always removed regardless of position.
  private static let unconditionalFillers = [
    "um", "uh", "umm", "uhh", "erm", "hmm",
    "you know", "basically", "actually", "literally",
    "i mean", "right", "so yeah", "yeah",
    "okay so", "well basically",
  ]

  /// Context-dependent fillers: only removed at sentence start, after comma, or after another filler.
  /// These are words that have legitimate uses ("I like pizza", "so we left").
  private static let contextFillers = [
    "like", "so", "well", "okay",
  ]

  private static func removeFillers(_ text: String) -> String {
    var output = text

    // Remove unconditional fillers (whole-word, case-insensitive)
    for filler in unconditionalFillers {
      let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
      output = output.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    // Collapse whitespace between passes so context fillers can detect sentence boundaries
    output = output.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    output = output.trimmingCharacters(in: .whitespaces)

    // Remove context-dependent fillers only when they appear:
    // - At the start of text / after sentence-ending punctuation
    // - After a comma
    // Loop because removing one filler (e.g. "so") can expose another (e.g. "like") at sentence start.
    var changed = true
    while changed {
      let before = output
      for filler in contextFillers {
        let escaped = NSRegularExpression.escapedPattern(for: filler)
        // After comma: ", like ..." or ",like ..."
        output = output.replacingOccurrences(
          of: "(,\\s*)\(escaped)\\b\\s*",
          with: "$1",
          options: [.regularExpression, .caseInsensitive]
        )
        // At sentence start (beginning of string or after .!?)
        output = output.replacingOccurrences(
          of: "(?:^|(?<=[.!?]\\s))\(escaped)\\b[,]?\\s*",
          with: "",
          options: [.regularExpression, .caseInsensitive]
        )
      }
      output = output.trimmingCharacters(in: .whitespaces)
      changed = output != before
    }

    return output
  }

  // MARK: - Stutter / Repetition Collapsing

  private static func collapseStutters(_ text: String) -> String {
    var output = text
    // Collapse repeated words: "the the" → "the", "I I I" → "I"
    output = output.replacingOccurrences(
      of: "\\b(\\w+)(\\s+\\1)+\\b",
      with: "$1",
      options: [.regularExpression, .caseInsensitive]
    )
    return output
  }

  // MARK: - Punctuation Cleanup

  private static func fixPunctuation(_ text: String) -> String {
    var output = text
    // Collapse multiple spaces
    output = output.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    // Remove space before punctuation
    output = output.replacingOccurrences(of: "[ \\t]+([,.!?;:])", with: "$1", options: .regularExpression)
    // Collapse duplicate punctuation: ",," → ","
    output = output.replacingOccurrences(of: "([,.!?;:])\\s*\\1+", with: "$1", options: .regularExpression)
    // Remove orphaned punctuation at line start
    output = output.replacingOccurrences(of: "(?m)^[ \\t]*[,.!?;:]+[ \\t]*", with: "", options: .regularExpression)
    // Ensure space after punctuation (if followed by a letter)
    output = output.replacingOccurrences(of: "([,.!?;:])([A-Za-z])", with: "$1 $2", options: .regularExpression)
    return output
  }

  // MARK: - Sentence Capitalization

  private static func capitalizeSentences(_ text: String) -> String {
    var output = text
    // Capitalize first letter of the string
    if let first = output.first, first.isLowercase {
      output = first.uppercased() + output.dropFirst()
    }
    // Capitalize after sentence-ending punctuation
    var result = ""
    var capitalizeNext = false
    var afterPunctuation = false
    for char in output {
      if ".!?".contains(char) {
        afterPunctuation = true
        capitalizeNext = false
        result.append(char)
      } else if afterPunctuation && char.isWhitespace {
        capitalizeNext = true
        result.append(char)
      } else if capitalizeNext && char.isLetter {
        result.append(char.uppercased())
        capitalizeNext = false
        afterPunctuation = false
      } else {
        if char.isLetter {
          afterPunctuation = false
          capitalizeNext = false
        }
        result.append(char)
      }
    }
    return result
  }

  // MARK: - Terminal Punctuation

  private static func ensureTerminalPunctuation(_ text: String) -> String {
    guard let last = text.last else { return text }
    if ".!?".contains(last) { return text }
    return text + "."
  }

  // MARK: - Whitespace Normalization

  private static func normalizeWhitespace(_ text: String) -> String {
    var output = text
    // Collapse multiple spaces
    output = output.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    // Trim trailing whitespace per line
    output = output.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
    // Trim leading whitespace per line
    output = output.replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
    return output
  }
}
