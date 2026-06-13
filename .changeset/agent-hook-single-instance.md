---
"hex-app": patch
---

Fix the Agent Plugins hook launching extra Hex instances when multiple Claude terminals are open. The hook now delivers its deeplink to the specific Hex that installed it (by bundle id, then exact app path) instead of letting the `hex://` URL scheme pick any registered Hex, so every terminal talks to one window and the request queue coalesces. Existing installs self-heal: the hook script is rewritten on launch when out of date.
