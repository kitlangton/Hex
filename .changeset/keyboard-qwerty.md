---
"hex-app": minor
---

Rebuild the iOS dictation keyboard as a standard QWERTY layout with the Hex mic in the bottom-right dictation spot. Replaces the previous two-panel letter-free design: full Q-W-E-R-T-Y rows, a shift key (one-shot → caps lock), a 123 numbers layer with a #+= symbols sub-layer, and a standard bottom row (123/ABC · globe · space · return) plus a prominent blue mic in Apple's dictation corner. While capturing it dims the keys and shows a "Listening…" waveform with Cancel and a red stop button; the noFullAccess / inserting / needsBounce / error states render as a status banner above the keys, in light and dark mode. No prediction/autocorrect bar yet (a later step). The session/IPC/mic logic in KeyboardViewController is unchanged.
