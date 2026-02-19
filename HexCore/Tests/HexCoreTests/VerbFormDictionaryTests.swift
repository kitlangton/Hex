import Testing
@testable import HexCore
import Foundation

@Suite("VerbFormDictionary")
struct VerbFormDictionaryTests {

  private func loadSampleVerbForms() throws -> VerbFormDictionary {
    let url = Bundle.module.url(forResource: "sample_verb_forms", withExtension: "json", subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    return try VerbFormDictionary(jsonData: data)
  }

  @Test("Conjugate 'go' to past tense")
  func goToPast() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("go", to: .vbD) == "went")
  }

  @Test("Conjugate 'go' to 3rd person singular")
  func goTo3rdPerson() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("go", to: .vbZ) == "goes")
  }

  @Test("Conjugate 'go' to gerund")
  func goToGerund() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("go", to: .vbG) == "going")
  }

  @Test("Reverse lookup: 'went' to base form")
  func wentToBase() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("went", to: .vb) == "go")
  }

  @Test("Conjugate 'be' to past tense")
  func beToPast() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("be", to: .vbD) == "was")
  }

  @Test("Conjugate 'be' to 3rd person singular")
  func beTo3rdPerson() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("be", to: .vbZ) == "is")
  }

  @Test("Conjugate 'have' to 3rd person singular")
  func haveTo3rdPerson() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("have", to: .vbZ) == "has")
  }

  @Test("Reverse: 'has' back to base form")
  func hasToBase() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("has", to: .vb) == "have")
  }

  @Test("Preserves capitalization")
  func preservesCapitalization() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("Go", to: .vbD) == "Went")
  }

  @Test("Unknown word returns nil")
  func unknownWord() throws {
    let dict = try loadSampleVerbForms()
    #expect(dict.conjugate("xyzzy", to: .vbD) == nil)
  }

  @Test("Invalid JSON throws")
  func invalidJSON() throws {
    let badData = "not json".data(using: .utf8)!
    #expect(throws: (any Error).self) {
      try VerbFormDictionary(jsonData: badData)
    }
  }

  @Test("Valid JSON but wrong structure throws VerbFormError")
  func wrongStructure() throws {
    let arrayData = "[1, 2, 3]".data(using: .utf8)!
    #expect(throws: VerbFormError.self) {
      try VerbFormDictionary(jsonData: arrayData)
    }
  }

  // MARK: - Regular Verb Fallback

  @Test("Regular verb: add -s for 3rd person")
  func regularVbZ() {
    #expect(VerbFormDictionary.conjugateRegular("walk", to: .vbZ) == "walks")
    #expect(VerbFormDictionary.conjugateRegular("play", to: .vbZ) == "plays")
  }

  @Test("Regular verb: add -es for sibilants")
  func regularVbZSibilant() {
    #expect(VerbFormDictionary.conjugateRegular("wash", to: .vbZ) == "washes")
    #expect(VerbFormDictionary.conjugateRegular("watch", to: .vbZ) == "watches")
    #expect(VerbFormDictionary.conjugateRegular("pass", to: .vbZ) == "passes")
  }

  @Test("Regular verb: -y → -ies")
  func regularVbZConsonantY() {
    #expect(VerbFormDictionary.conjugateRegular("carry", to: .vbZ) == "carries")
    #expect(VerbFormDictionary.conjugateRegular("try", to: .vbZ) == "tries")
  }

  @Test("Regular verb: -ed for past tense")
  func regularVbD() {
    #expect(VerbFormDictionary.conjugateRegular("walk", to: .vbD) == "walked")
    #expect(VerbFormDictionary.conjugateRegular("play", to: .vbD) == "played")
  }

  @Test("Regular verb: -e + d")
  func regularVbDTrailingE() {
    #expect(VerbFormDictionary.conjugateRegular("like", to: .vbD) == "liked")
    #expect(VerbFormDictionary.conjugateRegular("love", to: .vbD) == "loved")
  }

  @Test("Regular verb: -ing for gerund")
  func regularVbG() {
    #expect(VerbFormDictionary.conjugateRegular("walk", to: .vbG) == "walking")
    #expect(VerbFormDictionary.conjugateRegular("play", to: .vbG) == "playing")
  }

  @Test("Regular verb: drop -e for -ing")
  func regularVbGDropE() {
    #expect(VerbFormDictionary.conjugateRegular("make", to: .vbG) == "making")
    #expect(VerbFormDictionary.conjugateRegular("like", to: .vbG) == "liking")
  }
}
