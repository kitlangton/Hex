import Foundation

/// Tracks how live dictation text replaces content at the original insertion point.
public struct LiveTextInsertionState: Equatable, Sendable {
  public let prefix: String
  public let suffix: String
  public private(set) var insertedText: String

  public init(prefix: String, suffix: String, insertedText: String = "") {
    self.prefix = prefix
    self.suffix = suffix
    self.insertedText = insertedText
  }

  public mutating func update(with newText: String) -> String {
    insertedText = newText
    return composedValue
  }

  public var composedValue: String {
    prefix + insertedText + suffix
  }

  public var cursorLocation: Int {
    prefix.count + insertedText.count
  }

  public func revertedValue() -> String {
    prefix + suffix
  }

  public var revertedCursorLocation: Int {
    prefix.count
  }
}

public enum LiveTextInsertionLogic {
  public enum KeystrokeUpdateAction: Equatable, Sendable {
    case none
    case append(String)
    case shrinkBackspaces(Int)
    /// Delete `backspaces` characters at the insertion tail, then paste `insert`.
    case replaceTail(backspaces: Int, insert: String)
  }

  public static func snapshot(
    fullValue: String,
    selectionLocation: Int,
    selectionLength: Int
  ) -> LiveTextInsertionState? {
    guard selectionLocation >= 0, selectionLength >= 0 else { return nil }
    let endIndex = selectionLocation + selectionLength
    guard selectionLocation <= fullValue.count, endIndex <= fullValue.count else { return nil }

    let prefix = String(fullValue.prefix(selectionLocation))
    let suffix = String(fullValue.dropFirst(endIndex))
    return LiveTextInsertionState(prefix: prefix, suffix: suffix)
  }

  /// Plans minimal keystroke edits when ASR preview text changes (append, trim suffix, or full replace).
  public static func keystrokeUpdateAction(
    previous: String,
    new: String,
    preferFullReplace: Bool = false
  ) -> KeystrokeUpdateAction {
    guard previous != new else { return .none }

    if preferFullReplace, !previous.isEmpty {
      return .replaceTail(backspaces: previous.count, insert: new)
    }

    if new.isEmpty {
      guard !previous.isEmpty else { return .none }
      return .replaceTail(backspaces: previous.count, insert: "")
    }

    if previous.isEmpty {
      return .replaceTail(backspaces: 0, insert: new)
    }

    let sharedPrefixLength = commonPrefixLength(previous, new)

    if sharedPrefixLength == new.count {
      let backspaces = previous.count - new.count
      return backspaces > 0 ? .shrinkBackspaces(backspaces) : .none
    }

    if sharedPrefixLength == previous.count {
      let suffix = String(new.dropFirst(previous.count))
      return suffix.isEmpty ? .none : .append(suffix)
    }

    // Revise from the first changed character — do not wipe text before the shared prefix.
    let backspaces = previous.count - sharedPrefixLength
    let insert = String(new.dropFirst(sharedPrefixLength))
    return .replaceTail(backspaces: backspaces, insert: insert)
  }

  private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
    var index = lhs.startIndex
    var other = rhs.startIndex
    var count = 0

    while index < lhs.endIndex, other < rhs.endIndex, lhs[index] == rhs[other] {
      lhs.formIndex(after: &index)
      rhs.formIndex(after: &other)
      count += 1
    }

    return count
  }
}

/// Debounces live ASR preview updates to reduce cursor flicker from transient revisions.
public struct LivePreviewUpdateGate: Equatable, Sendable {
  /// Ignore very short first previews — padded 1s clips often hallucinate 1–4 chars.
  public static let minimumInitialApplyLength = 8
  /// When a prior apply was shorter than this, allow a fuller transcript to replace it.
  public static let shortPreviewRecoveryThreshold = 8

  public private(set) var lastApplied: String = ""
  private var pendingShrinkCandidate: String?

  public init() {}

  /// Returns whether `next` should be applied at the cursor.
  public mutating func shouldApply(next: String) -> Bool {
    guard !next.isEmpty else { return false }
    guard next != lastApplied else { return false }

    if lastApplied.isEmpty {
      return next.count >= Self.minimumInitialApplyLength
    }

    if next.count >= lastApplied.count {
      if next.hasPrefix(lastApplied) {
        pendingShrinkCandidate = nil
        return true
      }
      // Growing snapshot re-transcription often rewrites earlier words — allow refreshes
      // that are materially longer than what is already at the cursor.
      if lastApplied.count >= Self.minimumInitialApplyLength {
        let sharedPrefixLength = lastApplied.commonPrefix(with: next).count
        if next.count >= lastApplied.count + 15,
           sharedPrefixLength >= max(4, lastApplied.count / 4)
        {
          pendingShrinkCandidate = nil
          return true
        }
        if next.count >= lastApplied.count + 30 {
          pendingShrinkCandidate = nil
          return true
        }
        if next.count * 20 >= lastApplied.count * 21,
           sharedPrefixLength >= max(8, lastApplied.count / 4)
        {
          pendingShrinkCandidate = nil
          return true
        }
      }
      let sharedPrefixLength = lastApplied.commonPrefix(with: next).count
      let minimumStablePrefix = max(4, lastApplied.count / 2)
      // A tiny early preview (e.g. "Te") often diverges from the real transcript — replace it.
      if lastApplied.count <= Self.shortPreviewRecoveryThreshold,
         next.count >= 20,
         sharedPrefixLength < minimumStablePrefix
      {
        pendingShrinkCandidate = nil
        return true
      }
      // Reject unrelated growth (common on very short padded clips) while allowing
      // normal ASR rewrites that share roughly half the prior preview text.
      guard sharedPrefixLength >= minimumStablePrefix else { return false }
      pendingShrinkCandidate = nil
      return true
    }

    let sharedPrefixLength = lastApplied.commonPrefix(with: next).count
    guard sharedPrefixLength >= next.count else {
      pendingShrinkCandidate = nil
      return false
    }

    // Allow small ASR trim revisions without waiting for a second identical shrink.
    if lastApplied.count - next.count <= 2 {
      pendingShrinkCandidate = nil
      return true
    }

    if pendingShrinkCandidate == next {
      pendingShrinkCandidate = nil
      return true
    }

    pendingShrinkCandidate = next
    return false
  }

  public mutating func markApplied(_ text: String) {
    lastApplied = text
    pendingShrinkCandidate = nil
  }

  public mutating func reset() {
    lastApplied = ""
    pendingShrinkCandidate = nil
  }
}

/// Throttles live preview Parakeet passes and decides when to skip stale results.
public struct LivePreviewTranscriptionScheduler: Equatable, Sendable {
  public static let minimumAudioBeforeTranscribe: TimeInterval = 0.45
  public static let minimumNewAudioBetweenTranscribes: TimeInterval = 0.40
  /// Ignore preview results that lag the live capture by more than this.
  /// Must exceed capture callback cadence (~0.51s) plus typical Parakeet latency.
  public static let maxStaleResultDelta: TimeInterval = 1.25

  public private(set) var lastTranscribedDuration: TimeInterval = 0

  public init() {}

  public static func minimumNewAudioBetweenTranscribes(for snapshotDuration: TimeInterval) -> TimeInterval {
    switch snapshotDuration {
    case ..<3:
      minimumNewAudioBetweenTranscribes
    case ..<8:
      0.55
    case ..<15:
      0.75
    default:
      1.00
    }
  }

  public mutating func shouldScheduleTranscribe(
    snapshotDuration: TimeInterval,
    hasInFlightTranscribe: Bool
  ) -> Bool {
    guard !hasInFlightTranscribe else { return false }
    guard snapshotDuration >= Self.minimumAudioBeforeTranscribe else { return false }
    let requiredNewAudio = Self.minimumNewAudioBetweenTranscribes(for: snapshotDuration)
    guard snapshotDuration - lastTranscribedDuration >= requiredNewAudio else {
      return false
    }
    return true
  }

  public func shouldApplyResult(resultDuration: TimeInterval, currentDuration: TimeInterval) -> Bool {
    currentDuration - resultDuration <= Self.maxStaleResultDelta
  }

  public mutating func markTranscribed(duration: TimeInterval) {
    lastTranscribedDuration = duration
  }

  /// Allows an immediate retry when a preview result was too stale to apply.
  public mutating func noteSkippedStaleResult(at resultDuration: TimeInterval) {
    lastTranscribedDuration = max(0, resultDuration - Self.minimumNewAudioBetweenTranscribes)
  }
}
