#!/bin/sh
# AfterPrompt — opens a tiny game window when your coding agent takes a while,
# and closes it when the agent is done. Needs nothing beyond what macOS and
# Linux ship with: sh, curl, sed.
#
#   afterprompt.sh hook start   UserPromptSubmit: wait, then open the game window
#   afterprompt.sh hook stop    Stop / permission prompt / SessionEnd: finish the session
#   afterprompt.sh reap <id>    (internal) quit the window's browser once the game page closes
#   afterprompt.sh open         open a practice window right now
#
# Hook commands accept `--agent <name>` (default: claude).
#
# Only the agent name and timestamps leave your machine. Prompts, code, and
# transcripts are never sent anywhere.

BASE=$(printf '%s' "${AFTERPROMPT_URL:-https://afterprompt.inchi.dev}" | sed 's:/*$::')
DELAY_SECONDS=${AFTERPROMPT_DELAY:-60}
case $DELAY_SECONDS in '' | *[!0-9]*) DELAY_SECONDS=60 ;; esac
HOME_DIR=${AFTERPROMPT_HOME:-$HOME/.afterprompt}
RUNS=$HOME_DIR/runs
LOG=$HOME_DIR/afterprompt.log
PROFILE=$HOME_DIR/browser
WINDOW_WIDTH=420
WINDOW_HEIGHT=720
OS=$(uname -s)
SCRIPT=$0

COMMAND=${1:-}
SUB=${2:-}
AGENT=${AFTERPROMPT_AGENT:-claude}
while [ $# -gt 0 ]; do
  if [ "$1" = --agent ] && [ $# -gt 1 ]; then AGENT=$2; fi
  shift
done
# The agent name goes into a JSON body: keep it to plain letters.
case $AGENT in '' | *[!a-z0-9-]*) AGENT=claude ;; esac

log() {
  mkdir -p "$HOME_DIR" 2>/dev/null
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null
}

# A top-level string field from a JSON object. Hook input and API responses are
# flat objects; quotes inside string values arrive escaped, so they can't match.
json_string() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

json_number() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n 1
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

# ─── API ─────────────────────────────────────────────────────────

complete_session() {
  curl -fsS -m 8 -X POST -H "Authorization: Bearer $2" "$BASE/api/sessions/$1/complete" >/dev/null ||
    log "complete failed for $1"
}

finish() {
  if [ "$(state_get "$1" phase)" = open ]; then
    id=$(state_get "$1" session)
    token=$(state_get "$1" token)
    [ -n "$id" ] && [ -n "$token" ] && complete_session "$id" "$token"
  fi
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
  deadline=$(($(date +%s) + 600))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 2
    status=$(curl -fsS -m 5 "$BASE/api/sessions/$1") || break
    [ "$(json_number "$status" viewers)" = 0 ] && break
  done
  pkill -f "user-data-dir=$PROFILE" 2>/dev/null
}

# ─── hooks ───────────────────────────────────────────────────────

# A prompt was submitted. Wait; if the agent is still busy afterwards, open
# the game. A Stop in the meantime removes the state file and cancels this.
hook_start() {
  input=$1
  state=$(state_path "$(json_string "$input" session_id)")
  # Claude Code sends prompt_id, Codex sends turn_id.
  prompt=$(json_string "$input" prompt_id)
  [ -n "$prompt" ] || prompt=$(json_string "$input" turn_id)
  [ -n "$prompt" ] || prompt=$(date +%s)-$$

  # A previous turn that never reported Stop (e.g. interrupted): wrap it up.
  [ -f "$state" ] && finish "$state"

  state_write "$state" phase=waiting "prompt=$prompt"
  log "prompt $prompt: waiting ${DELAY_SECONDS}s"
  sleep "$DELAY_SECONDS"

  [ "$(state_get "$state" prompt)" = "$prompt" ] && [ "$(state_get "$state" phase)" = waiting ] || return

  response=$(curl -fsS -m 8 -X POST -H 'Content-Type: application/json' \
    -d "{\"agent\":\"$AGENT\"}" "$BASE/api/sessions") || {
    log "create session failed"
    return
  }
  id=$(json_string "$response" id)
  token=$(json_string "$response" completionToken)
  case $id in s_*) ;; *) log "create session: unexpected response" && return ;; esac

  if [ "$(state_get "$state" prompt)" != "$prompt" ]; then
    # The agent finished while we were creating the session: never show it.
    complete_session "$id" "$token"
    return
  fi
  # Record the session before the window exists, so a Stop from here on always completes it.
  state_write "$state" phase=open "prompt=$prompt" "session=$id" "token=$token"
  open_window "$BASE/goo?session=$id&popup=1"
  [ "$(state_get "$state" prompt)" = "$prompt" ] &&
    state_write "$state" phase=open "prompt=$prompt" "session=$id" "token=$token" "window=$WINDOW_KIND"
}

# The agent stopped (or needs the user): finish the session so the window
# closes. This hook runs synchronously so it survives `claude -p` exiting
# right after; the slow tidy-up is handed to a detached process.
hook_stop() {
  input=$1
  state=$(state_path "$(json_string "$input" session_id)")
  [ -f "$state" ] || return
  phase=$(state_get "$state" phase)
  id=$(state_get "$state" session)
  window=$(state_get "$state" window)
  finish "$state"
  rm -f "$state"
  event=$(json_string "$input" hook_event_name)
  log "${event:-stop}: finished $phase session ${id:-(none)}"
  if [ "$phase" = open ] && [ "$window" = app ] && [ "$OS" = Darwin ]; then
    nohup sh "$SCRIPT" reap "$id" >/dev/null 2>&1 &
  fi
}

read_input() {
  [ -t 0 ] || cat
}

[ "${AFTERPROMPT_DISABLE:-}" = 1 ] && exit 0
mkdir -p "$HOME_DIR" 2>/dev/null

# Hooks fail silently: a broken game must never get in the agent's way.
case "$COMMAND $SUB" in
  'hook start') hook_start "$(read_input)" 2>>"$LOG" ;;
  'hook stop' | 'hook end') hook_stop "$(read_input)" 2>>"$LOG" ;;
  reap\ ?*) reap_when_closed "$SUB" 2>>"$LOG" ;;
  'open '*) open_window "$BASE/goo?popup=1" ;;
  *)
    printf 'Usage: afterprompt.sh hook start|stop [--agent name] | open\n' >&2
    [ -z "$COMMAND" ] || exit 1
    ;;
esac
exit 0
