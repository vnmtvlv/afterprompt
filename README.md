# AfterPrompt for Claude Code and Codex

When your agent has been working for more than a minute, AfterPrompt tells you it is your move. The default is a notification, **Your agent is thinking — your move**. Activating it opens a small game. When the agent finishes, a second notification says **Your agent is done**, and any open game closes. Set `AFTERPROMPT_ON_PROMPT=open` to skip the notification and open the window directly, which is how 0.1.x behaved.

Quick answers stay quiet: if the agent finishes before the delay, nothing is posted and no window appears.

A permission prompt closes the game so it does not sit on top of the question, posts **Your agent needs you**, and the later stop still posts **Your agent is done**.

## Install

**Claude Code**

```
/plugin marketplace add https://afterprompt.inchi.dev/marketplace.json
/plugin install afterprompt@inchi
```

**Codex macOS app**

1. Open **Plugins** in the Codex macOS app.
2. Find **AfterPrompt** and select **Install**.
3. When the app shows that setup needs attention, select **Finish**, review the five AfterPrompt hooks, and trust them.
4. Start a new task.

During local development, open this repository in Codex, restart the app, and choose **Inchi** as the source in Plugins.

The public site [afterprompt.games](https://afterprompt.games) tells people to install `inchidev/afterprompt`. That repository is the canonical plugin (v0.1.6, server `https://afterprompt.games`). This tree is an earlier snapshot (server `https://afterprompt.inchi.dev`) with the notification behavior added on top. Installing from the website does not pick up this snapshot.

Nothing else is required: the hooks are a plain shell script using `sh`, `curl`, and `sed`. Click-to-open on macOS is better when `terminal-notifier` is already installed (`brew install terminal-notifier`). Without it, the banner still shows via `osascript`, and a click does not open the game. Linux uses `notify-send` when it is on `PATH`. Windows is not supported yet.

## How it works

| Claude Code hook | Codex hook | What happens |
| --- | --- | --- |
| `UserPromptSubmit` | `UserPromptSubmit` | Records the turn and returns immediately. The delay runs in a detached process, so the agent is not blocked. |
| after the delay, mode `notify` | after the delay, mode `notify` | Creates a session and posts **Your agent is thinking — your move**. Activating it opens `…/goo?session=…&popup=1`. |
| after the delay, mode `open` | after the delay, mode `open` | Creates a session and opens that URL as a chromeless Chrome, Edge, Brave, or Chromium `--app` window, in the top-right corner. Without a Chromium browser, it opens a normal tab. |
| `Stop` | `Stop` | If a game was offered, completes the session and posts **Your agent is done**. |
| `Notification` (`permission_prompt`) | `PermissionRequest` | Completes an open session, posts **Your agent needs you**, and remembers to say the agent is done on the later stop. |
| `SessionEnd` | `SessionEnd`, `Interrupt` | Completes any open session. Posts **Your agent is done** only if a game was already offered or a permission prompt already fired. |

`UserPromptSubmit` is marked `"async": true` for both hosts. Claude Code honors that. Codex parses `async` and still runs the command synchronously, which is why the script itself returns at once and waits in another process. Codex `Stop` must exit 0 with no stdout; plain text there is a hook failure, so notices go to the OS notification UI and the log, not to the hook's standard output.

State lives in `~/.afterprompt/`: one small file per agent session, a log, and a separate browser profile that keeps your game progress when the window is opened by the script. Your everyday browser profile is never touched. A notification click on macOS (`terminal-notifier -open`) opens the game URL in the default browser. A `notify-send` action opens it through the same window path as `open` mode.

**Privacy:** only the agent name (`claude` or `codex`) and timestamps are sent to the configured server. Prompts, code, file paths, and transcripts never leave your machine. The notification text is fixed and does not include the prompt.

## Settings

Set these environment variables, for example in the `env` block of `~/.claude/settings.json`, or in your shell profile for Codex:

| Variable | Default | Meaning |
| --- | --- | --- |
| `AFTERPROMPT_ON_PROMPT` | `notify` | `notify`, `open`, or `off` |
| `AFTERPROMPT_DELAY` | `60` | Seconds of work before the game is offered. `0` offers it immediately |
| `AFTERPROMPT_DISABLE` | — | `1` turns the plugin off without uninstalling |
| `AFTERPROMPT_BROWSER` | auto | Path to a Chromium-family browser binary |
| `AFTERPROMPT_URL` | `https://afterprompt.inchi.dev` | Game server (for local development) |
| `AFTERPROMPT_HOME` | `~/.afterprompt` | Where state, logs, and the browser profile live |

Ask Codex to “open an AfterPrompt practice game” at any time.

## Try it locally

Print the resolved config. This does not sleep, notify, or use the network:

```bash
sh plugins/afterprompt/scripts/afterprompt.sh dry-run
AFTERPROMPT_ON_PROMPT=open AFTERPROMPT_DELAY=0 sh plugins/afterprompt/scripts/afterprompt.sh dry-run
```

Run the tests:

```bash
sh plugins/afterprompt/scripts/test-afterprompt.sh
```

Offer the game on the next real turn as a notification after five seconds, or open the window directly:

```bash
export AFTERPROMPT_ON_PROMPT=notify   # or open, or off
export AFTERPROMPT_DELAY=5
```

Point `AFTERPROMPT_URL` at a local server if you are not using the hosted one. `AFTERPROMPT_DRY_RUN=1` records what a turn would do under `~/.afterprompt/dry-run.log` and skips `curl` and the real notification.

## Codex

Codex has the same command hooks as Claude Code, in `hooks/codex.json`: `UserPromptSubmit`, `Stop`, `PermissionRequest`, `Interrupt`, and `SessionEnd`. There is no Claude-style `Notification` event. `PermissionRequest` is the permission path, and it runs for every approval rather than a `permission_prompt` matcher.

Codex also has a legacy `notify` command in the user `~/.codex/config.toml`. It only runs for `agent-turn-complete`, plugins cannot set it (project config ignores `notify`), and it is not a click-to-open game hook. This plugin does not use it. `tui.notifications` can beep for turn completion and approval requests; it cannot open the game.

What Codex does not provide, and this script works around or leaves missing:

- Asynchronous command hooks. `async: true` is parsed and ignored, so a hook that slept would block the turn. The timer is detached with `setsid` (or `nohup` where `setsid` is absent).
- A notification API with a click action. The hook posts a banner by executing `terminal-notifier`, `osascript`, or `notify-send`.
- A guarantee that a GUI notification launched from the Codex macOS app is allowed. The CLI path is the one these hooks are written for. After this script changes, Codex asks you to review and trust the hooks again because the trust check is on the hook definition's hash.

A future menu-bar app is sketched in the pull request, not built here.
