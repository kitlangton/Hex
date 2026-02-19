import Testing
@testable import HexCore
import Foundation

@Suite("TagVocabulary")
struct TagVocabularyTests {

  private func loadSampleLabels() throws -> TagVocabulary {
    let url = Bundle.module.url(forResource: "sample_labels", withExtension: "txt", subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    return try TagVocabulary(labelsData: data)
  }

  @Test("Parses sample labels file")
  func parseSampleLabels() throws {
    let vocab = try loadSampleLabels()
    #expect(vocab.count == 26)
    #expect(vocab.keepTagIndex == 0)
  }

  @Test("$KEEP tag")
  func keepTag() throws {
    let vocab = try loadSampleLabels()
    let tag = vocab.tag(at: 0)
    #expect(tag == .keep)
  }

  @Test("$DELETE tag")
  func deleteTag() throws {
    let vocab = try loadSampleLabels()
    let tag = vocab.tag(at: 1)
    #expect(tag == .delete)
  }

  @Test("$APPEND tags")
  func appendTags() throws {
    let vocab = try loadSampleLabels()
    #expect(vocab.tag(at: 2) == .append(","))
    #expect(vocab.tag(at: 3) == .append("."))
    #expect(vocab.tag(at: 4) == .append("the"))
    #expect(vocab.tag(at: 5) == .append("a"))
    #expect(vocab.tag(at: 6) == .append("to"))
  }

  @Test("$REPLACE tags")
  func replaceTags() throws {
    let vocab = try loadSampleLabels()
    #expect(vocab.tag(at: 7) == .replace("the"))
    #expect(vocab.tag(at: 8) == .replace("a"))
    #expect(vocab.tag(at: 9) == .replace("is"))
    #expect(vocab.tag(at: 10) == .replace("are"))
  }

  @Test("$TRANSFORM_CASE tags")
  func caseTransformTags() throws {
    let vocab = try loadSampleLabels()
    #expect(vocab.tag(at: 13) == .transformCase(.upper))
    #expect(vocab.tag(at: 14) == .transformCase(.lower))
    #expect(vocab.tag(at: 15) == .transformCase(.capital))
    #expect(vocab.tag(at: 16) == .transformCase(.capitalFirst))
  }

  @Test("$TRANSFORM_VERB tags")
  func verbTransformTags() throws {
    let vocab = try loadSampleLabels()
    #expect(vocab.tag(at: 17) == .transformVerb(from: .vb, to: .vbD))
    #expect(vocab.tag(at: 18) == .transformVerb(from: .vb, to: .vbZ))
    #expect(vocab.tag(at: 19) == .transformVerb(from: .vb, to: .vbG))
    #expect(vocab.tag(at: 20) == .transformVerb(from: .vbD, to: .vb))
    #expect(vocab.tag(at: 21) == .transformVerb(from: .vbZ, to: .vb))
    #expect(vocab.tag(at: 22) == .transformVerb(from: .vbP, to: .vbZ))
  }

  @Test("$MERGE tags")
  func mergeTags() throws {
    let vocab = try loadSampleLabels()
    #expect(vocab.tag(at: 23) == .merge(.hyphen))
    #expect(vocab.tag(at: 24) == .merge(.space))
  }

  @Test("$SPLIT tags")
  func splitTags() throws {
    let vocab = try loadSampleLabels()
    #expect(vocab.tag(at: 25) == .split(.hyphen))
  }

  @Test("Out of bounds returns keep")
  func outOfBoundsReturnsKeep() throws {
    let vocab = try loadSampleLabels()
    #expect(vocab.tag(at: -1) == .keep)
    #expect(vocab.tag(at: 9999) == .keep)
  }

  @Test("Empty labels throws")
  func emptyLabelsThrows() throws {
    let emptyData = Data()
    #expect(throws: TagVocabularyError.self) {
      try TagVocabulary(labelsData: emptyData)
    }
  }

  @Test("Missing $KEEP tag throws")
  func missingKeepThrows() throws {
    let noKeepData = "$DELETE\n$APPEND_foo\n".data(using: .utf8)!
    #expect(throws: TagVocabularyError.self) {
      try TagVocabulary(labelsData: noKeepData)
    }
  }
}
