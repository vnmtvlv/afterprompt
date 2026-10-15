#!/bin/sh
# AfterPrompt — a tiny game for the minutes a coding agent is busy.
# Needs nothing beyond sh, curl, and sed. Notifications use terminal-notifier
# when it is already installed, otherwise osascript (macOS) or notify-send (Linux).
#
#   afterprompt.sh hook start   UserPromptSubmit: arm a detached timer
#   afterprompt.sh hook stop    Stop / permission / SessionEnd: finish and notify
#   afterprompt.sh delayed      (internal) wait, then open or notify
#   afterprompt.sh reap <id>    (internal) quit the window's browser once it closes
#   afterprompt.sh open-url <u> (internal) open a game URL from a notification click
#   afterprompt.sh open         open a practice window right now
#   afterprompt.sh dry-run      print the resolved config; no network, no UI
#
# Hook commands accept `--agent <name>` (default: claude).
#
# AFTERPROMPT_ON_PROMPT selects what happens after AFTERPROMPT_DELAY seconds:
#   notify (default)  notification "Your agent is thinking — your move";
#                     activating it opens the game
#   open              open the game window directly (the 0.1.x behavior)
#   off               do not open or notify
#
# The timer always runs in a detached process. Codex currently parses
# `"async": true` but does not run command hooks asynchronously, so a sleep
# inside the hook would block the turn. Detaching keeps both hosts fast.
#
# Only the agent name and timestamps leave your machine. Prompts, code, and
# transcripts are never sent anywhere.

BASE=$(printf '%s' "${AFTERPROMPT_URL:-https://afterprompt.inchi.dev}" | sed 's:/*$::')
DELAY_SECONDS=${AFTERPROMPT_DELAY:-60}
case $DELAY_SECONDS in '' | *[!0-9]*) DELAY_SECONDS=60 ;; esac
MODE=${AFTERPROMPT_ON_PROMPT:-notify}
case $MODE in open | notify | off) ;; *) MODE=notify ;; esac
HOME_DIR=${AFTERPROMPT_HOME:-$HOME/.afterprompt}
RUNS=$HOME_DIR/runs
LOG=$HOME_DIR/afterprompt.log
PROFILE=$HOME_DIR/browser
WINDOW_WIDTH=420
WINDOW_HEIGHT=720
OS=${AFTERPROMPT_OS:-$(uname -s)}
SCRIPT=$0
DISABLED=0
[ "${AFTERPROMPT_DISABLE:-}" = 1 ] && DISABLED=1

# A later notification click must still find this file if the cwd changed.
case $SCRIPT in
  /*) ;;
  *)
    script_dir=$(CDPATH= cd -- "$(dirname "$SCRIPT")" 2>/dev/null && pwd)
    [ -n "$script_dir" ] && SCRIPT=$script_dir/$(basename "$SCRIPT")
    ;;
esac

COMMAND=
SUB=
POS1=
POS2=
AGENT=${AFTERPROMPT_AGENT:-claude}
while [ $# -gt 0 ]; do
  case $1 in
    --agent)
      shift
      [ $# -gt 0 ] && AGENT=$1
      [ $# -gt 0 ] && shift
      ;;
    *)
      if [ -z "$COMMAND" ]; then COMMAND=$1
      elif [ -z "$SUB" ]; then SUB=$1
      elif [ -z "$POS1" ]; then POS1=$1
      else POS2=$1
      fi
      shift
      ;;
  esac
done
# The agent name goes into a JSON body: keep it to plain letters.
case $AGENT in '' | *[!a-z0-9-]*) AGENT=claude ;; esac

log() {
  mkdir -p "$HOME_DIR" 2>/dev/null
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null
}

# Record a side effect that dry-run must not perform. Hook stdout stays empty:
# Codex treats plain text on stdout from Stop as a failed hook.
dry() {
  [ "${AFTERPROMPT_DRY_RUN:-}" = 1 ] || return 0
  mkdir -p "$HOME_DIR" 2>/dev/null
  printf '%s\n' "$*" >>"$HOME_DIR/dry-run.log" 2>/dev/null
}

applescript_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# A top-level string field from a JSON object. Hook input and API responses are
# flat objects; quotes inside string values arrive escaped, so they can't match.
json_string() {
  printf '%s' "$1" | tr '\n' ' ' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

json_number() {
  printf '%s' "$1" | tr '\n' ' ' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n 1
}

# ─── per-agent-session state ─────────────────────────────────────
# One small key=value file per agent session.

state_path() {
  printf '%s/%s.state' "$RUNS" "$(printf '%s' "${1:-default}" | tr -c 'A-Za-z0-9_-' '_' | cut -c 1-80)"
}

# state_get <file> <key>
state_get() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# state_write <file> <line>... — atomic, so a concurrent reader never sees half a file.
state_write() {
  file=$1
  shift
  mkdir -p "$RUNS"
  printf '%s\n' "$@" >"$file.$$.tmp" && mv -f "$file.$$.tmp" "$file"
}

safe_token() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_' | cut -c 1-80
}

waiter_path() {
  printf '%s.%s.waiter' "$1" "$(safe_token "$2")"
}

# Stop the detached timer for this prompt, and only if it is still our script.
stop_waiter() {
  file=$(waiter_path "$1" "$2")
  [ -f "$file" ] || return 0
  pid=$(sed -n '1s/ .*//p' "$file")
  rm -f "$file"
  case $pid in '' | *[!0-9]*) return 0 ;; esac
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case $cmd in
    *afterprompt*) ;;
    *) return 0 ;;
  esac
  # A session leader's group is only the timer and its sleep. Otherwise kill
  # just that pid so we never signal the agent or the hook runner.
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
}

clear_waiters() {
  for file in "$1".*.waiter; do
    [ -f "$file" ] || continue
    rm -f "$file"
  done
}

# Fork into its own session when we can, so the hook process can exit without
# the host's process-group teardown taking the timer with it.
detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >>"$LOG" 2>&1 &
  else
    nohup "$@" </dev/null >>"$LOG" 2>&1 &
  fi
}

# ─── API ─────────────────────────────────────────────────────────

complete_session() {
  if [ "${AFTERPROMPT_DRY_RUN:-}" = 1 ]; then
    dry "complete $1"
    return 0
  fi
  curl -fsS -m 8 -X POST -H "Authorization: Bearer $2" "$BASE/api/sessions/$1/complete" >/dev/null ||
    log "complete failed for $1"
}

finish() {
  phase=$(state_get "$1" phase)
  case $phase in
    open | notified)
      id=$(state_get "$1" session)
      token=$(state_get "$1" token)
      [ -n "$id" ] && [ -n "$token" ] && complete_session "$id" "$token"
      ;;
  esac
}

play_url_for() {
  printf '%s/goo?session=%s&popup=1' "$BASE" "$1"
}

# Our own game URLs only. Notification clicks must not become an open-URL primitive.
allowed_play_url() {
  prefix="$BASE/goo?session="
  suffix="&popup=1"
  case $1 in
    "$prefix"*"$suffix") ;;
    *) return 1 ;;
  esac
  id=${1#"$prefix"}
  id=${id%"$suffix"}
  case $id in
    s_[A-Za-z0-9_-]*) ;;
    *) return 1 ;;
  esac
  case $id in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# ─── notifications ───────────────────────────────────────────────
# Fast and non-blocking: every backend is spawned and the function returns.
# Click-to-open needs terminal-notifier (macOS) or notify-send actions (Linux).
# osascript can show a banner, but a stock display notification has no click URL.

notify_backend() {
  if command -v terminal-notifier >/dev/null 2>&1; then
    printf 'terminal-notifier'
    return
  fi
  if [ "$OS" = Darwin ]; then
    printf 'osascript'
    return
  fi
  if command -v notify-send >/dev/null 2>&1; then
    printf 'notify-send'
    return
  fi
  printf 'log'
}

# notify <message> [url]
# The actual banner is posted from a detached process so the hook can exit
# without cutting off osascript, terminal-notifier, or a notify-send action.
notify() {
  message=$1
  url=$2
  title='AfterPrompt'
  backend=$(notify_backend)
  if [ "${AFTERPROMPT_DRY_RUN:-}" = 1 ]; then
    if [ -n "$url" ] && [ "$backend" != osascript ] && [ "$backend" != log ]; then
      click=open
    else
      click=none
    fi
    dry "notify via=$backend click=$click title=$title message=$message url=${url:-}"
    return 0
  fi
  detach sh "$SCRIPT" post "$backend" "$message" "$url"
}

known_message() {
  case $1 in
    "Your agent is thinking — your move" | "Your agent is done" | "Your agent needs you") return 0 ;;
    *) return 1 ;;
  esac
}

# post <backend> <message> [url] — runs in the detached notifier process.
cmd_post() {
  backend=$1
  message=$2
  url=$3
  known_message "$message" || return 0
  if [ -n "$url" ]; then
    allowed_play_url "$url" || return 0
  fi
  case $backend in
    terminal-notifier)
      if [ -n "$url" ]; then
        terminal-notifier -title "AfterPrompt" -message "$message" -group afterprompt -open "$url" >/dev/null 2>&1 ||
          log "terminal-notifier failed"
      else
        terminal-notifier -title "AfterPrompt" -message "$message" -group afterprompt >/dev/null 2>&1 ||
          log "terminal-notifier failed"
      fi
      ;;
    osascript)
      title_esc=$(applescript_escape "AfterPrompt")
      message_esc=$(applescript_escape "$message")
      osascript -e "display notification \"$message_esc\" with title \"$title_esc\"" >/dev/null 2>&1 ||
        log "osascript notification failed"
      if [ -n "$url" ]; then
        log "notification has no click action without terminal-notifier; game URL $url"
      fi
      ;;
    notify-send)
      if [ -n "$url" ]; then
        # -A implies --wait, so this process stays up until the user acts.
        action=$(notify-send --app-name=AfterPrompt -A 'open=Your move' "AfterPrompt" "$message" 2>/dev/null) || {
          notify-send --app-name=AfterPrompt "AfterPrompt" "$message" >/dev/null 2>&1 || true
          return 0
        }
        case $action in
          open*) sh "$SCRIPT" open-url "$url" ;;
        esac
      else
        notify-send --app-name=AfterPrompt "AfterPrompt" "$message" >/dev/null 2>&1 ||
          log "notify-send failed"
      fi
      ;;
    *)
      log "notify: AfterPrompt — $message${url:+ ($url)}"
      ;;
  esac
}

# ─── window ──────────────────────────────────────────────────────

# A Chromium-family browser: they support chromeless `--app` windows.
find_browser() {
  if [ -n "${AFTERPROMPT_BROWSER:-}" ]; then
    printf '%s' "$AFTERPROMPT_BROWSER"
    return
  fi
  if [ "$OS" = Darwin ]; then
    for root in /Applications "$HOME/Applications"; do
      for app in 'Google Chrome' Chromium 'Microsoft Edge' 'Brave Browser' 'Google Chrome Canary'; do
        if [ -x "$root/$app.app/Contents/MacOS/$app" ]; then
          printf '%s' "$root/$app.app/Contents/MacOS/$app"
          return
        fi
      done
    done
    return
  fi
  for name in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser; do
    if command -v "$name" >/dev/null 2>&1; then
      command -v "$name"
      return
    fi
  done
}

# Top-right corner of the main screen, when we can find out how big it is.
# Sets WIN_X, WIN_Y, WIN_H.
window_position() {
  WIN_X=80 WIN_Y=80 WIN_H=$WINDOW_HEIGHT
  [ "$OS" = Darwin ] || return
  # NSScreen, not Finder: asking Finder would trigger an Automation prompt.
  size=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.frame; Math.round(f.size.width) + " " + Math.round(f.size.height)' 2>/dev/null) || return
  width=${size% *}
  height=${size#* }
  case "$width$height" in '' | *[!0-9]*) return ;; esac
  WIN_X=$((width - WINDOW_WIDTH - 24))
  [ "$WIN_X" -lt 0 ] && WIN_X=0
  WIN_Y=48
  WIN_H=$((height - 96))
  [ "$WIN_H" -gt "$WINDOW_HEIGHT" ] && WIN_H=$WINDOW_HEIGHT
}

# Opens the URL; sets WINDOW_KIND to `app` (chromeless window) or `tab`.
open_window() {
  if [ "${AFTERPROMPT_DRY_RUN:-}" = 1 ]; then
    WINDOW_KIND=dry
    dry "open-window $1"
    return
  fi
  browser=$(find_browser)
  if [ -n "$browser" ]; then
    window_position
    # A dedicated profile: its own process, and the game's progress lives here.
    "$browser" "--app=$1" "--user-data-dir=$PROFILE" --no-first-run --no-default-browser-check \
      "--window-size=$WINDOW_WIDTH,$WIN_H" "--window-position=$WIN_X,$WIN_Y" >/dev/null 2>&1 &
    WINDOW_KIND=app
    log "opened app window with $browser"
    return
  fi
  # No Chromium browser: a regular tab still works, it just can't be chromeless.
  if [ "$OS" = Darwin ]; then open "$1" >/dev/null 2>&1 &
  else xdg-open "$1" >/dev/null 2>&1 &
  fi
  WINDOW_KIND=tab
  log "opened default browser tab"
}

# On macOS a browser keeps running after its last window closes, leaving a
# stray Dock icon. Once the game window is gone, quit our dedicated profile.
reap_when_closed() {
  [ "$OS" = Darwin ] || return
  if [ "${AFTERPROMPT_DRY_RUN:-}" = 1 ]; then
    dry "reap $1"
    return
  fi
  deadline=$(($(date +%s) + 600))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 2
    status=$(curl -fsS -m 5 "$BASE/api/sessions/$1") || break
    [ "$(json_number "$status" viewers)" = 0 ] && break
  done
  pkill -f "user-data-dir=$PROFILE" 2>/dev/null
}

# ─── hooks ───────────────────────────────────────────────────────

create_session() {
  if [ "${AFTERPROMPT_DRY_RUN:-}" = 1 ]; then
    dry "create-session agent=$AGENT"
    CREATED_ID=s_dryrun
    CREATED_TOKEN=t_dryrun
    return 0
  fi
  response=$(curl -fsS -m 8 -X POST -H 'Content-Type: application/json' \
    -d "{\"agent\":\"$AGENT\"}" "$BASE/api/sessions") || {
    log "create session failed"
    return 1
  }
  CREATED_ID=$(json_string "$response" id)
  CREATED_TOKEN=$(json_string "$response" completionToken)
  case $CREATED_ID in s_*) ;; *) log "create session: unexpected response" && return 1 ;; esac
  return 0
}

# The delay elapsed and this prompt is still the active one.
engage() {
  state=$1
  prompt=$2
  [ "$(state_get "$state" prompt)" = "$prompt" ] && [ "$(state_get "$state" phase)" = waiting ] || return 0
  create_session || return 0
  id=$CREATED_ID
  token=$CREATED_TOKEN
  if [ "$(state_get "$state" prompt)" != "$prompt" ] || [ "$(state_get "$state" phase)" != waiting ]; then
    # The agent finished while we were creating the session: never show it.
    complete_session "$id" "$token"
    dry "discard-session $id"
    return 0
  fi
  url=$(play_url_for "$id")
  if [ "$MODE" = open ]; then
    # Record the session before the window exists, so a Stop from here on always completes it.
    state_write "$state" phase=open "prompt=$prompt" "session=$id" "token=$token" "url=$url"
    open_window "$url"
    if [ "$(state_get "$state" prompt)" = "$prompt" ]; then
      state_write "$state" phase=open "prompt=$prompt" "session=$id" "token=$token" "url=$url" "window=$WINDOW_KIND"
    fi
    return 0
  fi
  state_write "$state" phase=notified "prompt=$prompt" "session=$id" "token=$token" "url=$url"
  notify "Your agent is thinking — your move" "$url"
}

# A prompt was submitted. Record it and return immediately; the wait happens
# out of process. A Stop in the meantime removes the state file and cancels it.
hook_start() {
  input=$1
  [ "$MODE" = off ] && return 0
  state=$(state_path "$(json_string "$input" session_id)")
  # Claude Code sends prompt_id, Codex sends turn_id.
  prompt=$(json_string "$input" prompt_id)
  [ -n "$prompt" ] || prompt=$(json_string "$input" turn_id)
  [ -n "$prompt" ] || prompt=$(date +%s)-$$

  if [ -f "$state" ]; then
    old_prompt=$(state_get "$state" prompt)
    stop_waiter "$state" "$old_prompt"
    finish "$state"
    clear_waiters "$state"
  fi

  state_write "$state" phase=waiting "prompt=$prompt"
  log "prompt $prompt: waiting ${DELAY_SECONDS}s mode=$MODE"
  detach sh "$SCRIPT" delayed --agent "$AGENT" "$state" "$prompt"
}

# Detached timer started by hook_start.
cmd_delayed() {
  state=$1
  prompt=$2
  [ -n "$state" ] && [ -n "$prompt" ] || return 0
  [ -f "$state" ] || return 0
  [ "$(state_get "$state" prompt)" = "$prompt" ] && [ "$(state_get "$state" phase)" = waiting ] || return 0
  printf '%s %s\n' "$$" "$prompt" >"$(waiter_path "$state" "$prompt")"
  log "delayed $prompt: sleeping ${DELAY_SECONDS}s"
  if [ "$DELAY_SECONDS" -gt 0 ]; then
    sleep "$DELAY_SECONDS"
  fi
  rm -f "$(waiter_path "$state" "$prompt")"
  [ "$MODE" = off ] && return 0
  engage "$state" "$prompt"
}

# Browser tidy-up can poll for minutes. Dry-run records it inline; a real
# hook detaches so `claude -p` is not held open.
schedule_reap() {
  [ "$1" = open ] && [ "$2" = app ] && [ "$OS" = Darwin ] || return 0
  if [ "${AFTERPROMPT_DRY_RUN:-}" = 1 ]; then
    reap_when_closed "$3"
  else
    detach sh "$SCRIPT" reap "$3"
  fi
}

# The agent stopped (or needs the user): finish the session so the window
# closes. This hook runs synchronously so it survives `claude -p` exiting
# right after; notifications and browser tidy-up are detached.
hook_stop() {
  input=$1
  event=$(json_string "$input" hook_event_name)
  case $event in
    Notification | PermissionRequest) kind=permission ;;
    *) kind=stop ;;
  esac
  state=$(state_path "$(json_string "$input" session_id)")
  if [ ! -f "$state" ]; then
    # A permission prompt with no tracked turn still needs the user.
    if [ "$kind" = permission ] && [ "$MODE" != off ]; then
      notify "Your agent needs you" ""
    fi
    return 0
  fi
  phase=$(state_get "$state" phase)
  prompt=$(state_get "$state" prompt)
  id=$(state_get "$state" session)
  window=$(state_get "$state" window)
  stop_waiter "$state" "$prompt"
  if [ "$kind" = permission ]; then
    # Close a game that is already up so it does not cover the prompt, and
    # cancel the timer so it cannot open one. Keep a marker: the eventual
    # Stop is still "your agent is done".
    finish "$state"
    clear_waiters "$state"
    state_write "$state" phase=paused "prompt=$prompt"
    log "${event:-permission}: paused $phase session ${id:-(none)}"
    [ "$MODE" != off ] && notify "Your agent needs you" ""
    schedule_reap "$phase" "$window" "$id"
    return 0
  fi
  finish "$state"
  clear_waiters "$state"
  rm -f "$state"
  log "${event:-stop}: finished $phase session ${id:-(none)}"
  if [ "$MODE" != off ]; then
    case $phase in
      open | notified | paused)
        # Quick answers (still `waiting`) never got a game or a thinking
        # notification, so they stay quiet here too.
        notify "Your agent is done" ""
        ;;
    esac
  fi
  schedule_reap "$phase" "$window" "$id"
}

cmd_dry_run() {
  printf 'mode=%s\n' "$MODE"
  printf 'delay=%s\n' "$DELAY_SECONDS"
  printf 'os=%s\n' "$OS"
  printf 'backend=%s\n' "$(notify_backend)"
  printf 'base=%s\n' "$BASE"
  printf 'agent=%s\n' "$AGENT"
  printf 'disable=%s\n' "$DISABLED"
}

read_input() {
  [ -t 0 ] || cat
}

# dry-run stays available when the plugin is disabled, so config can be inspected.
case $COMMAND in
  dry-run)
    cmd_dry_run
    exit 0
    ;;
esac

[ "$DISABLED" = 1 ] && exit 0
mkdir -p "$HOME_DIR" 2>/dev/null

# Hooks fail silently: a broken game must never get in the agent's way.
case $COMMAND in
  hook)
    case $SUB in
      start) hook_start "$(read_input)" 2>>"$LOG" ;;
      stop | end) hook_stop "$(read_input)" 2>>"$LOG" ;;
    esac
    ;;
  delayed) cmd_delayed "$SUB" "$POS1" 2>>"$LOG" ;;
  post) cmd_post "$SUB" "$POS1" "$POS2" 2>>"$LOG" ;;
  reap) [ -n "$SUB" ] && reap_when_closed "$SUB" 2>>"$LOG" ;;
  open-url)
    if allowed_play_url "$SUB"; then
      open_window "$SUB"
    else
      log "refusing open-url"
    fi
    ;;
  open) open_window "$BASE/goo?popup=1" ;;
  *)
    printf 'Usage: afterprompt.sh hook start|stop [--agent name] | open | dry-run\n' >&2
    [ -z "$COMMAND" ] || exit 1
    ;;
esac
exit 0
