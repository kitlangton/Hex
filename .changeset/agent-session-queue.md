---
"hex-app": minor
---

Queue multiple blocked Claude sessions in the Agent voice window instead of dropping all but the newest. Each waiting session gets its own card (one per project) with its own draft reply, the card header shows the project and host app plus an `n / N` position when several are waiting, concurrent sessions are read aloud in distinct voices, and quitting Hex now releases every blocked hook so no session hangs on its timeout.
