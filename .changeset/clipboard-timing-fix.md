---
"hex-app": patch
---

Fix clipboard restore timing for slow apps – increased delay from 100ms to 500ms to prevent paste failures in apps that read clipboard asynchronously (e.g., Claude, Warp)

