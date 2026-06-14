---
"hex-app": patch
---

Remove the source-app name from the Agent Plugins voice window header. It showed whichever app was frontmost when the dialog appeared (e.g. your browser), which was misleading since replies are delivered in-band to the Claude Code session regardless of the foreground app. The header now shows just the project name and the queue position.
