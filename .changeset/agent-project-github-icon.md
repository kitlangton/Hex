---
"hex-app": patch
---

Show the project's GitHub owner avatar in the Agent Plugins voice window header instead of a generic folder icon. Hex reads the repo's `origin` remote, derives the owner/org, and loads its avatar from github.com (cached). The folder icon remains as the fallback while the avatar loads, when the project has no GitHub remote, or if the fetch fails.
