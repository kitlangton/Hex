//
//  SubwordAlignment.swift
//  HexCore
//

import Foundation

/// Aligns subword-level model predictions to word-level edit tags.
///
/// GECToR outputs one prediction per subword token, but edits happen at the word level.
/// We use the **first-subword** approach: for each word, take its first subword token's
/// prediction as the edit for the entire word.
public enum SubwordAlignment {
  /// Default minimum confidence threshold. Predictions below this use `$KEEP`.
  public static let defaultMinConfidence: Float = 0.0

  /// Align model predictions to word-level edit tags.
  ///
  /// - Parameters:
  ///   - predictions: Per-token (tagIndex, confidence) pairs. Length = full sequence including BOS/EOS.
  ///   - wordBoundaries: Word-to-token mapping from the tokenizer.
  ///   - vocabulary: Tag vocabulary to convert indices to `EditTag`s.
  ///   - minConfidence: Predictions below this confidence threshold are replaced with KEEP.
  /// - Returns: One `EditTag` per input word.
  public static func align(
    predictions: [(tagIndex: Int, confidence: Float)],
    wordBoundaries: [WordBoundary],
    vocabulary: TagVocabulary,
    minConfidence: Float = defaultMinConfidence
  ) -> [EditTag] {
    wordBoundaries.map { boundary in
      let tokenOffset = boundary.startTokenOffset
      guard tokenOffset < predictions.count else { return EditTag.keep }

      let prediction = predictions[tokenOffset]

      // Below confidence threshold → keep
      if prediction.confidence < minConfidence {
        return EditTag.keep
      }

      return vocabulary.tag(at: prediction.tagIndex)
    }
  }

  /// Apply a sequence of edit tags to the original words to produce corrected text.
  ///
  /// - Parameters:
  ///   - words: Original whitespace-split words.
  ///   - tags: One `EditTag` per word (from `align`).
  ///   - verbForms: Verb conjugation dictionary for TRANSFORM_VERB operations.
  /// - Returns: Corrected text.
  public static func applyEdits(
    words: [String],
    tags: [EditTag],
    verbForms: VerbFormDictionary?
  ) -> String {
    guard words.count == tags.count else {
      return words.joined(separator: " ")
    }

    var result = [String]()

    for (index, (word, tag)) in zip(words, tags).enumerated() {
      switch tag {
      case .keep:
        result.append(word)

      case .delete:
        // Skip the word entirely
        continue

      case .append(let text):
        result.append(word)
        result.append(text)

      case .replace(let text):
        result.append(text)

      case .transformCase(let transform):
        result.append(applyCase(word, transform: transform))

      case .transformVerb(_, let to):
        if let conjugated = verbForms?.conjugate(word, to: to) {
          result.append(conjugated)
        } else if let regular = VerbFormDictionary.conjugateRegular(word, to: to) {
          result.append(regular)
        } else {
          result.append(word) // Can't conjugate; keep original
        }

      case .merge(let mergeType):
        // Merge this word with the next word
        if index + 1 < words.count {
          let separator = mergeType == .hyphen ? "-" : ""
          // Remove trailing space from current word before merging
          let trimmed = word.trimmingCharacters(in: .whitespaces)
          result.append(trimmed + separator)
        } else {
          result.append(word)
        }

      case .split(let splitType):
        switch splitType {
        case .hyphen:
          result.append(word.replacingOccurrences(of: "-", with: " "))
        }

      case .transformAgreement(let transform):
        result.append(applyAgreement(word, transform: transform))
      }
    }

    var text = result.joined(separator: " ")
    // Remove spaces before punctuation that can arise from edits
    text = text.replacingOccurrences(of: " .", with: ".")
    text = text.replacingOccurrences(of: " ,", with: ",")
    text = text.replacingOccurrences(of: " !", with: "!")
    text = text.replacingOccurrences(of: " ?", with: "?")
    text = text.replacingOccurrences(of: " ;", with: ";")
    text = text.replacingOccurrences(of: " :", with: ":")
    return text
  }

  // MARK: - Helpers

  private static func applyAgreement(_ word: String, transform: AgreementTransform) -> String {
    let lower = word.lowercased()
    let isCapitalized = word.first?.isUppercase == true

    let result: String
    switch transform {
    case .plural:
      if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("z")
          || lower.hasSuffix("sh") || lower.hasSuffix("ch") {
        result = word + "es"
      } else if lower.hasSuffix("y") && lower.count > 1 {
        let beforeY = lower[lower.index(lower.endIndex, offsetBy: -2)]
        if !"aeiou".contains(beforeY) {
          result = String(word.dropLast()) + "ies"
        } else {
          result = word + "s"
        }
      } else {
        result = word + "s"
      }
    case .singular:
      if lower.hasSuffix("ies") && lower.count > 3 {
        result = String(word.dropLast(3)) + "y"
      } else if lower.hasSuffix("ses") || lower.hasSuffix("xes") || lower.hasSuffix("zes")
                  || lower.hasSuffix("shes") || lower.hasSuffix("ches") {
        result = String(word.dropLast(2))
      } else if lower.hasSuffix("s") && !lower.hasSuffix("ss") {
        result = String(word.dropLast())
      } else {
        result = word
      }
    }

    if isCapitalized && !result.isEmpty {
      return result.prefix(1).uppercased() + result.dropFirst()
    }
    return result
  }

  private static func applyCase(_ word: String, transform: CaseTransform) -> String {
    switch transform {
    case .upper:
      return word.uppercased()
    case .lower:
      return word.lowercased()
    case .capital:
      return word.prefix(1).uppercased() + word.dropFirst().lowercased()
    case .capitalFirst:
      guard !word.isEmpty else { return word }
      return word.prefix(1).uppercased() + word.dropFirst()
    case .capitalSecond:
      guard word.count > 1 else { return word }
      let idx = word.index(word.startIndex, offsetBy: 1)
      let first = String(word.prefix(1))
      let second = String(word[idx...idx]).uppercased()
      let rest = String(word.dropFirst(2))
      return first + second + rest
    }
  }
}
