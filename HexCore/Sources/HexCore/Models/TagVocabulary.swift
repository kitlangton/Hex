//
//  TagVocabulary.swift
//  HexCore
//

import Foundation

/// The types of case transformations GECToR can predict.
public enum CaseTransform: String, Sendable, Equatable {
  case upper = "UPPER"
  case lower = "LOWER"
  case capital = "CAPITAL"
  case capitalFirst = "CAPITAL_1"  // capitalize first char only
  case capitalSecond = "CAPITAL_2" // capitalize second char only
}

/// Penn Treebank verb form tags used in GECToR's TRANSFORM_VERB operations.
public enum VerbTransform: String, Sendable, Equatable {
  case vb = "VB"     // base form: "go"
  case vbD = "VBD"   // past tense: "went"
  case vbG = "VBG"   // gerund: "going"
  case vbN = "VBN"   // past participle: "gone"
  case vbP = "VBP"   // non-3rd-person present: "go"
  case vbZ = "VBZ"   // 3rd-person singular present: "goes"
}

/// Types of merge operations.
public enum MergeType: String, Sendable, Equatable {
  case hyphen = "HYPHEN"  // merge with hyphen: "well known" → "well-known"
  case space = "SPACE"    // merge removing space
}

/// Types of split operations.
public enum SplitType: String, Sendable, Equatable {
  case hyphen = "HYPHEN"  // split on hyphen: "well-known" → "well known"
}

/// Noun number agreement transforms.
public enum AgreementTransform: String, Sendable, Equatable {
  case plural = "PLURAL"      // "cat" → "cats"
  case singular = "SINGULAR"  // "cats" → "cat"
}

/// A single edit operation predicted by GECToR for one token.
public enum EditTag: Sendable, Equatable {
  case keep
  case delete
  case append(String)
  case replace(String)
  case transformCase(CaseTransform)
  case transformVerb(from: VerbTransform, to: VerbTransform)
  case merge(MergeType)
  case split(SplitType)
  case transformAgreement(AgreementTransform)
}

/// Parses the GECToR label vocabulary (labels.txt) into structured `EditTag` values.
public struct TagVocabulary: Sendable {
  private let tags: [EditTag]

  /// Index of the `$KEEP` tag.
  public let keepTagIndex: Int

  /// Total number of tags.
  public var count: Int { tags.count }

  /// Initialize from raw labels data (one tag per line).
  public init(labelsData: Data) throws {
    guard let text = String(data: labelsData, encoding: .utf8) else {
      throw TagVocabularyError.invalidData
    }

    let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard !lines.isEmpty else {
      throw TagVocabularyError.emptyLabels
    }

    var parsedTags = [EditTag]()
    parsedTags.reserveCapacity(lines.count)
    var keepIdx: Int?

    for (index, line) in lines.enumerated() {
      let tag = Self.parse(line)
      parsedTags.append(tag)
      if case .keep = tag {
        keepIdx = index
      }
    }

    guard let foundKeepIdx = keepIdx else {
      throw TagVocabularyError.missingKeepTag
    }

    self.tags = parsedTags
    self.keepTagIndex = foundKeepIdx
  }

  /// Look up the edit tag at a given index.
  public func tag(at index: Int) -> EditTag {
    guard index >= 0 && index < tags.count else { return .keep }
    return tags[index]
  }

  // MARK: - Parsing

  /// Parse a single label string into an `EditTag`.
  static func parse(_ label: String) -> EditTag {
    switch label {
    case "$KEEP":
      return .keep
    case "$DELETE":
      return .delete
    default:
      break
    }

    // $APPEND_xxx
    if label.hasPrefix("$APPEND_") {
      let payload = String(label.dropFirst("$APPEND_".count))
      return .append(payload)
    }

    // $REPLACE_xxx
    if label.hasPrefix("$REPLACE_") {
      let payload = String(label.dropFirst("$REPLACE_".count))
      return .replace(payload)
    }

    // $TRANSFORM_CASE_UPPER / LOWER / CAPITAL / CAPITAL_1 / CAPITAL_2
    if label.hasPrefix("$TRANSFORM_CASE_") {
      let raw = String(label.dropFirst("$TRANSFORM_CASE_".count))
      if let transform = CaseTransform(rawValue: raw) {
        return .transformCase(transform)
      }
    }

    // $TRANSFORM_VERB_VB_VBD (from_to)
    if label.hasPrefix("$TRANSFORM_VERB_") {
      let raw = String(label.dropFirst("$TRANSFORM_VERB_".count))
      let parts = raw.split(separator: "_", maxSplits: 1)
      if parts.count == 2,
         let from = VerbTransform(rawValue: String(parts[0])),
         let to = VerbTransform(rawValue: String(parts[1])) {
        return .transformVerb(from: from, to: to)
      }
    }

    // $MERGE_HYPHEN / $MERGE_SPACE
    if label.hasPrefix("$MERGE_") {
      let raw = String(label.dropFirst("$MERGE_".count))
      if let mergeType = MergeType(rawValue: raw) {
        return .merge(mergeType)
      }
    }

    // $SPLIT_HYPHEN
    if label.hasPrefix("$SPLIT_") {
      let raw = String(label.dropFirst("$SPLIT_".count))
      if let splitType = SplitType(rawValue: raw) {
        return .split(splitType)
      }
    }

    // $TRANSFORM_AGREEMENT_PLURAL / $TRANSFORM_AGREEMENT_SINGULAR
    if label.hasPrefix("$TRANSFORM_AGREEMENT_") {
      let raw = String(label.dropFirst("$TRANSFORM_AGREEMENT_".count))
      if let transform = AgreementTransform(rawValue: raw) {
        return .transformAgreement(transform)
      }
    }

    // <OOV> and other unknown tags are treated as KEEP for safety
    return .keep
  }
}

// MARK: - Errors

public enum TagVocabularyError: Error, LocalizedError {
  case invalidData
  case emptyLabels
  case missingKeepTag

  public var errorDescription: String? {
    switch self {
    case .invalidData: return "Failed to decode labels data as UTF-8"
    case .emptyLabels: return "Labels file is empty"
    case .missingKeepTag: return "Labels file does not contain a $KEEP tag"
    }
  }
}
