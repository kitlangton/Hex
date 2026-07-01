//
//  SpokenText.swift
//  Hex
//
//  Turns an assistant's markdown reply into something worth reading ALOUD: drop code blocks
//  entirely, reduce `[label](url)` to its label, drop bare URLs, and strip the formatting
//  punctuation the synthesizer would stumble on. The full (cleaned) reply is read — there's
//  no length limiting.
//

import Foundation

enum SpokenText {
  /// The text to READ ALOUD for a message body: the markdown reply with code blocks and
  /// URLs stripped.
  static func spoken(from raw: String) -> String {
    filterMarkdown(raw)
  }

  // MARK: Markdown → speech

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

  // MARK: Helper

  private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
  }
}
