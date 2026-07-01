---
"hex-app": minor
---

Add **Agent Plugins** — an opt-in voice window for coding agents (#2). When an installed agent finishes a turn, asks a multiple-choice question, or requests a permission, a floating window appears so you can answer by voice, typing, or tapping an option without leaving your editor.

- **Claude Code and pi:** ships integrations for both Claude Code and the pi coding agent, each behind a one-time copy-paste setup. They share a single `AgentIntegrationsClient` registry, so adding another agent is just one provider.
- **Sandbox-friendly install:** Hex stays sandboxed and never edits `~/.claude` or `~/.pi` itself. Settings → Agent Plugins shows a copy-paste terminal command that registers the hook/extension; the hook and Hex exchange messages through Hex's own container.
- **In-band replies:** answers are delivered to the exact agent session via a response file the hook relays — they can never land in the wrong window, and a reply can't silently fail after a card's hook has timed out.
- **Concurrent sessions:** blocked sessions queue one card at a time, and a header selector of project avatars (the repo's GitHub owner) switches between the ones waiting. Each card's header shows the project name and its current git branch.
- **Stays out of your way:** a hook-driven card appears passively without stealing keyboard focus from the editor you're typing in; engage it to reply, and any Enter (with or without a modifier) sends.
- **Optional read-aloud:** agent output can be spoken on-device via Kokoro TTS, with a selectable voice and a distinct voice per concurrent project.
