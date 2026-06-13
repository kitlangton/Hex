//
//  AgentTranscriptClient.swift
//  Hex
//
//  Decides what the agent window should show. For PreToolUse (AskUserQuestion) and
//  PermissionRequest it reads the hook's own payload file — the CURRENT tool_input,
//  which is authoritative. The transcript is only used for the plain "last message"
//  case (Stop), since the current tool call may not be flushed yet at PreToolUse time.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let agentLogger = HexLog.app

/// What Claude Code is presenting to the user.
enum AgentPrompt: Equatable, Sendable {
  case message(String)              // plain assistant text (markdown)
  case question(AgentQuestion)      // AskUserQuestion multiple choice
  case permission(AgentPermission)  // tool awaiting allow/deny
}

struct AgentQuestion: Equatable, Sendable {
  var header: String
  var question: String
  var multiSelect: Bool
  var options: [AgentOption]
}

struct AgentOption: Equatable, Sendable, Identifiable {
  var label: String
  var detail: String
  var id: String { label }
}

struct AgentPermission: Equatable, Sendable {
  var tool: String
  var summary: String   // e.g. the Bash command or the file path
}

@DependencyClient
struct AgentTranscriptClient {
  /// Resolves the prompt to display.
  /// - payloadPath: temp file the hook wrote with the full hook JSON (incl. tool_input).
  /// - transcriptPath: the session transcript (.jsonl), used for the last-message fallback.
  var latestPrompt: @Sendable (_ payloadPath: String?, _ transcriptPath: String?) async throws -> AgentPrompt = { _, _ in .message("") }
}

extension AgentTranscriptClient: DependencyKey {
  static var liveValue: Self {
    .init(latestPrompt: { payloadPath, transcriptPath in
      // 1) Authoritative: the hook payload holds the CURRENT event + tool_input.
      if let hook = readJSON(payloadPath) {
        let event = hook["hook_event_name"] as? String ?? ""
        let toolName = hook["tool_name"] as? String ?? ""
        let input = hook["tool_input"] as? [String: Any]

        if toolName == "AskUserQuestion", let input, let q = question(from: input) {
          return .question(q)
        }
        if event == "PermissionRequest" {
          return .permission(AgentPermission(tool: toolName, summary: permissionSummary(toolName, input)))
        }
        // Stop payloads carry the final text directly — no transcript parse needed.
        if let last = hook["last_assistant_message"] as? String, !last.isEmpty {
          return .message(last)
        }
      }

      // 2) Fallback (Stop / Notification): the last assistant text from the transcript.
      if let transcriptPath {
        let expanded = (transcriptPath as NSString).expandingTildeInPath
        if let contents = try? String(contentsOf: URL(fileURLWithPath: expanded), encoding: .utf8) {
          let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
          return .message(lastAssistantText(lines))
        }
      }
      return .message("")
    })
  }
}

private func readJSON(_ path: String?) -> [String: Any]? {
  guard let path, !path.isEmpty else { return nil }
  let expanded = (path as NSString).expandingTildeInPath
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return nil }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Parses an AskUserQuestion tool_input into a question (first question only).
private func question(from input: [String: Any]) -> AgentQuestion? {
  guard
    let questions = input["questions"] as? [[String: Any]],
    let first = questions.first
  else { return nil }

  let options = (first["options"] as? [[String: Any]] ?? []).map {
    AgentOption(label: $0["label"] as? String ?? "", detail: $0["description"] as? String ?? "")
  }
  return AgentQuestion(
    header: first["header"] as? String ?? "",
    question: first["question"] as? String ?? "",
    multiSelect: first["multiSelect"] as? Bool ?? false,
    options: options
  )
}

/// A short human-readable summary of what a tool wants to do, for the permission card.
private func permissionSummary(_ tool: String, _ input: [String: Any]?) -> String {
  guard let input else { return tool }
  for key in ["command", "file_path", "path", "url", "pattern", "description"] {
    if let value = input[key] as? String, !value.isEmpty { return value }
  }
  if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
     let s = String(data: data, encoding: .utf8) {
    return s.count > 300 ? String(s.prefix(300)) + "…" : s
  }
  return tool
}

/// Last assistant message's joined text blocks (bottom-up, stopping at the user turn).
private func lastAssistantText(_ lines: [Substring]) -> String {
  var collected: [String] = []
  for line in lines.reversed() {
    guard let obj = parseLine(line), let type = obj["type"] as? String else { continue }
    if type == "assistant" {
      if let text = textBlocks(obj), !text.isEmpty { collected.append(text) }
    } else if type == "user", !collected.isEmpty {
      break
    }
  }
  return collected.reversed().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func textBlocks(_ obj: [String: Any]) -> String? {
  guard let message = obj["message"] as? [String: Any] else { return nil }
  if let blocks = message["content"] as? [[String: Any]] {
    let texts = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
    return texts.isEmpty ? nil : texts.joined(separator: "\n")
  }
  if let text = message["content"] as? String { return text }
  return nil
}

private func parseLine(_ line: Substring) -> [String: Any]? {
  guard let data = line.data(using: .utf8) else { return nil }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

extension DependencyValues {
  var agentTranscript: AgentTranscriptClient {
    get { self[AgentTranscriptClient.self] }
    set { self[AgentTranscriptClient.self] = newValue }
  }
}
