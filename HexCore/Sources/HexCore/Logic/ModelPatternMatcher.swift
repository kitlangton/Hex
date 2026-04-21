//
//  ModelPatternMatcher.swift
//  HexCore
//
//  Shared utility for matching model names using glob patterns (fnmatch).
//

import Foundation

/// Utilities for matching model names against glob patterns.
public enum ModelPatternMatcher {
  /// Returns `true` if `text` matches `pattern` (supports `*` and `?` wildcards).
  public static func matches(_ pattern: String, _ text: String) -> Bool {
    if pattern.contains("*") || pattern.contains("?") {
      return fnmatch(pattern, text, 0) == 0
    }
    return pattern == text
  }

  /// Matches model names tolerating HuggingFace size suffixes like `_626MB`.
  /// Returns true if exact match, glob match, or one name equals the other
  /// with a `_\d+MB` suffix stripped.
  public static func matchesFlexible(_ pattern: String, _ text: String) -> Bool {
    if matches(pattern, text) { return true }
    let stripped1 = stripSizeSuffix(pattern)
    let stripped2 = stripSizeSuffix(text)
    // Guard against degenerate inputs (e.g. "_626MB") both collapsing to empty.
    guard !stripped1.isEmpty, !stripped2.isEmpty else { return false }
    return stripped1 == stripped2
  }

  /// Strips a trailing `_\d+MB` suffix from a model name if present.
  public static func stripSizeSuffix(_ name: String) -> String {
    guard let range = name.range(of: #"_\d+MB$"#, options: .regularExpression) else {
      return name
    }
    return String(name[name.startIndex..<range.lowerBound])
  }

  /// Given a list of model names and download status, resolve a glob pattern to a concrete name.
  /// Preference: downloaded > non-turbo > any match.
  /// Returns `nil` if no match found.
  public static func resolvePattern(
    _ pattern: String,
    from models: [(name: String, isDownloaded: Bool)]
  ) -> String? {
    // No glob characters: return as-is
    guard pattern.contains("*") || pattern.contains("?") else {
      return pattern
    }

    // Find all matches
    let matched = models.filter { fnmatch(pattern, $0.name, 0) == 0 }
    guard !matched.isEmpty else { return nil }

    // Prefer already-downloaded matches
    let downloaded = matched.filter { $0.isDownloaded }
    if !downloaded.isEmpty {
      // Prefer non-turbo if both exist
      if let nonTurbo = downloaded.first(where: { !$0.name.localizedCaseInsensitiveContains("turbo") }) {
        return nonTurbo.name
      }
      return downloaded.first!.name
    }

    // If none downloaded yet, prefer non-turbo first
    if let nonTurbo = matched.first(where: { !$0.name.localizedCaseInsensitiveContains("turbo") }) {
      return nonTurbo.name
    }
    return matched.first!.name
  }
}
