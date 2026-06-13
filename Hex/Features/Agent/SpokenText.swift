//
//  SpokenText.swift
//  Hex
//
//  Turns an assistant's markdown reply into something worth reading ALOUD — short and
//  actionable — distinct from what the panel shows on screen. Three layers, in order:
//
//  1. Explicit marker: if the reply contains a `Spoken: …` line, that line IS the spoken
//     text (authoritative — the model wrote a TTS-ready summary itself). It's stripped
//     from the on-screen text via `displayText`.
//  2. Markdown filter: drop code blocks entirely, reduce `[label](url)` to its label,
//     drop bare URLs, and strip formatting punctuation the synthesizer would stumble on.
//  3. Heuristic condense: when there's no marker, speak the first sentence plus any
//     trailing question/imperative, so long explanations become a short action cycle.
//

import Foundation

enum SpokenText {
  /// The text to READ ALOUD for a message body.
  static func spoken(from raw: String) -> String {
    if let marker = markerLine(in: raw) { return marker }
    let filtered = filterMarkdown(raw)
    return condense(filtered)
  }

  /// The `Spoken: …` summary line, if the reply has one — shown as a highlighted banner.
  static func summary(from raw: String) -> String? {
    markerLine(in: raw)
  }

  /// The text to SHOW in the panel body — same markdown, minus any `Spoken:` marker line.
  static func displayText(from raw: String) -> String {
    guard markerLine(in: raw) != nil else { return raw }
    let kept = raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !isMarker($0) }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: 1. Spoken marker

  private static func isMarker(_ line: Substring) -> Bool {
    line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("spoken:")
  }

  /// The content of the first `Spoken: …` line, if any.
  private static func markerLine(in raw: String) -> String? {
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) where isMarker(line) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let content = trimmed.dropFirst("spoken:".count).trimmingCharacters(in: .whitespaces)
      if !content.isEmpty { return content }
    }
    return nil
  }

  // MARK: 2. Markdown → speech

  private static func filterMarkdown(_ text: String) -> String {
    var s = text
    // Fenced code blocks: drop entirely (don't read code aloud).
    s = replace(s, #"(?ms)^```.*?```\s*"#, with: "")
    // Images: ![alt](url) → drop (before links so the leading ! is consumed).
    s = replace(s, #"!\[[^\]]*\]\([^)]*\)"#, with: "")
    // Links: [label](url) → label.
    s = replace(s, #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
    // Autolinks / bare URLs → drop.
    s = replace(s, #"<https?://[^>]+>"#, with: "")
    s = replace(s, #"https?://[^\s)]+"#, with: "")
    // Inline code: keep the inner text, drop the backticks.
    s = replace(s, "`+", with: "")
    // Heading hashes, blockquote markers, list bullets at line starts.
    s = replace(s, #"(?m)^\s{0,3}#{1,6}\s+"#, with: "")
    s = replace(s, #"(?m)^\s{0,3}>\s?"#, with: "")
    s = replace(s, #"(?m)^\s*[-*+]\s+"#, with: "")
    s = replace(s, #"(?m)^\s*\d+\.\s+"#, with: "")
    // Emphasis / strikethrough markers.
    s = replace(s, #"[*_~]{1,3}"#, with: "")
    // Collapse whitespace.
    s = replace(s, #"\s+"#, with: " ")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: 3. Heuristic condense

  /// Roughly the first 60% of the reply by length (whole sentences), always keeping a
  /// trailing question so the "what's next" ask survives. Condenses long explanations
  /// without collapsing them to a single micro-sentence.
  private static let retainFraction = 0.6

  private static func condense(_ text: String) -> String {
    let sentences = splitSentences(text)
    guard sentences.count > 1 else { return sentences.first ?? text }

    let total = sentences.reduce(0) { $0 + $1.count }
    let target = Double(total) * retainFraction
    var kept: [String] = []
    var acc = 0
    for sentence in sentences {
      kept.append(sentence)
      acc += sentence.count
      if Double(acc) >= target { break }
    }

    // Always include a trailing question (the actionable ask), even if it fell past 60%.
    if let last = sentences.last, last.hasSuffix("?"), kept.last != last {
      kept.append(last)
    }
    return kept.joined(separator: " ")
  }

  // Kept deliberately short: an abbreviation like "al." would also match "material.",
  // suppressing real sentence breaks, so only include unambiguous multi-dot forms.
  private static let abbreviations = ["e.g.", "i.e.", "etc.", "vs."]

  private static func splitSentences(_ text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    let chars = Array(text)
    for (i, ch) in chars.enumerated() {
      current.append(ch)
      guard ch == "." || ch == "!" || ch == "?" else { continue }
      // Only a real boundary if the next character is whitespace or the end — so dots
      // inside "AgentView.swift" or "e.g." don't split a sentence mid-word.
      let next = i + 1 < chars.count ? chars[i + 1] : nil
      guard next == nil || next!.isWhitespace else { continue }
      // Don't split after a common abbreviation ("e.g.", "i.e.", "etc.").
      let lower = current.trimmingCharacters(in: .whitespaces).lowercased()
      if ch == ".", abbreviations.contains(where: { lower.hasSuffix($0) }) { continue }
      let trimmed = current.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { sentences.append(trimmed) }
      current = ""
    }
    let tail = current.trimmingCharacters(in: .whitespaces)
    if !tail.isEmpty { sentences.append(tail) }
    return sentences
  }

  // MARK: Helper

  private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
  }
}
