# Design: Re-sandbox Hex (Agent Plugins under the App Sandbox)

Status: proposed · Owner: agent-plugins · Target branch: `agent-sandbox`

## Goal

Turn `com.apple.security.app-sandbox` back **on** while keeping the Agent Plugins
integration working. Today the integration is the *only* reason the app ships
unsandboxed (see `Hex.entitlements`, currently `app-sandbox = false`).

Decisions already taken (this doc assumes them):

- **Remove the terminal-typing / "trigger agent" path entirely.** No more
  synthetic keystrokes into another app. The reliable in-band reply path stays.
- **No install self-verification.** Hex won't read `~/.claude` to confirm the
  hook is registered. Uninstall is a manual step the user performs.

Non-goals (separate future work): channels (the proper way to talk to *idle*
sessions), Mac App Store distribution.

## Why the app is unsandboxed today

Three things in the Claude integration reach outside the app container:

1. **Install writes to `~/.claude`** — `ClaudePluginClient.install()` writes
   `~/.claude/hex/hex-agent-hook.sh` and merges hook registrations into
   `~/.claude/settings.json` (resolved via `NSHomeDirectory()`).
2. **Runtime IPC uses the user's `$TMPDIR`** — the hook writes the payload to
   `${TMPDIR:-/tmp}/hex-agent/hook.$$.json` and polls for `<payload>.response`;
   Hex reads the payload (`AgentTranscriptClient`) and writes the response
   (`AgentHookResponder`).
3. **Stop-hook fallback reads `~/.claude/projects/<…>/<session>.jsonl`** — to
   show Claude's last assistant message when the hook JSON doesn't carry it.

Two sandbox traps make this worse than it looks:

- Under the sandbox, **`NSHomeDirectory()` returns the container**
  (`~/Library/Containers/com.kitlangton.Hex/Data`), not real `~`. So the install
  paths silently point into the container.
- Under the sandbox, **Hex's `$TMPDIR` is the container's temp**, which is *not*
  the same directory the user's hook process sees. The shared-file IPC would
  stop being shared.

So a copy-paste installer alone is insufficient — the **runtime** handoff also
crosses the sandbox boundary and must move.

Good news: **Sparkle is already configured for the sandbox.** The
`…-spks` / `…-spki` `mach-lookup` temporary-exception entitlements are the
sandboxed-Sparkle XPC pattern, which strongly implies the app was sandboxed
before the agent-plugins work flipped it off. We are largely restoring a
known-good config plus solving the IPC relocation.

## Design overview

> **Pivot (local-first):** the original draft used an **App Group** container as
> the rendezvous. App Groups need a real Developer-ID provisioning profile, which
> doesn't work under local ad-hoc signing. Since the near-term goal is "works on my
> machine," we instead use **Hex's own sandbox container**
> (`~/Library/Containers/com.kitlangton.Hex/Data`, == `NSHomeDirectory()` under the
> sandbox). A sandboxed app reads/writes its own container with **no entitlement and
> no provisioning**, so plain ad-hoc signing works; the unsandboxed hook (a
> user-owned process) can also write into it. We can switch to an App Group later
> for the upstream PR. Also: `git` for avatar resolution can't run sandboxed against
> a project dir outside the container, so avatar resolution moves into the hook too
> (follow-up).

Four moving parts:

1. **Hex's sandbox container** is the IPC rendezvous (a path both the sandboxed app
   — via `NSHomeDirectory()` — and the unsandboxed hook — via
   `$HOME/Library/Containers/com.kitlangton.Hex/Data` — reach). No App Group.
2. **Install becomes a copy-paste terminal command** the user runs once. Hex
   never writes `~/.claude`.
3. **A thin stub hook** in `~/.claude` execs the **real hook logic from the group
   container**, which sandboxed Hex *can* keep up to date — so app updates don't
   require re-running the installer.
4. **The hook does all `~/.claude` reads** (incl. the transcript tail) and bundles
   what Hex needs into the payload. Hex only ever reads the group container.

Plus the agreed removal of the terminal-typing path.

### 1. App Group container (the rendezvous)

- Group id: `group.com.kitlangton.Hex` (final form may need the team-id prefix for
  Developer ID signing — **verify during the spike**, see Risks).
- Location: `~/Library/Group Containers/group.com.kitlangton.Hex/`.
- Hex resolves it with
  `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`.
- Layout:
  - `agent/hook.sh` — the real hook logic, written & refreshed by Hex on launch.
  - `agent/io/hook.<pid>.json` — per-invocation payload (written by the hook).
  - `agent/io/hook.<pid>.json.response` — the reply (written by Hex; or empty by
    the hook for "dismissed / yield to TUI").
  - `agent/install.sh` — the generated one-time installer (written by Hex).
- Access model: the sandboxed app reaches the group container via the
  `application-groups` entitlement; the **unsandboxed** hook process reaches the
  same directory by ordinary user file permissions (the user owns it). This is
  the canonical "share between a sandboxed app and a helper" location.

### 2. Entitlements (`Hex.entitlements`)

- `com.apple.security.app-sandbox` → **`true`**.
- Add `com.apple.security.application-groups` → `[ group.com.kitlangton.Hex ]`.
- Keep: `network.client` (HF model downloads), `device.audio-input`,
  `files.user-selected.read-write` (optional model import), the Sparkle
  `mach-lookup` exceptions, `cs.disable-library-validation`.
- Re-evaluate `automation.apple-events`: only needed if a non-agent feature still
  uses Apple events (e.g. media pause). Keep for now; out of scope.
- `XDG_CACHE_HOME` already points into the container (set at launch) — unaffected.

### 3. Install: copy-paste command

UI (Settings → Agent Plugins) changes from an Install button that writes
`~/.claude` to:

- A read-only command field + **Copy** button showing exactly:
  ```
  sh ~/Library/Group\ Containers/group.com.kitlangton.Hex/agent/install.sh
  ```
- Short instructions: "Paste this into a terminal and press return. Re-run it if
  Hex tells you the integration needs updating."
- An **uninstall** command field + Copy button (manual removal):
  ```
  sh ~/Library/Group\ Containers/group.com.kitlangton.Hex/agent/uninstall.sh
  ```

Hex writes `install.sh` / `uninstall.sh` into the group container (it can do this
sandboxed) on launch / when the panel opens, with the bundle id, app path, and the
absolute group-container path baked in. Putting the heavy logic in a script we
generate keeps the clipboard payload to one line and lets the installer be robust.

`install.sh` does, idempotently:

1. `mkdir -p ~/.claude/hex`.
2. Write the **stub** hook to `~/.claude/hex/hex-agent-hook.sh` (see §4) and
   `chmod 755` it.
3. Merge the four hook registrations into `~/.claude/settings.json`, pointing at
   the stub path, preferring `python3`, falling back to `jq`; if neither exists,
   print a clear error telling the user to install one. (Claude Code users almost
   always have one.)

`uninstall.sh` removes the four registrations and deletes `~/.claude/hex`.

### 4. Thin stub + real hook in the group container

Problem: a sandboxed Hex can no longer refresh `~/.claude/hex/hex-agent-hook.sh`
when the protocol changes. Solution: split the hook.

- **Stub** (installed once into `~/.claude/hex/hex-agent-hook.sh`, stable forever):
  ```sh
  #!/bin/sh
  exec sh "$HOME/Library/Group Containers/group.com.kitlangton.Hex/agent/hook.sh" "$@"
  ```
- **Real hook** (`agent/hook.sh` in the group container): today's
  `hookScriptTemplate`, with two changes:
  - **Rendezvous path** → the group container's `agent/io/` instead of
    `${TMPDIR:-/tmp}/hex-agent`.
  - **Stop transcript extraction** → when `hook_event_name == "Stop"` and the hook
    JSON lacks the assistant text, the hook reads the tail of `transcript_path`
    (it runs unsandboxed, so it can), extracts the last assistant message, and
    writes it into the payload JSON. Hex then never touches `~/.claude/projects`.

Hex keeps a `refreshIfStale`-equivalent that rewrites `agent/hook.sh` in the group
container on launch (cheap diff). App updates therefore take effect without the
user re-running anything; the stub never changes. The user only re-runs
`install.sh` if the stub or the registration format itself changes (rare) — Hex
can surface a "needs reinstall" note keyed off a version stamp in the group
container (best-effort; not required for correctness).

### 5. Remove the terminal-typing / trigger-agent path

This is the agreed removal. It deletes the only code that needs to drive another
app, and it simplifies the data model.

What goes away (with user-facing impact):

- **Proactively composing to an idle session is gone** until channels lands. The
  voice window only ever *responds* to a session that is blocked on a hook.
- **Manual summon** (`openManually`) can no longer open a compose card to the most
  recent idle session. New behavior:
  - A session is currently blocked → engage/focus its live card.
  - Nothing is blocked → the "No Claude sessions" empty state.
- **The selector** becomes a *switcher across concurrently-blocked sessions* only.
  Idle sessions are no longer listed (they can't be targeted). It derives directly
  from the blocked queue (`requests` where `isBlocked`), so the `recentSessions`
  registry and the `composeFor` / `.compose` machinery can be removed.

Concretely (code-change checklist):

- `AgentFeature`
  - Remove `AgentRequest.Kind.compose` and `init(composeFor:)`; `Kind` collapses to
    just the hook case (or `Kind` is dropped and `payloadPath`/`isBlocked` derive
    from the stored payload path).
  - `.send`: drop the legacy `else` branch (activate + `pasteboard.type` +
    `sendKeyboardCommand`). A card with no `payloadPath` can no longer exist, so
    send is always the in-band path.
  - `.respondPermission`: drop the legacy numbered-menu typing fallback; always
    in-band.
  - Remove `activateTargetApp(pid:bundleID:)`.
  - `.openManually`: remove the "compose to most-recent session" branch; keep
    summon→empty-state and the engage/dismiss toggle.
  - `.selectAgent`: remove the idle-compose branch; only switches among blocked.
  - Remove the `recentSessions` registry, `RecentSession`, `rememberSession`, and
    rebuild `selectableAgents` from the blocked queue.
  - Drop `SessionContext.sourceAppBundleID` / `sourceAppPID` (only the typing path
    used them).
- `ShowPayload`: drop `sourceAppBundleID` / `sourceAppPID`.
- `HexAppDelegate`: remove foreground-app tracking (`startTrackingForegroundApp`,
  `lastForegroundApp`) and the `sourceApp*` fields it fed into `ShowPayload`. The
  comment says it exists solely "so Agent Plugins can paste back into the
  terminal" — dead once typing is gone. (Confirm `TranscriptionFeature`'s own
  source-app capture at ~line 297 is independent — it is.)
- `PasteboardClient`: leave `type` / `sendKeyboardCommand` if transcription still
  uses them; remove only if they become unused.
- `ClaudePluginClient`: replace `install`/`uninstall`/`refreshIfStale` so they
  write the installer/uninstaller + real hook into the **group container**, not
  `~/.claude`. `isInstalled` becomes best-effort or is dropped (no `~/.claude`
  read under sandbox).
- `AgentHookResponder` / `AgentTranscriptClient`: unchanged logic, but the
  `payloadPath` they operate on now lives in the group container. The transcript
  read in `AgentTranscriptClient` can be removed once the hook injects the Stop
  message into the payload.

### 6. Migration & uninstall

- Existing users (installed while unsandboxed): their old `~/.claude/hex` script
  points at `$TMPDIR`, which the new sandboxed Hex won't share — so it silently
  stops working. We can't reliably detect this under the sandbox. Mitigation:
  Settings prominently shows the new install command and an uninstall command for
  the old one. Acceptable per the "self-verification doesn't matter" decision.
- Uninstall is the `uninstall.sh` copy-paste command. Hex does not modify
  `~/.claude` itself.

## Risks / open questions (verify in the spike)

1. **App Group + Developer ID signing.** Confirm the group id format the
   provisioning/signing accepts for non-MAS distribution and that
   `containerURL(forSecurityApplicationGroupIdentifier:)` returns a writable path.
   This is the highest-risk item.
2. **`python3`/`jq` availability** for the settings.json merge in `install.sh`.
   Prefer `python3`, fall back to `jq`, else a clear error.
3. **Shell quoting** of the `Group Containers` path (has a space) in the stub and
   the install command.
4. **`open hex://` / `open -b` into a sandboxed app** — expected to work, but
   confirm Launch Services delivery and that the bundle-id targeting still wins
   over a stray second instance.
5. **Stop transcript tail parsing in shell** — correctness of extracting the last
   assistant message from the `.jsonl`.
6. **Sparkle still updates** under the (re-enabled) sandbox — expected given the
   existing XPC exceptions, but re-verify end to end.

## Rollout

1. Branch `agent-sandbox`; commit incrementally.
2. Land the typing-path removal first (pure deletion, independently testable).
3. Add the App Group entitlement + container plumbing; relocate the rendezvous.
4. Move install to the generated `install.sh` + stub/real-hook split.
5. Move the Stop transcript read into the hook.
6. Flip `app-sandbox = true`; verify no sandbox violations in Console, in-band
   replies work, hooks deliver, Sparkle updates.
7. Update `CLAUDE.md` (the entitlements/section notes that currently say
   "Requires the app to be UNSANDBOXED") and `ClaudePluginClient`'s header.

## Out of scope (follow-ups)

- **Channels** restore the ability to talk to *idle* sessions (the capability the
  typing path approximated). That's the real replacement for "trigger agent" and
  is tracked separately.
