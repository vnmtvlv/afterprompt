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

- `AFTERPROMPT_ON_PROMPT`: what happens after the delay. `notify` (default) posts "Your agent is thinking — your move" and opens the game when that notification is activated. `open` opens the game window directly. `off` does neither.
- `AFTERPROMPT_DELAY`: seconds before that happens; defaults to `60`. `0` means immediately. Quick turns that finish first stay quiet.
- `AFTERPROMPT_DISABLE=1`: disables the lifecycle behavior, including stop and permission notifications.
- `AFTERPROMPT_BROWSER`: overrides the Chromium-family browser executable.
- `AFTERPROMPT_URL`: overrides the game server URL.
- `AFTERPROMPT_HOME`: overrides local state, log, and browser-profile storage.

`sh "${PLUGIN_ROOT}/scripts/afterprompt.sh" dry-run` prints the resolved mode, delay, OS, notification backend, and server. It does not sleep, notify, or use the network.

On Stop, after a game was offered, the plugin posts "Your agent is done" and completes the server session. A Claude `Notification` (`permission_prompt`) or Codex `PermissionRequest` posts "Your agent needs you", closes any open game, and leaves the later Stop to say the agent is done.

The plugin sends only the agent name and timestamps to the configured server. It does not send prompts, source code, file paths, or transcripts. Notification text is fixed; the prompt is not included.

Click-to-open on macOS uses `terminal-notifier` when it is already installed (`brew install terminal-notifier`). Without it, `osascript` shows the banner and a click does not open the game. Linux uses `notify-send` actions when that command exists.
