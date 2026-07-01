//
//  AgentHookResponder.swift
//  Hex
//
//  Answers a blocked agent hook in-band. The integration script polls for
//  `<payload>.response`; we write the complete hook-output JSON there and the integration
//  relays it back to the agent. An empty file means "user dismissed — yield to the terminal UI".
//
//  Output shapes use Claude Code's hook-output dialect as the lingua franca (other
//  integrations — e.g. pi — translate it into their own conventions on the agent side):
//  - Stop:               {"decision":"block","reason":"<user's text>"} — the agent
//                        treats the reason as the user's next instruction.
//  - AskUserQuestion:    PreToolUse hookSpecificOutput, permissionDecision=allow,
//                        updatedInput with an `answers` map keyed by question text.
//  - PermissionRequest:  hookSpecificOutput decision behavior allow/deny.
//

import Foundation
import HexCore

private let responderLogger = HexLog.app

enum AgentHookResponder {
  /// Writes the response file. `json == nil` writes an empty file (dismiss/yield).
  static func respond(payloadPath: String, json: [String: Any]?) {
    let responsePath = payloadPath + ".response"
    let data: Data
    if let json {
      guard let encoded = try? JSONSerialization.data(withJSONObject: json) else {
        responderLogger.error("Agent hook response failed to encode; yielding to TUI")
        try? Data().write(to: URL(fileURLWithPath: responsePath), options: .atomic)
        return
      }
      data = encoded
    } else {
      data = Data()
    }
    do {
      try data.write(to: URL(fileURLWithPath: responsePath), options: .atomic)
      responderLogger.notice("Agent hook response written (\(data.count) bytes)")
    } catch {
      responderLogger.error("Agent hook response write failed: \(error.localizedDescription)")
    }
  }

  /// Answers a question (AskUserQuestion) or a turn-end message (Stop) with free text
  /// or a chosen option label.
  static func respondAnswer(payloadPath: String, prompt: AgentPrompt, answer: String) {
    switch prompt {
    case let .question(question):
      var input = hookPayload(payloadPath)?["tool_input"] as? [String: Any] ?? [:]
      var answers = input["answers"] as? [String: String] ?? [:]
      answers[question.question] = answer
      input["answers"] = answers
      respond(payloadPath: payloadPath, json: [
        "hookSpecificOutput": [
          "hookEventName": "PreToolUse",
          "permissionDecision": "allow",
          "updatedInput": input,
        ],
      ])
    case .message, .permission:
      // Stop hook (or anything free-text): a blocked Stop's reason is delivered to
      // the agent as the user's follow-up instruction.
      respond(payloadPath: payloadPath, json: [
        "decision": "block",
        "reason": answer,
      ])
    }
  }

  /// Answers a PermissionRequest hook with allow/deny.
  static func respondPermission(payloadPath: String, allow: Bool) {
    let decision: [String: Any] = allow
      ? ["behavior": "allow", "updatedInput": hookPayload(payloadPath)?["tool_input"] as? [String: Any] ?? [:]]
      : ["behavior": "deny", "message": "The user denied this request in Hex."]
    respond(payloadPath: payloadPath, json: [
      "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": decision,
      ],
    ])
  }

  private static func hookPayload(_ path: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
