---
"hex-app": minor
---

Simplify Coach settings now that the prompt is fully user-editable: drop the Native Language, Target Accent, Goal, and Custom Guidance settings rows along with their template placeholders. The Settings panel shows only what still matters — Provider, API key, Threshold, Auto-show, Coach Prompt, Delete-after-analysis, Feedback history. The default prompt is now self-contained (English pronunciation coach for fluent native English) with `{{TRANSCRIPT}}` as the only placeholder; any leftover `{{L1_LANGUAGE}}` / `{{TARGET_ACCENT}}` / `{{USER_GOAL}}` / `{{CUSTOM_GUIDANCE}}` markers in a user's saved template will pass through untouched. Old `hex_settings.json` files with the dropped fields decode cleanly — the removed values are silently ignored.
