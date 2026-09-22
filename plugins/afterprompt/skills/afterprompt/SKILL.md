---
name: afterprompt
description: Open an AfterPrompt practice game or explain how the installed AfterPrompt plugin behaves and is configured.
---

# AfterPrompt

Use the bundled script only when the user explicitly asks to open a practice game:

```bash
sh "${PLUGIN_ROOT}/scripts/afterprompt.sh" open
```

For configuration questions, explain these environment variables without changing them unless the user asks:

- `AFTERPROMPT_DELAY`: seconds before the game opens; defaults to `60`.
- `AFTERPROMPT_DISABLE=1`: disables the lifecycle behavior.
- `AFTERPROMPT_BROWSER`: overrides the Chromium-family browser executable.
- `AFTERPROMPT_URL`: overrides the game server URL.
- `AFTERPROMPT_HOME`: overrides local state, log, and browser-profile storage.

The plugin sends only the agent name and timestamps to `afterprompt.inchi.dev`. It does not send prompts, source code, file paths, or transcripts.
