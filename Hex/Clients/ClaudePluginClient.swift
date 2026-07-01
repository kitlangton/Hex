//
//  ClaudePluginClient.swift
//  Hex
//
//  Bridges Hex (sandboxed) to Claude Code. Hex itself never writes ~/.claude — instead it
//  generates three scripts inside its OWN sandbox container (which it can write freely, and
//  which the user's unsandboxed `claude` hook process can also reach by absolute path):
//
//    <container>/agent/hook.sh        the real hook logic (refreshed by Hex on launch)
//    <container>/agent/install.sh     run once by the user to register the hooks
//    <container>/agent/uninstall.sh   run by the user to remove them
//    <container>/agent/io/            payload + response rendezvous files
//
//  The user pastes `sh <…>/agent/install.sh` into a terminal once. That writes a thin STUB
//  to ~/.claude/hex/hex-agent-hook.sh which `exec`s the real hook in the container, and
//  merges the hook registrations into ~/.claude/settings.json. Because the real logic lives
//  in the container, Hex can update it on launch without the user re-running anything.
//
//  Rendezvous lives in the container so a sandboxed Hex can read the payload and write the
//  <payload>.response in-band, while the unsandboxed hook writes the payload and polls the
//  response — no App Group / provisioning required, so plain local ad-hoc signing works.
//

import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

private let pluginLogger = HexLog.app

// MARK: - Live implementation

/// Registered with the app via `AgentIntegrationsClient`. Not exposed as its own
/// dependency — features should go through the registry so they stay decoupled from
/// the list of installed integrations.
struct ClaudePluginClientLive: AgentIntegrationProvider {
  /// Hook events to register, with their matcher. Empty matcher == match all.
  private let events: [(event: String, matcher: String)] = [
    ("Stop", ""),
    ("PreToolUse", "AskUserQuestion"),
    ("PermissionRequest", ""),
    // Bookkeeping only: when the user answers directly in the terminal, release any
    // hooks still blocked waiting on Hex and hide the Hex panel.
    ("UserPromptSubmit", ""),
  ]

  @Shared(.hexSettings) var hexSettings: HexSettings

  /// Hex's container Data dir. Under the sandbox this is
  /// `~/Library/Containers/com.kitlangton.Hex/Data`; the user's shell reaches the same place
  /// via `$HOME/Library/Containers/…`. Both sides therefore agree on absolute paths.
  private var containerRoot: URL { URL(fileURLWithPath: NSHomeDirectory()) }
  private var agentDir: URL { containerRoot.appendingPathComponent("agent", isDirectory: true) }
  private var ioDir: URL { agentDir.appendingPathComponent("io", isDirectory: true) }
  private var realHookURL: URL { agentDir.appendingPathComponent("hook.sh") }
  private var installScriptURL: URL { agentDir.appendingPathComponent("install.sh") }
  private var uninstallScriptURL: URL { agentDir.appendingPathComponent("uninstall.sh") }
  /// Sentinel the hook checks first: present only while the feature is enabled, so a disabled
  /// toggle makes every hook exit instantly instead of blocking ~9.5 min on a response.
  private var enabledFlagURL: URL { agentDir.appendingPathComponent("enabled") }
  /// Sentinel mirroring the read-aloud toggle: present only while the voice window is reading
  /// output aloud. When set, the Stop hook generates a short spoken summary (via headless
  /// `claude --safe-mode -p`) so Hex can offer a condensed read-aloud.
  private var readAloudFlagURL: URL { agentDir.appendingPathComponent("read-aloud") }

  var installCommand: String { "sh '\(installScriptURL.path)'" }
  var uninstallCommand: String { "sh '\(uninstallScriptURL.path)'" }

  // MARK: AgentIntegrationProvider

  var descriptor: AgentIntegration {
    AgentIntegration(
      id: "claude",
      displayName: "Claude Code",
      icon: .asset("IntegrationClaude"),
      installCaption: "Run this once in a terminal to register the Hex hooks with Claude Code:",
      uninstallCaption: "Run this to remove the hooks, then restart your claude sessions:",
      installCommand: installCommand,
      uninstallCommand: uninstallCommand
    )
  }

  // MARK: Prepare

  /// (Re)writes the three scripts if missing or out of date. Bakes in OUR bundle id + app
  /// path (so the hook delivers the deeplink to this exact Hex) and the absolute container
  /// paths (so the stub and the rendezvous resolve from the user's shell).
  func prepare() {
    do {
      try FileManager.default.createDirectory(at: ioDir, withIntermediateDirectories: true)
      let bundleID = Bundle.main.bundleIdentifier ?? "com.kitlangton.Hex"
      let appPath = Bundle.main.bundlePath
      writeIfChanged(
        Self.hookScript(bundleID: bundleID, appPath: appPath, ioDir: ioDir.path, enabledFlag: enabledFlagURL.path, readAloudFlag: readAloudFlagURL.path),
        to: realHookURL, executable: true
      )
      writeIfChanged(
        Self.installScript(stubReferences: realHookURL.path, events: events),
        to: installScriptURL, executable: true
      )
      writeIfChanged(Self.uninstallScript(), to: uninstallScriptURL, executable: true)
      syncEnabledFlag()
    } catch {
      pluginLogger.error("Failed to prepare Claude agent scripts: \(error.localizedDescription)")
    }
  }

  /// Mirrors the in-app toggles onto disk for the hook to read: each sentinel is present when
  /// its setting is on, absent when off. Called from `prepare()` (launch / settings open /
  /// toggle), including when the voice window's read-aloud toggle flips.
  private func syncEnabledFlag() {
    setFlag(enabledFlagURL, on: hexSettings.agentPluginsEnabled)
    // Only spend a model call on a spoken summary while we're reading aloud AND the global
    // condensed setting is on — with it off, every reply is read in full for free.
    setFlag(readAloudFlagURL, on: hexSettings.agentPluginsEnabled && hexSettings.agentSpeakOutput && hexSettings.agentSpeakCondensed)
  }

  private func setFlag(_ url: URL, on: Bool) {
    if on {
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func writeIfChanged(_ contents: String, to url: URL, executable: Bool) {
    if (try? String(contentsOf: url, encoding: .utf8)) == contents { return }
    do {
      try contents.write(to: url, atomically: true, encoding: .utf8)
      if executable {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      }
    } catch {
      pluginLogger.error("Failed to write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
    }
  }

  // MARK: install.sh / uninstall.sh

  private static func installScript(stubReferences realHookPath: String, events: [(event: String, matcher: String)]) -> String {
    // The events the python merge will register, as a Python list literal.
    let eventLiteral = events.map { "(\"\($0.event)\", \"\($0.matcher)\")" }.joined(separator: ", ")
    return installScriptTemplate
      .replacingOccurrences(of: "__REAL_HOOK_PATH__", with: realHookPath)
      .replacingOccurrences(of: "__EVENTS__", with: eventLiteral)
  }

  private static let installScriptTemplate = #"""
  #!/bin/sh
  # Hex Agent Plugins installer. Generated by Hex.app — safe to re-run.
  set -e
  STUB="$HOME/.claude/hex/hex-agent-hook.sh"
  mkdir -p "$HOME/.claude/hex"

  # A thin stub that execs the real hook from Hex's container, so Hex can update the real
  # logic on launch without you re-running this installer.
  cat > "$STUB" <<'STUBEOF'
  #!/bin/sh
  exec sh "__REAL_HOOK_PATH__" "$@"
  STUBEOF
  chmod 755 "$STUB"

  if command -v python3 >/dev/null 2>&1; then
    STUB="$STUB" python3 <<'PYEOF'
  import json, os
  stub = os.environ["STUB"]
  p = os.path.expanduser("~/.claude/settings.json")
  try:
      d = json.load(open(p))
      if not isinstance(d, dict): d = {}
  except Exception:
      d = {}
  hooks = d.get("hooks") if isinstance(d.get("hooks"), dict) else {}
  events = [__EVENTS__]
  for ev, matcher in events:
      groups = [g for g in hooks.get(ev, []) if not any(h.get("command") == stub for h in g.get("hooks", []))]
      groups.append({"matcher": matcher, "hooks": [{"type": "command", "command": stub, "timeout": 600}]})
      hooks[ev] = groups
  d["hooks"] = hooks
  os.makedirs(os.path.dirname(p), exist_ok=True)
  json.dump(d, open(p, "w"), indent=2)
  print("Hex: registered Claude Code hooks in ~/.claude/settings.json")
  PYEOF
  else
    echo "Hex installer needs python3 (Xcode Command Line Tools: xcode-select --install)." >&2
    exit 1
  fi
  echo "Done. Restart any running 'claude' sessions to pick up the hooks."
  """#

  private static func uninstallScript() -> String {
    #"""
    #!/bin/sh
    # Hex Agent Plugins uninstaller. Generated by Hex.app.
    STUB="$HOME/.claude/hex/hex-agent-hook.sh"
    if command -v python3 >/dev/null 2>&1; then
      STUB="$STUB" python3 <<'PYEOF'
    import json, os
    stub = os.environ["STUB"]
    p = os.path.expanduser("~/.claude/settings.json")
    try:
        d = json.load(open(p))
        if not isinstance(d, dict): d = {}
    except Exception:
        d = {}
    hooks = d.get("hooks") if isinstance(d.get("hooks"), dict) else {}
    for ev in list(hooks.keys()):
        groups = [g for g in hooks.get(ev, []) if not any(h.get("command") == stub for h in g.get("hooks", []))]
        if groups: hooks[ev] = groups
        else: hooks.pop(ev, None)
    if hooks: d["hooks"] = hooks
    else: d.pop("hooks", None)
    json.dump(d, open(p, "w"), indent=2)
    print("Hex: removed Claude Code hooks from ~/.claude/settings.json")
    PYEOF
    fi
    rm -rf "$HOME/.claude/hex"
    echo "Removed. Restart any running 'claude' sessions."
    """#
  }

  // MARK: Real hook

  static func hookScript(bundleID: String, appPath: String, ioDir: String, enabledFlag: String, readAloudFlag: String) -> String {
    hookScriptTemplate
      .replacingOccurrences(of: "__HEX_BUNDLE_ID__", with: bundleID)
      .replacingOccurrences(of: "__HEX_APP_PATH__", with: appPath)
      .replacingOccurrences(of: "__IO_DIR__", with: ioDir)
      .replacingOccurrences(of: "__ENABLED_FLAG__", with: enabledFlag)
      .replacingOccurrences(of: "__READ_ALOUD_FLAG__", with: readAloudFlag)
  }

  private static let hookScriptTemplate: String = #"""
  #!/bin/sh
  # Hex Agent Plugins hook — bridges Claude Code to the Hex voice window.
  # Generated and managed by Hex.app (Settings → Agent Plugins).

  # Re-entrancy guard: the read-aloud summary step shells out to `claude` to condense the reply.
  # That call uses `--safe-mode` (hooks disabled) so it should never re-enter this hook, but we
  # also stamp HEX_AGENT_SUMMARY and bail here as belt-and-suspenders against recursion.
  [ -n "$HEX_AGENT_SUMMARY" ] && exit 0
  input=$(cat)

  # Agent Plugins disabled in Hex → do nothing and let Claude continue, instantly. No deeplink,
  # no Hex launch, no blocking on a response. The sentinel is present only while enabled.
  [ -f "__ENABLED_FLAG__" ] || exit 0

  HEX_BUNDLE_ID="__HEX_BUNDLE_ID__"
  HEX_APP_PATH="__HEX_APP_PATH__"
  READ_ALOUD_FLAG="__READ_ALOUD_FLAG__"

  # Rendezvous inside Hex's sandbox container so the sandboxed app can read the payload and
  # write the <payload>.response, while this (unsandboxed) hook writes the payload and polls.
  dir="__IO_DIR__"
  mkdir -p "$dir" 2>/dev/null
  payload="$dir/hook.$$.json"
  printf '%s' "$input" > "$payload" 2>/dev/null
  response="$payload.response"

  # For Stop, fold the last assistant message into the payload so Hex (sandboxed, no access
  # to ~/.claude) never needs to read the transcript itself.
  if command -v python3 >/dev/null 2>&1; then
    PAYLOAD="$payload" python3 <<'PYEOF' 2>/dev/null || true
  import json, os
  path = os.environ["PAYLOAD"]
  try:
      d = json.load(open(path))
  except Exception:
      raise SystemExit(0)
  if d.get("hook_event_name") != "Stop" or d.get("last_assistant_message"):
      raise SystemExit(0)
  tp = os.path.expanduser(d.get("transcript_path") or "")
  try:
      lines = open(tp, encoding="utf-8").read().splitlines()
  except Exception:
      raise SystemExit(0)
  collected = []
  for line in reversed(lines):
      line = line.strip()
      if not line:
          continue
      try:
          obj = json.loads(line)
      except Exception:
          continue
      t = obj.get("type")
      if t == "assistant":
          content = (obj.get("message") or {}).get("content")
          text = ""
          if isinstance(content, list):
              text = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
          elif isinstance(content, str):
              text = content
          if text.strip():
              collected.append(text)
      elif t == "user" and collected:
          break
  if collected:
      d["last_assistant_message"] = "\n".join(reversed(collected)).strip()
      json.dump(d, open(path, "w"))
  PYEOF
  fi

  # When the voice window is reading output aloud, generate a short spoken summary with headless
  # Claude so Hex can offer a condensed read-aloud — without putting any marker in the visible
  # reply. Gated on the read-aloud sentinel so we never spend a model call when it is off. The
  # `--safe-mode` flag disables hooks/MCP/plugins (while keeping OAuth auth) so this nested call
  # cannot recurse into this hook; HEX_AGENT_SUMMARY guards the same at the top of this script.
  if [ -f "$READ_ALOUD_FLAG" ] && command -v claude >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    PAYLOAD="$payload" python3 <<'PYEOF' 2>/dev/null || true
  import json, os, subprocess
  path = os.environ["PAYLOAD"]
  try:
      d = json.load(open(path))
  except Exception:
      raise SystemExit(0)
  if d.get("hook_event_name") != "Stop" or d.get("hex_condensed"):
      raise SystemExit(0)
  full = (d.get("last_assistant_message") or "").strip()
  if not full:
      raise SystemExit(0)
  prompt = (
      "Condense the assistant message below into a spoken heads-up for a text-to-speech reader. "
      "Surface only what the user needs to pay attention "
      "to: the key outcome, anything blocking, risky, or unexpected, and any question being asked. "
      "Plain prose, no markdown or code. Output only the summary, nothing else.\n\n" + full
  )
  env = {**os.environ, "HEX_AGENT_SUMMARY": "1"}
  try:
      out = subprocess.run(
          ["claude", "--safe-mode", "-p", prompt, "--model", "haiku"],
          capture_output=True, text=True, timeout=45, env=env,
      )
  except Exception:
      raise SystemExit(0)
  summary = (out.stdout or "").strip()
  if summary:
      d["hex_condensed"] = summary
      json.dump(d, open(path, "w"))
  PYEOF
  fi

  encode() {
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.quote(sys.stdin.read()))'
    else
      sed 's/ /%20/g'
    fi
  }

  # -g: deliver the URL in the BACKGROUND. Without it, `open` activates Hex, yanking your
  # editor out of focus the moment a card appears (and beeping when keys hit no field).
  open_url() {
    if [ -n "$HEX_BUNDLE_ID" ] && /usr/bin/open -g -b "$HEX_BUNDLE_ID" "$1" >/dev/null 2>&1; then
      return 0
    fi
    if [ -n "$HEX_APP_PATH" ] && [ -d "$HEX_APP_PATH" ] && /usr/bin/open -g -a "$HEX_APP_PATH" "$1" >/dev/null 2>&1; then
      return 0
    fi
    /usr/bin/open -g "$1" >/dev/null 2>&1 || open -g "$1" >/dev/null 2>&1
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

  # Resolve the project's GitHub owner here — Hex is sandboxed and can't spawn git against a
  # project dir outside its container — and pass it so the app can build the avatar URL.
  cwd=$(printf '%s' "$input" | (jq -r '.cwd // ""' 2>/dev/null || python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin).get("cwd",""))' 2>/dev/null))
  if [ -n "$cwd" ]; then
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] && base="${base}&branch=$(printf '%s' "$branch" | encode)"
    remote=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null)
    case "$remote" in
      *github.com*)
        rest=${remote#*github.com}
        rest=${rest#:}
        rest=${rest#/}
        owner=${rest%%/*}
        [ -n "$owner" ] && base="${base}&owner=$(printf '%s' "$owner" | encode)"
        ;;
    esac
  fi

  penc=$(printf '%s' "$payload" | encode)
  open_url "${base}&payload=${penc}"

  # Block until Hex answers (or ~9.5 min, under the 600s hook timeout).
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
