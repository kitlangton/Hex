//
//  PiPluginClient.swift
//  Hex
//
//  Companion to ClaudePluginClient — bridges Hex (sandboxed) to the pi coding agent
//  (https://pi.dev). Pi has no external-shell-hook mechanism like Claude Code; instead
//  it auto-discovers TypeScript extensions in `~/.pi/agent/extensions/`. So we generate
//  a small extension that speaks the SAME Claude-shaped JSON dialect Hex already produces
//  and consumes (via AgentHookResponder + AgentTranscriptClient), then maps it onto pi's
//  event names. This lets us reuse 100% of the app-side voice/window/rendezvous code.
//
//  Files in our container:
//
//    <container>/agent/pi/extension.ts      the real pi extension (refreshed on launch)
//    <container>/agent/pi-install.sh        run once: symlinks into ~/.pi/agent/extensions
//    <container>/agent/pi-uninstall.sh      removes the symlink
//    <container>/agent/io/                  shared rendezvous dir (same as Claude)
//    <container>/agent/enabled              shared on/off sentinel (same as Claude)
//
//  The install script creates `~/.pi/agent/extensions/hex/index.ts` as a symlink to the
//  container path, so Hex updates to the extension take effect on the next pi `/reload`
//  without the user re-running anything.
//

import ComposableArchitecture
import Dependencies
import Foundation
import HexCore

private let piPluginLogger = HexLog.app

// MARK: - Live implementation

/// Registered with the app via `AgentIntegrationsClient`. Not exposed as its own
/// dependency — features should go through the registry so they stay decoupled from
/// the list of installed integrations.
struct PiPluginClientLive: AgentIntegrationProvider {
  @Shared(.hexSettings) var hexSettings: HexSettings

  /// Same container layout as ClaudePluginClient — we deliberately share `io/` and
  /// `enabled` so the toggle and the rendezvous infrastructure stay unified across
  /// agent integrations.
  private var containerRoot: URL { URL(fileURLWithPath: NSHomeDirectory()) }
  private var agentDir: URL { containerRoot.appendingPathComponent("agent", isDirectory: true) }
  private var ioDir: URL { agentDir.appendingPathComponent("io", isDirectory: true) }
  private var piDir: URL { agentDir.appendingPathComponent("pi", isDirectory: true) }
  private var extensionURL: URL { piDir.appendingPathComponent("extension.ts") }
  private var installScriptURL: URL { agentDir.appendingPathComponent("pi-install.sh") }
  private var uninstallScriptURL: URL { agentDir.appendingPathComponent("pi-uninstall.sh") }
  /// Shared with ClaudePluginClient: a sentinel file the integrations check first so a
  /// disabled toggle short-circuits everything without re-running any installer.
  private var enabledFlagURL: URL { agentDir.appendingPathComponent("enabled") }

  var installCommand: String { "sh '\(installScriptURL.path)'" }
  var uninstallCommand: String { "sh '\(uninstallScriptURL.path)'" }

  // MARK: AgentIntegrationProvider

  var descriptor: AgentIntegration {
    AgentIntegration(
      id: "pi",
      displayName: "pi",
      icon: .asset("IntegrationPi"),
      installCaption: "Run this once to install the Hex extension into ~/.pi/agent/extensions/, then /reload inside pi:",
      uninstallCaption: "Run this to remove the extension, then /reload inside pi:",
      installCommand: installCommand,
      uninstallCommand: uninstallCommand
    )
  }

  // MARK: Prepare

  func prepare() {
    do {
      try FileManager.default.createDirectory(at: ioDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
      let bundleID = Bundle.main.bundleIdentifier ?? "com.kitlangton.Hex"
      let appPath = Bundle.main.bundlePath
      writeIfChanged(
        Self.extensionScript(
          bundleID: bundleID,
          appPath: appPath,
          ioDir: ioDir.path,
          enabledFlag: enabledFlagURL.path
        ),
        to: extensionURL, executable: false
      )
      writeIfChanged(
        Self.installScript(extensionPath: extensionURL.path),
        to: installScriptURL, executable: true
      )
      writeIfChanged(
        Self.uninstallScript(),
        to: uninstallScriptURL, executable: true
      )
      syncEnabledFlag()
    } catch {
      piPluginLogger.error("Failed to prepare pi agent scripts: \(error.localizedDescription)")
    }
  }

  /// Mirrors the in-app toggle onto disk. Shared with ClaudePluginClient — calling either
  /// prepare() yields the same sentinel state.
  private func syncEnabledFlag() {
    if hexSettings.agentPluginsEnabled {
      if !FileManager.default.fileExists(atPath: enabledFlagURL.path) {
        FileManager.default.createFile(atPath: enabledFlagURL.path, contents: nil)
      }
    } else {
      try? FileManager.default.removeItem(at: enabledFlagURL)
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
      piPluginLogger.error("Failed to write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
    }
  }

  // MARK: install.sh / uninstall.sh

  private static func installScript(extensionPath: String) -> String {
    installScriptTemplate.replacingOccurrences(of: "__EXT_PATH__", with: extensionPath)
  }

  private static let installScriptTemplate = #"""
  #!/bin/sh
  # Hex pi-extension installer. Generated by Hex.app — safe to re-run.
  set -e
  EXT_DIR="$HOME/.pi/agent/extensions/hex"
  mkdir -p "$EXT_DIR"
  # Symlink so Hex can update extension.ts on launch and pi picks it up via /reload
  # without the user re-running this installer.
  ln -sfn "__EXT_PATH__" "$EXT_DIR/index.ts"
  echo "Hex: installed pi extension at $EXT_DIR/index.ts"
  echo "Run '/reload' inside pi (or restart it) to activate."
  """#

  private static func uninstallScript() -> String {
    #"""
    #!/bin/sh
    # Hex pi-extension uninstaller. Generated by Hex.app.
    EXT_DIR="$HOME/.pi/agent/extensions/hex"
    rm -rf "$EXT_DIR"
    echo "Hex: removed pi extension at $EXT_DIR"
    echo "Run '/reload' inside pi (or restart it) to deactivate."
    """#
  }

  // MARK: pi extension (TypeScript)

  static func extensionScript(bundleID: String, appPath: String, ioDir: String, enabledFlag: String) -> String {
    extensionScriptTemplate
      .replacingOccurrences(of: "__HEX_BUNDLE_ID__", with: bundleID)
      .replacingOccurrences(of: "__HEX_APP_PATH__", with: appPath)
      .replacingOccurrences(of: "__IO_DIR__", with: ioDir)
      .replacingOccurrences(of: "__ENABLED_FLAG__", with: enabledFlag)
  }

  /// The TypeScript extension. Pi loads this via jiti, so plain `.ts` works without
  /// any build step. We keep the surface minimal:
  ///
  ///   - `agent_end`            → Stop  (speak the last assistant message; if the user
  ///                              answers, feed it back as the next user turn)
  ///   - `tool_call` (dangerous bash)
  ///                            → PermissionRequest  (voice allow/deny)
  ///   - `ask_user` custom tool → PreToolUse / AskUserQuestion (voice question + options)
  ///
  /// All three speak the same Claude-shaped JSON that Hex's AgentHookResponder writes,
  /// so the app side needs zero changes.
  private static let extensionScriptTemplate: String = ##"""
  // Hex ↔ pi bridge extension. Generated and managed by Hex.app (Settings → Agent Plugins).
  // Do not edit by hand — Hex overwrites this file on launch.

  import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
  import { Type } from "typebox";
  import fs from "node:fs";
  import path from "node:path";
  import { execFile } from "node:child_process";
  import { randomUUID } from "node:crypto";

  const HEX_BUNDLE_ID = "__HEX_BUNDLE_ID__";
  const HEX_APP_PATH = "__HEX_APP_PATH__";
  const IO_DIR = "__IO_DIR__";
  const ENABLED_FLAG = "__ENABLED_FLAG__";

  // Mirrors the Claude hook's ~9.5 min ceiling so a forgotten card eventually frees the
  // turn instead of pinning pi forever.
  const RENDEZVOUS_TIMEOUT_MS = 9.5 * 60 * 1000;
  const POLL_INTERVAL_MS = 200;

  function enabled(): boolean {
    try { return fs.existsSync(ENABLED_FLAG); } catch { return false; }
  }

  function openDeeplink(url: string): Promise<void> {
    return new Promise((resolve) => {
      // -g: deliver in the background so the user's editor keeps focus.
      // Try the bundle id first (resilient to app moves), then the absolute path, then a
      // generic `open` (lets the user's launch services routing decide).
      const tryNext = (attempts: Array<() => Promise<boolean>>) => {
        if (attempts.length === 0) return resolve();
        attempts[0]().then((ok) => ok ? resolve() : tryNext(attempts.slice(1)));
      };
      const attempt = (args: string[]) => () => new Promise<boolean>((res) => {
        execFile("/usr/bin/open", args, (err) => res(!err));
      });
      tryNext([
        attempt(["-g", "-b", HEX_BUNDLE_ID, url]),
        attempt(["-g", "-a", HEX_APP_PATH, url]),
        attempt(["-g", url]),
      ]);
    });
  }

  async function sleep(ms: number): Promise<void> {
    return new Promise((r) => setTimeout(r, ms));
  }

  /**
   * Writes a Claude-shaped hook payload into IO_DIR, opens the hex:// deeplink, and
   * polls for `<payload>.response`. Returns the parsed JSON, or `null` if the user
   * dismissed (empty response file) or we timed out.
   */
  async function rendezvous(
    payload: Record<string, unknown>,
    extras: Record<string, string>,
    signal?: AbortSignal,
  ): Promise<Record<string, unknown> | null> {
    try { fs.mkdirSync(IO_DIR, { recursive: true }); } catch {}
    const id = `${process.pid}.${randomUUID()}`;
    const payloadPath = path.join(IO_DIR, `hook.${id}.json`);
    const responsePath = `${payloadPath}.response`;

    try {
      fs.writeFileSync(payloadPath, JSON.stringify(payload));
    } catch {
      return null;
    }

    const qs = new URLSearchParams({
      event: (payload["hook_event_name"] as string) ?? "",
      tool: (payload["tool_name"] as string) ?? "",
      session: (payload["session_id"] as string) ?? "",
      transcript: (payload["transcript_path"] as string) ?? "",
      cwd: (payload["cwd"] as string) ?? "",
      ...extras,
      payload: payloadPath,
    });
    await openDeeplink(`hex://agent-update?${qs.toString()}`);

    const deadline = Date.now() + RENDEZVOUS_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (signal?.aborted) break;
      if (fs.existsSync(responsePath)) {
        let text = "";
        try { text = fs.readFileSync(responsePath, "utf8"); } catch {}
        try { fs.unlinkSync(responsePath); } catch {}
        try { fs.unlinkSync(payloadPath); } catch {}
        if (!text) return null;
        try { return JSON.parse(text); } catch { return null; }
      }
      await sleep(POLL_INTERVAL_MS);
    }
    // Timed out: clean up so we don't leak rendezvous files on disk.
    try { fs.unlinkSync(payloadPath); } catch {}
    try { fs.unlinkSync(responsePath); } catch {}
    return null;
  }

  /** Pull the last assistant text from the session, mirroring what Hex does for Claude. */
  function lastAssistantMessage(ctx: ExtensionContext): string {
    const entries = ctx.sessionManager.getEntries();
    for (let i = entries.length - 1; i >= 0; i--) {
      const entry = entries[i] as any;
      if (entry?.type !== "message") continue;
      const msg = entry.message;
      if (msg?.role !== "assistant") continue;
      const content = msg.content;
      if (typeof content === "string") return content;
      if (Array.isArray(content)) {
        const text = content
          .filter((b: any) => b?.type === "text" && typeof b.text === "string")
          .map((b: any) => b.text)
          .join("\n")
          .trim();
        if (text) return text;
      }
    }
    return "";
  }

  /** Dangerous patterns we voice-gate by default. Users wanting tighter / looser control
   * can layer additional `tool_call` handlers from their own extensions. */
  const DANGEROUS_BASH = [
    /\brm\s+(-rf?|--recursive)/i,
    /\bsudo\b/i,
    /\b(chmod|chown)\b.*777/i,
  ];

  function isDangerousBash(toolName: string, input: any): boolean {
    if (toolName !== "bash") return false;
    const cmd = (input?.command ?? "") as string;
    return DANGEROUS_BASH.some((p) => p.test(cmd));
  }

  export default function (pi: ExtensionAPI) {
    // == Claude "Stop": speak the last assistant message; if the user answers, the
    // response carries `decision: "block", reason: "..."` and we feed `reason` back
    // as the next user message — same semantic as Claude's blocked Stop hook.
    pi.on("agent_end", async (_event, ctx) => {
      if (!enabled()) return;
      const last = lastAssistantMessage(ctx);
      if (!last) return;
      const sessionFile = ctx.sessionManager.getSessionFile?.() ?? "";
      const response = await rendezvous({
        hook_event_name: "Stop",
        session_id: sessionFile,
        transcript_path: sessionFile,
        cwd: ctx.cwd,
        last_assistant_message: last,
      }, {}, ctx.signal);
      const reason = (response as any)?.reason;
      if ((response as any)?.decision === "block" && typeof reason === "string" && reason.trim()) {
        try {
          // agent_end fires while pi still considers itself processing, so a bare
          // sendUserMessage throws ("Agent is already processing"). deliverAs "steer"
          // queues the reply for the next LLM invocation — i.e. the user's spoken
          // answer becomes their next turn, matching Claude's blocked-Stop semantic.
          pi.sendUserMessage(reason, { deliverAs: "steer" });
        } catch {
          // Last-ditch guard: never let a delivery hiccup crash the agent loop.
        }
      }
    });

    // == Claude "PermissionRequest": voice-gate dangerous bash. Conservative by default;
    // returning `{ block: true, reason }` is pi's native deny.
    pi.on("tool_call", async (event, ctx) => {
      if (!enabled()) return;
      if (!isDangerousBash(event.toolName, event.input)) return;

      const sessionFile = ctx.sessionManager.getSessionFile?.() ?? "";
      const response = await rendezvous({
        hook_event_name: "PermissionRequest",
        tool_name: event.toolName,
        tool_input: event.input,
        session_id: sessionFile,
        transcript_path: sessionFile,
        cwd: ctx.cwd,
      }, {}, ctx.signal);

      const decision = (response as any)?.hookSpecificOutput?.decision;
      if (decision?.behavior === "deny") {
        return { block: true, reason: decision.message ?? "Denied by Hex" };
      }
      // allow / dismissed → fall through (no block).
    });

    // == Claude "AskUserQuestion": register a tool the LLM can call to ask the user a
    // voice question. Returns the user's spoken answer as the tool result. The request
    // matches Claude's AskUserQuestion `tool_input` shape so Hex's existing question
    // parser reads it unchanged.
    pi.registerTool({
      name: "ask_user",
      label: "Ask User",
      description: "Ask the user a voice question and wait for their spoken answer. Use when you need user input to proceed.",
      promptSnippet: "Ask the user a voice question via Hex; returns the spoken answer.",
      parameters: Type.Object({
        question: Type.String({ description: "The question to ask" }),
        header: Type.Optional(Type.String({ description: "Short title shown above the question" })),
        options: Type.Optional(Type.Array(
          Type.Object({
            label: Type.String(),
            description: Type.Optional(Type.String()),
          }),
          { description: "Optional choices the user can pick from" },
        )),
      }),
      async execute(_toolCallId, params, signal, _onUpdate, ctx) {
        if (!enabled()) {
          return {
            content: [{ type: "text", text: "Hex agent plugins are disabled; no answer captured." }],
            details: { question: params.question, answer: null },
          };
        }
        const sessionFile = ctx.sessionManager.getSessionFile?.() ?? "";
        const toolInput = {
          questions: [{
            header: params.header ?? "",
            question: params.question,
            multiSelect: false,
            options: params.options ?? [],
          }],
        };
        const response = await rendezvous({
          hook_event_name: "PreToolUse",
          tool_name: "AskUserQuestion",
          tool_input: toolInput,
          session_id: sessionFile,
          transcript_path: sessionFile,
          cwd: ctx.cwd,
        }, {}, signal);

        const answers = (response as any)?.hookSpecificOutput?.updatedInput?.answers ?? {};
        const answer = (answers[params.question] as string | undefined) ?? null;
        if (!answer) {
          return {
            content: [{ type: "text", text: "User dismissed the question." }],
            details: { question: params.question, answer: null },
          };
        }
        return {
          content: [{ type: "text", text: `User answered: ${answer}` }],
          details: { question: params.question, answer },
        };
      },
    });
  }
  """##
}
