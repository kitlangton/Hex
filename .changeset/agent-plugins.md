---
"hex-app": minor
---

Add Agent Plugins: a voice window for Claude Code. When Claude Code finishes a turn, asks a question, or requests a permission, Hex pops a floating window showing the prompt with a field you can dictate or type a reply into. Answers are delivered in-band: the Claude Code hook blocks while Hex is open, and Hex answers it directly (Stop follow-ups, AskUserQuestion answers, permission allow/deny) — no terminal focusing or synthetic keystrokes, so replies always reach the right session even while you work in another app. Answering in the terminal instead just dismisses the Hex window. Includes a new Agent Plugins settings tab with one-click install of the Claude Code hooks.
