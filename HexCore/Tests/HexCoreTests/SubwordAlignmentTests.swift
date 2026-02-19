import Testing
@testable import HexCore
import Foundation

@Suite("SubwordAlignment")
struct SubwordAlignmentTests {

  private func loadSampleVocab() throws -> TagVocabulary {
    let url = Bundle.module.url(forResource: "sample_labels", withExtension: "txt", subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    return try TagVocabulary(labelsData: data)
  }

  private func loadSampleVerbForms() throws -> VerbFormDictionary {
    let url = Bundle.module.url(forResource: "sample_verb_forms", withExtension: "json", subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    return try VerbFormDictionary(jsonData: data)
  }

  @Test("First-subword selection: takes first token prediction per word")
  func firstSubwordSelection() throws {
    let vocab = try loadSampleVocab()

    // Simulate 3 words where first word has 2 subword tokens, second has 1, third has 3
    let wordBoundaries = [
      WordBoundary(wordIndex: 0, startTokenOffset: 1, endTokenOffset: 3),  // tokens 1-2
      WordBoundary(wordIndex: 1, startTokenOffset: 3, endTokenOffset: 4),  // token 3
      WordBoundary(wordIndex: 2, startTokenOffset: 4, endTokenOffset: 7),  // tokens 4-6
    ]

    // BOS at index 0, then tokens at 1-6, EOS at 7
    let predictions: [(tagIndex: Int, confidence: Float)] = [
      (0, 0.9),   // BOS → KEEP
      (1, 0.85),  // Word 0, first subword → DELETE
      (0, 0.7),   // Word 0, second subword → KEEP (ignored)
      (2, 0.9),   // Word 1, first subword → APPEND_,
      (0, 0.95),  // Word 2, first subword → KEEP
      (0, 0.8),   // Word 2, second subword → KEEP (ignored)
      (0, 0.8),   // Word 2, third subword → KEEP (ignored)
      (0, 0.9),   // EOS → KEEP
    ]

    let tags = SubwordAlignment.align(
      predictions: predictions,
      wordBoundaries: wordBoundaries,
      vocabulary: vocab
    )

    #expect(tags.count == 3)
    #expect(tags[0] == .delete)
    #expect(tags[1] == .append(","))
    #expect(tags[2] == .keep)
  }

  @Test("All KEEP produces no changes")
  func allKeepNoChanges() throws {
    let vocab = try loadSampleVocab()
    let verbForms = try loadSampleVerbForms()

    let words = ["The", "cat", "sat"]
    let tags: [EditTag] = [.keep, .keep, .keep]

    let result = SubwordAlignment.applyEdits(words: words, tags: tags, verbForms: verbForms)
    #expect(result == "The cat sat")
  }

  @Test("DELETE removes word")
  func deleteRemovesWord() throws {
    let vocab = try loadSampleVocab()
    let verbForms = try loadSampleVerbForms()

    let words = ["The", "very", "cat", "sat"]
    let tags: [EditTag] = [.keep, .delete, .keep, .keep]

    let result = SubwordAlignment.applyEdits(words: words, tags: tags, verbForms: verbForms)
    #expect(result == "The cat sat")
  }

  @Test("APPEND inserts word after")
  func appendInsertsWord() throws {
    let verbForms = try loadSampleVerbForms()

    let words = ["He", "went", "store"]
    let tags: [EditTag] = [.keep, .append("to"), .append("the")]

    let result = SubwordAlignment.applyEdits(words: words, tags: tags, verbForms: verbForms)
    #expect(result == "He went to store the")
  }

  @Test("REPLACE substitutes word")
  func replaceSubstitutesWord() throws {
    let verbForms = try loadSampleVerbForms()

    let words = ["The", "cats", "is", "sleeping"]
    let tags: [EditTag] = [.keep, .keep, .replace("are"), .keep]

    let result = SubwordAlignment.applyEdits(words: words, tags: tags, verbForms: verbForms)
    #expect(result == "The cats are sleeping")
  }

  @Test("TRANSFORM_VERB conjugates verb")
  func transformVerbConjugates() throws {
    let verbForms = try loadSampleVerbForms()

    let words = ["He", "go", "to", "the", "store"]
    let tags: [EditTag] = [.keep, .transformVerb(from: .vb, to: .vbD), .keep, .keep, .keep]

    let result = SubwordAlignment.applyEdits(words: words, tags: tags, verbForms: verbForms)
    #expect(result == "He went to the store")
  }

  @Test("TRANSFORM_CASE uppercases word")
  func transformCaseUpper() throws {
    let verbForms = try loadSampleVerbForms()

    let words = ["hello", "world"]
    let tags: [EditTag] = [.transformCase(.capital), .keep]

    let result = SubwordAlignment.applyEdits(words: words, tags: tags, verbForms: verbForms)
    #expect(result == "Hello world")
  }

  @Test("Confidence thresholding reverts to KEEP below threshold")
  func confidenceThreshold() throws {
    let vocab = try loadSampleVocab()

    let wordBoundaries = [
      WordBoundary(wordIndex: 0, startTokenOffset: 1, endTokenOffset: 2),
      WordBoundary(wordIndex: 1, startTokenOffset: 2, endTokenOffset: 3),
    ]

    let predictions: [(tagIndex: Int, confidence: Float)] = [
      (0, 0.9),   // BOS
      (1, 0.3),   // Word 0 → DELETE with low confidence
      (1, 0.9),   // Word 1 → DELETE with high confidence
      (0, 0.9),   // EOS
    ]

    let tags = SubwordAlignment.align(
      predictions: predictions,
      wordBoundaries: wordBoundaries,
      vocabulary: vocab,
      minConfidence: 0.5
    )

    #expect(tags[0] == .keep)    // Below threshold → KEEP
    #expect(tags[1] == .delete)  // Above threshold → DELETE
  }

  @Test("Empty word list produces empty result")
  func emptyWords() {
    let result = SubwordAlignment.applyEdits(words: [], tags: [], verbForms: nil)
    #expect(result == "")
  }

  @Test("Mismatched words/tags count returns joined words")
  func mismatchedCount() {
    let words = ["hello", "world"]
    let tags: [EditTag] = [.keep] // only 1 tag for 2 words

    let result = SubwordAlignment.applyEdits(words: words, tags: tags, verbForms: nil)
    #expect(result == "hello world")
  }
}
