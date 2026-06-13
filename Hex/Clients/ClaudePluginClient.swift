//
//  ClaudePluginClient.swift
//  Hex
//
//  Installs/uninstalls the Hex ↔ Claude Code integration by writing a local hook
//  script under ~/.claude and merging hook registrations into ~/.claude/settings.json.
//  No GitHub marketplace required — everything lives on the user's machine.
//
//  Requires the app to be UNSANDBOXED (see Hex.entitlements) so it can read/write
//  the real ~/.claude directory.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let pluginLogger = HexLog.app

@DependencyClient
struct ClaudePluginClient {
  /// True if the Hex hook script exists and is referenced by ~/.claude/settings.json.
  var isInstalled: @Sendable () async -> Bool = { false }
  /// Writes the hook script and registers all five hook events.
  var install: @Sendable () async throws -> Void
  /// Removes Hex's hook registrations and deletes the hook script directory.
  var uninstall: @Sendable () async throws -> Void
  /// If the hook is installed but its script is out of date (e.g. an app update changed
  /// the delivery logic), rewrite the script in place. No-op when not installed.
  var refreshIfStale: @Sendable () async -> Void = {}
}

extension ClaudePluginClient: DependencyKey {
  static var liveValue: Self {
    let live = ClaudePluginClientLive()
    return .init(
      isInstalled: { live.isInstalled() },
      install: { try live.install() },
      uninstall: { try live.uninstall() },
      refreshIfStale: { live.refreshIfStale() }
    )
  }
}

extension DependencyValues {
  var claudePlugin: ClaudePluginClient {
    get { self[ClaudePluginClient.self] }
    set { self[ClaudePluginClient.self] = newValue }
  }
}

// MARK: - Live implementation

struct ClaudePluginClientLive {
  /// Hook events to register, with their matcher. Empty matcher == match all.
  /// PreToolUse only fires our window when Claude asks a question.
  // Fire at the end of a turn, and on the two moments that genuinely need user input:
  // a multiple-choice question and a permission request. We deliberately skip the noisy
  // Notification hook that pops mid-conversation.
  private let events: [(event: String, matcher: String)] = [
    ("Stop", ""),
    ("PreToolUse", "AskUserQuestion"),
    ("PermissionRequest", ""),
    // Bookkeeping only: when the user answers directly in the terminal, release any
    // hooks still blocked waiting on Hex and hide the Hex panel.
    ("UserPromptSubmit", ""),
  ]

  private var claudeDir: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
  }
  private var hexDir: URL { claudeDir.appendingPathComponent("hex", isDirectory: true) }
  private var scriptURL: URL { hexDir.appendingPathComponent("hex-agent-hook.sh") }
  private var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
  private var scriptPath: String { scriptURL.path }

  // MARK: Status

  func isInstalled() -> Bool {
    guard FileManager.default.fileExists(atPath: scriptPath) else { return false }
    guard let hooks = readSettings()["hooks"] as? [String: Any] else { return false }
    return hooks.values.contains { value in
      guard let groups = value as? [[String: Any]] else { return false }
      return groups.contains { groupReferencesScript($0) }
    }
  }

  // MARK: Install

  func install() throws {
    try FileManager.default.createDirectory(at: hexDir, withIntermediateDirectories: true)
    // Bake in OUR bundle id + path so the hook delivers the deeplink to this exact Hex,
    // never launching a different (or extra) Hex that also claims the hex:// scheme.
    let bundleID = Bundle.main.bundleIdentifier ?? "com.kitlangton.Hex"
    let appPath = Bundle.main.bundlePath
    try Self.hookScript(bundleID: bundleID, appPath: appPath)
      .write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

    var settings = readSettings()
    var hooks = settings["hooks"] as? [String: Any] ?? [:]

    for (event, matcher) in events {
      var groups = hooks[event] as? [[String: Any]] ?? []
      // Re-register from scratch so upgrades (e.g. the blocking timeout) take effect.
      groups.removeAll { groupReferencesScript($0) }
      groups.append([
        "matcher": matcher,
        "hooks": [["type": "command", "command": scriptPath, "timeout": 600]],
      ])
      hooks[event] = groups
    }

    settings["hooks"] = hooks
    try writeSettings(settings)
    pluginLogger.notice("Installed Claude Code agent hooks at \(self.scriptPath, privacy: .private)")
  }

  // MARK: Refresh

  /// Rewrites the hook script if it exists but doesn't match what this app would install
  /// now. Only touches the script file — the settings.json registration points at the same
  /// path, so it needs no change. Cheap to call on every launch (skips when already current).
  func refreshIfStale() {
    guard FileManager.default.fileExists(atPath: scriptPath) else { return }
    let bundleID = Bundle.main.bundleIdentifier ?? "com.kitlangton.Hex"
    let desired = Self.hookScript(bundleID: bundleID, appPath: Bundle.main.bundlePath)
    let current = try? String(contentsOf: scriptURL, encoding: .utf8)
    guard current != desired else { return }
    do {
      try desired.write(to: scriptURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
      pluginLogger.notice("Refreshed Claude Code agent hook script for \(bundleID, privacy: .public)")
    } catch {
      pluginLogger.error("Failed to refresh agent hook script: \(error.localizedDescription)")
    }
  }

  // MARK: Uninstall

  func uninstall() throws {
    var settings = readSettings()
    if var hooks = settings["hooks"] as? [String: Any] {
      for (event, _) in events {
        guard var groups = hooks[event] as? [[String: Any]] else { continue }
        groups.removeAll { groupReferencesScript($0) }
        if groups.isEmpty {
          hooks.removeValue(forKey: event)
        } else {
          hooks[event] = groups
        }
      }
      if hooks.isEmpty {
        settings.removeValue(forKey: "hooks")
      } else {
        settings["hooks"] = hooks
      }
      try writeSettings(settings)
    }

    if FileManager.default.fileExists(atPath: hexDir.path) {
      try FileManager.default.removeItem(at: hexDir)
    }
    pluginLogger.notice("Uninstalled Claude Code agent hooks")
  }

  // MARK: Helpers

  /// Whether a hook group references our script (so we can find/remove only ours).
  private func groupReferencesScript(_ group: [String: Any]) -> Bool {
    guard let entries = group["hooks"] as? [[String: Any]] else { return false }
    return entries.contains { ($0["command"] as? String) == scriptPath }
  }

  private func readSettings() -> [String: Any] {
    guard
      let data = try? Data(contentsOf: settingsURL),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
  }

  private func writeSettings(_ settings: [String: Any]) throws {
    let data = try JSONSerialization.data(
      withJSONObject: settings,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try data.write(to: settingsURL, options: .atomic)
  }

  // MARK: Hook script

  /// Reads the Claude Code hook JSON on stdin, opens a `hex://agent-update` deeplink, then
  /// BLOCKS polling for `<payload>.response`. Hex writes the complete hook-output JSON into
  /// that file (or an empty file for "dismissed, yield to the terminal UI") and this script
  /// relays it on stdout. The answer travels in-band to the exact Claude session — no app
  /// focusing, no synthetic keystrokes. Prefers jq, falls back to python3.
  ///
  /// `bundleID` and `appPath` identify the installing app, baked into the script so every
  /// invocation targets that exact Hex (`open -b`, then `open -a` as a fallback) rather than
  /// letting the URL scheme launch a different — or extra — Hex.
  static func hookScript(bundleID: String, appPath: String) -> String {
    hookScriptTemplate
      .replacingOccurrences(of: "__HEX_BUNDLE_ID__", with: bundleID)
      .replacingOccurrences(of: "__HEX_APP_PATH__", with: appPath)
  }

  private static let hookScriptTemplate: String = #"""
  #!/bin/sh
  # Hex Agent Plugins hook — bridges Claude Code to the Hex voice window.
  # Installed and managed by Hex.app (Settings → Agent Plugins). Safe to delete there.
  input=$(cat)

  # The exact Hex that installed this hook. Delivering the deeplink to this specific app
  # keeps every Claude terminal talking to one Hex window — otherwise the hex:// scheme can
  # launch a different, or additional, Hex and the queue never coalesces. We try the bundle
  # id first (survives the app moving), then the absolute path (robust when LaunchServices
  # has stale/duplicate registrations), then the bare scheme as a last resort.
  HEX_BUNDLE_ID="__HEX_BUNDLE_ID__"
  HEX_APP_PATH="__HEX_APP_PATH__"

  # NB: we deliberately do NOT bail on stop_hook_active. That flag stays set on every
  # Stop that follows a decision:block reply, but since this hook always blocks for real
  # user input there's no auto-continue loop to guard against — skipping it here would
  # suppress the panel on every turn after the first voice reply.

  # Dump the full hook JSON to a temp file so Hex can read the CURRENT tool_input
  # (the live question / permission), avoiding stale transcript data and URL limits.
  dir="${TMPDIR:-/tmp}/hex-agent"
  mkdir -p "$dir" 2>/dev/null
  payload="$dir/hook.$$.json"
  printf '%s' "$input" > "$payload" 2>/dev/null
  response="$payload.response"

  encode() {
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.quote(sys.stdin.read()))'
    else
      sed 's/ /%20/g'
    fi
  }

  # Deliver a hex:// URL to the specific Hex that installed us: bundle id, then exact app
  # path, then the default scheme handler as a last resort.
  open_url() {
    if [ -n "$HEX_BUNDLE_ID" ] && /usr/bin/open -b "$HEX_BUNDLE_ID" "$1" >/dev/null 2>&1; then
      return 0
    fi
    if [ -n "$HEX_APP_PATH" ] && [ -d "$HEX_APP_PATH" ] && /usr/bin/open -a "$HEX_APP_PATH" "$1" >/dev/null 2>&1; then
      return 0
    fi
    /usr/bin/open "$1" >/dev/null 2>&1 || open "$1" >/dev/null 2>&1
  }

  if command -v jq >/dev/null 2>&1; then
    base=$(printf '%s' "$input" | jq -r '
      "hex://agent-update?event=\(.hook_event_name // "")"
      + "&tool=\(.tool_name // "")"
      + "&session=\(.session_id // "")"
      + "&transcript=\((.transcript_path // "")|@uri)"
      + "&cwd=\((.cwd // "")|@uri)"' 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    base=$(printf '%s' "$input" | python3 -c '
  import sys, json, urllib.parse
  try:
      d = json.load(sys.stdin)
  except Exception:
      sys.exit(0)
  q = urllib.parse.urlencode({
      "event": d.get("hook_event_name", ""),
      "tool": d.get("tool_name", ""),
      "session": d.get("session_id", ""),
      "transcript": d.get("transcript_path", ""),
      "cwd": d.get("cwd", ""),
  })
  sys.stdout.write("hex://agent-update?" + q)' 2>/dev/null)
  else
    base="hex://agent-update?event=unknown"
  fi

  [ -z "$base" ] && { rm -f "$payload"; exit 0; }

  # User answered in the terminal: release every hook still blocked on this session,
  # tell Hex to hide its panel, and get out of the way.
  case "$base" in
    *"event=UserPromptSubmit"*)
      sid=${base#*session=}
      sid=${sid%%&*}
      for p in "$dir"/hook.*.json; do
        [ -f "$p" ] && [ "$p" != "$payload" ] || continue
        case "$(cat "$p" 2>/dev/null)" in
          *"$sid"*) : > "$p.response" ;;
        esac
      done
      rm -f "$payload"
      open_url "$base"
      exit 0 ;;
  esac

  penc=$(printf '%s' "$payload" | encode)
  open_url "${base}&payload=${penc}"

  # Block until Hex answers (or ~9.5 min, under the 600s hook timeout).
  # Non-empty response = hook-output JSON to relay; empty = user dismissed.
  i=0
  while [ "$i" -lt 2850 ]; do
    if [ -f "$response" ]; then
      out=$(cat "$response" 2>/dev/null)
      rm -f "$response" "$payload"
      [ -n "$out" ] && printf '%s' "$out"
      exit 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  rm -f "$response" "$payload"
  exit 0
  """#
}
