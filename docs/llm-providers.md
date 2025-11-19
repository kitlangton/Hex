# LLM Provider Abstraction

Hex now routes text transformations through a provider abstraction so Claude CLI, Ollama, and future engines share a common pipeline.

## Provider Types

| Type          | Description                                 | Tool Support |
| ------------- | ------------------------------------------- | ------------ |
| `claude_code` | Claude Desktop CLI (`claude` binary)        | Yes          |
| `ollama`      | Local Ollama runtime (via `ollama run …`)   | Text-only    |

All providers are defined under the `providers` array inside `text_transformations.json`. Each entry can optionally set a `displayName` for the Settings UI.

### Placeholder Provider ID

Set `"providerID": "hex-preferred-provider"` inside a transformation to defer to the user's choice in Settings → LLM Providers. When unset, Hex falls back to the first provider in the configuration.

## Tooling Policy

1. Set `tooling.enabledToolGroups` at the provider level when the backing model reliably follows the MCP protocol. Claude CLI is the only provider shipping in tool-enabled mode by default.
2. Transformation-level `tooling` overrides provider defaults, but Hex automatically disables MCP when a provider reports `supportsToolCalling = false` or `toolReliability = none` (e.g., Ollama models).
3. Text-only providers still run prompts but skip Hex's MCP server entirely, preventing confusing tool prompts for local models without function-calling support.

## Ollama Setup

1. Install Ollama from [ollama.com/download](https://ollama.com/download) or via Homebrew (`brew install ollama`).
2. Pull the desired model (e.g., `ollama pull llama3.1:8b`).
3. Add a provider entry similar to:
   ```json
   {
     "id": "provider-ollama",
     "displayName": "Local Ollama",
     "type": "ollama",
     "binaryPath": "/usr/local/bin/ollama",
     "defaultModel": "llama3.1:8b",
     "timeoutSeconds": 45
   }
   ```
4. Reference `provider-ollama` in `.llm` transformations that only need text cleanup. MCP tooling instructions are ignored automatically.

## Settings Surface

Settings → “LLM Providers” lists every provider defined in `text_transformations.json`, shows whether it supports tools, and lets users choose a preferred provider/model. Transformations that use `hex-preferred-provider` respect this selection.

Use the “Open Config File” button to jump directly to `~/Library/Application Support/Hex/text_transformations.json` when deeper edits are needed.
