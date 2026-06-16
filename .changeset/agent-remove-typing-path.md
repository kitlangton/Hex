---
"hex-app": minor
---

The Agent Plugins voice window now only ever *responds* to a Claude session that's blocked on a hook — the "type a reply into the terminal" path has been removed. Replies are always delivered in-band (the answer can never land in the wrong window), the agent selector switches between concurrently-blocked sessions, and summoning the window with nothing waiting shows the "No Claude sessions" state. Removes the now-meaningless "Submit on Send" setting. (Proactively messaging an idle session is planned to return via Claude Code channels.)
