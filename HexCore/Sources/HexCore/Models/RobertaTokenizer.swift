//
//  RobertaTokenizer.swift
//  HexCore
//

import Foundation

/// Tracks which subword tokens correspond to which input word.
public struct WordBoundary: Sendable, Equatable {
  /// Index of the whitespace-split word (0-based).
  public let wordIndex: Int
  /// Inclusive start offset into token IDs (after BOS).
  public let startTokenOffset: Int
  /// Exclusive end offset into token IDs.
  public let endTokenOffset: Int

  public init(wordIndex: Int, startTokenOffset: Int, endTokenOffset: Int) {
    self.wordIndex = wordIndex
    self.startTokenOffset = startTokenOffset
    self.endTokenOffset = endTokenOffset
  }
}

/// Byte-level BPE tokenizer compatible with RoBERTa / GPT-2 vocabulary.
///
/// Encodes text into token IDs using the same algorithm as HuggingFace's
/// `RobertaTokenizerFast`: byte-level BPE with `Ġ` (U+0120) as the space prefix.
public struct RobertaTokenizer: Sendable {
  // MARK: - Constants

  private static let bosTokenId = 0    // <s>
  private static let eosTokenId = 2    // </s>
  private static let padTokenId = 1    // <pad>
  private static let unkTokenId = 3    // <unk>

  // MARK: - Stored Properties

  /// Maps token string → token ID.
  private let encoder: [String: Int]
  /// Maps token ID → token string.
  private let decoder: [Int: String]
  /// Ordered BPE merge rules as (first, second) pairs.
  private let bpeMerges: [(String, String)]
  /// Merge priority: (first, second) → rank (lower = higher priority).
  private let bpeRanks: [StringPair: Int]

  // Byte-to-unicode and unicode-to-byte mappings (GPT-2 style).
  private let byteEncoder: [UInt8: Character]
  private let byteDecoder: [Character: UInt8]

  // MARK: - Init

  public init(vocabData: Data, mergesData: Data) throws {
    // Parse vocab JSON: { "token": id, ... }
    guard let vocabDict = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
      throw TokenizerError.invalidVocab
    }
    self.encoder = vocabDict

    var dec = [Int: String]()
    dec.reserveCapacity(vocabDict.count)
    for (token, id) in vocabDict {
      dec[id] = token
    }
    self.decoder = dec

    // Parse merges file (first line is header "#version: ...", skip it)
    guard let mergesString = String(data: mergesData, encoding: .utf8) else {
      throw TokenizerError.invalidMerges
    }
    let lines = mergesString.components(separatedBy: "\n")
    var merges = [(String, String)]()
    var ranks = [StringPair: Int]()
    var rank = 0
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let parts = trimmed.split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let pair = (String(parts[0]), String(parts[1]))
      merges.append(pair)
      ranks[StringPair(pair.0, pair.1)] = rank
      rank += 1
    }
    self.bpeMerges = merges
    self.bpeRanks = ranks

    // Build byte encoder/decoder (GPT-2 byte-to-unicode mapping)
    let (be, bd) = Self.buildByteMapping()
    self.byteEncoder = be
    self.byteDecoder = bd
  }

  // MARK: - Public API

  /// Encode text to token IDs with BOS/EOS framing, plus word boundary info.
  public func encode(_ text: String) -> (tokenIds: [Int], wordBoundaries: [WordBoundary]) {
    let words = splitIntoWords(text)

    var allTokenIds = [Self.bosTokenId]
    var boundaries = [WordBoundary]()

    for (wordIndex, word) in words.enumerated() {
      let startOffset = allTokenIds.count
      let tokenIds = encodeWord(word, isFirstWord: wordIndex == 0)
      allTokenIds.append(contentsOf: tokenIds)
      let endOffset = allTokenIds.count
      boundaries.append(WordBoundary(
        wordIndex: wordIndex,
        startTokenOffset: startOffset,
        endTokenOffset: endOffset
      ))
    }

    allTokenIds.append(Self.eosTokenId)
    return (allTokenIds, boundaries)
  }

  /// Decode token IDs back to text. Strips BOS/EOS/PAD.
  public func decode(_ tokenIds: [Int]) -> String {
    let specialIds: Set<Int> = [Self.bosTokenId, Self.eosTokenId, Self.padTokenId]
    let tokens = tokenIds.compactMap { id -> String? in
      guard !specialIds.contains(id) else { return nil }
      return decoder[id]
    }

    let joined = tokens.joined()
    // Convert byte-encoded unicode chars back to actual bytes
    var bytes = [UInt8]()
    for char in joined {
      if let byte = byteDecoder[char] {
        bytes.append(byte)
      }
    }
    return String(bytes: bytes, encoding: .utf8) ?? ""
  }

  // MARK: - Word Splitting

  /// Split text into words, preserving leading spaces as part of non-first words.
  /// RoBERTa tokenizer treats spaces as part of the following word token (Ġ prefix).
  private func splitIntoWords(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }

    var words = [String]()
    var current = ""
    var isFirst = true

    for char in text {
      if char == " " || char == "\t" || char == "\n" {
        if !current.isEmpty {
          words.append(current)
          current = ""
          isFirst = false
        }
        // Space becomes part of the next word (Ġ prefix)
        current.append(char)
      } else {
        if isFirst {
          current.append(char)
        } else {
          current.append(char)
        }
      }
    }
    if !current.isEmpty {
      words.append(current)
    }
    return words
  }

  // MARK: - BPE Encoding

  /// Encode a single word (possibly with leading space) into token IDs.
  private func encodeWord(_ word: String, isFirstWord: Bool) -> [Int] {
    // Convert to byte-level unicode representation
    let byteStr = word.utf8.map { byteEncoder[$0] ?? Character("\u{FFFD}") }
    guard !byteStr.isEmpty else { return [] }

    // Apply BPE
    var symbols = byteStr.map { String($0) }
    symbols = applyBPE(symbols)

    // Look up token IDs
    return symbols.map { token in
      encoder[token] ?? Self.unkTokenId
    }
  }

  /// Apply BPE merges to a sequence of symbols until no more merges apply.
  private func applyBPE(_ symbols: [String]) -> [String] {
    guard symbols.count > 1 else { return symbols }

    var word = symbols

    while true {
      // Find the highest-priority (lowest rank) pair
      var bestPair: StringPair?
      var bestRank = Int.max

      for i in 0..<(word.count - 1) {
        let pair = StringPair(word[i], word[i + 1])
        if let rank = bpeRanks[pair], rank < bestRank {
          bestRank = rank
          bestPair = pair
        }
      }

      guard let pair = bestPair else { break }

      // Merge all occurrences of the best pair
      var newWord = [String]()
      var i = 0
      while i < word.count {
        if i < word.count - 1 && word[i] == pair.first && word[i + 1] == pair.second {
          newWord.append(pair.first + pair.second)
          i += 2
        } else {
          newWord.append(word[i])
          i += 1
        }
      }
      word = newWord

      if word.count == 1 { break }
    }

    return word
  }

  // MARK: - Byte Mapping

  /// Build the GPT-2 byte-to-unicode mapping.
  /// Maps bytes 0-255 to unicode characters, avoiding control characters.
  private static func buildByteMapping() -> ([UInt8: Character], [Character: UInt8]) {
    var byteToUnicode = [UInt8: Character]()
    var n = 0

    // Printable ASCII + Latin-1 supplement ranges that map to themselves
    let ranges: [ClosedRange<Int>] = [
      0x21...0x7E,   // ! to ~
      0xA1...0xAC,   // ¡ to ¬
      0xAE...0xFF,   // ® to ÿ
    ]

    var directBytes = Set<Int>()
    for range in ranges {
      for b in range {
        directBytes.insert(b)
        byteToUnicode[UInt8(b)] = Character(Unicode.Scalar(b)!)
      }
    }

    // Map remaining bytes to unicode chars starting at U+0100
    var offset = 256
    for b in 0...255 {
      if !directBytes.contains(b) {
        byteToUnicode[UInt8(b)] = Character(Unicode.Scalar(offset)!)
        offset += 1
      }
    }

    var unicodeToByte = [Character: UInt8]()
    for (byte, char) in byteToUnicode {
      unicodeToByte[char] = byte
    }

    return (byteToUnicode, unicodeToByte)
  }
}

// MARK: - Helpers

/// Hashable pair of strings for BPE rank lookup.
private struct StringPair: Hashable {
  let first: String
  let second: String

  init(_ first: String, _ second: String) {
    self.first = first
    self.second = second
  }
}

// MARK: - Errors

public enum TokenizerError: Error, LocalizedError {
  case invalidVocab
  case invalidMerges

  public var errorDescription: String? {
    switch self {
    case .invalidVocab: return "Failed to parse tokenizer vocabulary JSON"
    case .invalidMerges: return "Failed to parse tokenizer merges file"
    }
  }
}
