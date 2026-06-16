---
"hex-app": minor
---

Hex now runs under the macOS App Sandbox again. The Claude Code integration no longer requires Hex to read or write `~/.claude` directly: Hex generates the hook + an installer inside its own sandbox container, and Settings → Agent Plugins shows a one-time copy-paste command you run in a terminal to register the hooks. The hook and Hex exchange messages through Hex's container, and the hook bundles Claude's last message into the payload so the sandboxed app never needs to read the session transcript. Removing an integration is a matching copy-paste command.
