#!/bin/sh
# Behavior tests for afterprompt.sh. No network and no real notifications.
#   sh plugins/afterprompt/scripts/test-afterprompt.sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
SCRIPT=$ROOT/plugins/afterprompt/scripts/afterprompt.sh
WORK=$(mktemp -d)
FAIL=0
PASS=0

cleanup() {
  find "$WORK" -name '*.waiter' 2>/dev/null | while read -r file; do
    pid=$(sed -n '1s/ .*//p' "$file")
    case $pid in '' | *[!0-9]*) continue ;; esac
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
      kill -TERM -"$pid" 2>/dev/null || true
    else
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

BIN=$WORK/bin
mkdir -p "$BIN"
CURL_LOG=$WORK/curl.log
cat >"$BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${CURL_LOG:?}"
exit 99
EOF
chmod +x "$BIN/curl"

ok() {
  PASS=$((PASS + 1))
  printf 'ok %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1" >&2
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    bad "$3"
    printf '  expected: %s\n  actual:   %s\n' "$2" "$1" >&2
  fi
}

assert_contains() {
  if printf '%s' "$1" | grep -F -q -- "$2"; then
    ok "$3"
  else
    bad "$3"
    printf '  missing: %s\n  in: %s\n' "$2" "$1" >&2
  fi
}

assert_not_contains() {
  if printf '%s' "$1" | grep -F -q -- "$2"; then
    bad "$3"
    printf '  unexpected: %s\n  in: %s\n' "$2" "$1" >&2
  else
    ok "$3"
  fi
}

new_home() {
  HOME_DIR=$(mktemp -d "$WORK/home.XXXXXX")
  export AFTERPROMPT_HOME=$HOME_DIR
  export AFTERPROMPT_DRY_RUN=1
  export AFTERPROMPT_URL=https://afterprompt.test
  export AFTERPROMPT_OS=Linux
  export AFTERPROMPT_DELAY=0
  export AFTERPROMPT_ON_PROMPT=notify
  unset AFTERPROMPT_DISABLE
  unset AFTERPROMPT_AGENT
  export CURL_LOG
  export PATH="$BIN:$PATH"
}

log_text() {
  if [ -f "$HOME_DIR/dry-run.log" ]; then
    cat "$HOME_DIR/dry-run.log"
  fi
}

state_file() {
  printf '%s/runs/%s.state' "$HOME_DIR" "$1"
}

# ─── config ──────────────────────────────────────────────────────

new_home
cfg=$(AFTERPROMPT_ON_PROMPT=popup AFTERPROMPT_DELAY=abc sh "$SCRIPT" dry-run --agent 'Bad Agent')
assert_contains "$cfg" "mode=notify" "invalid mode falls back to notify"
assert_contains "$cfg" "delay=60" "invalid delay falls back to 60"
assert_contains "$cfg" "agent=claude" "unsafe agent name falls back to claude"
assert_contains "$cfg" "base=https://afterprompt.test" "dry-run reports the base URL"
assert_contains "$cfg" "disable=0" "dry-run reports disable off"

cfg=$(AFTERPROMPT_DISABLE=1 AFTERPROMPT_ON_PROMPT=open sh "$SCRIPT" dry-run)
assert_contains "$cfg" "disable=1" "dry-run still prints when disabled"
assert_contains "$cfg" "mode=open" "dry-run reports open mode"

out=$(AFTERPROMPT_DISABLE=1 sh "$SCRIPT" hook start </dev/null)
status=$?
assert_eq "$status" 0 "disabled hook exits 0"
assert_eq "$out" "" "disabled hook prints nothing"
if [ -d "$HOME_DIR/runs" ]; then
  bad "disabled hook writes no state"
else
  ok "disabled hook writes no state"
fi

# ─── notify backend selection ────────────────────────────────────

new_home
cfg=$(AFTERPROMPT_OS=Darwin PATH="$BIN:/usr/bin:/bin" sh "$SCRIPT" dry-run)
assert_contains "$cfg" "backend=osascript" "darwin without terminal-notifier uses osascript"

mkdir -p "$WORK/tn"
cat >"$WORK/tn/terminal-notifier" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NOTIFY_LOG:?}"
exit 0
EOF
chmod +x "$WORK/tn/terminal-notifier"
cfg=$(AFTERPROMPT_OS=Darwin PATH="$WORK/tn:$BIN:/usr/bin:/bin" sh "$SCRIPT" dry-run)
assert_contains "$cfg" "backend=terminal-notifier" "terminal-notifier wins when installed"

cfg=$(AFTERPROMPT_OS=Linux PATH="$BIN:/usr/bin:/bin" sh "$SCRIPT" dry-run)
# This environment may or may not have notify-send. Assert the two legal results.
case $cfg in
  *backend=notify-send* | *backend=log*) ok "linux backend is notify-send or log" ;;
  *) bad "linux backend is notify-send or log" ;;
esac

# ─── prompt submit is fast and does not send the prompt ─────────

new_home
export AFTERPROMPT_DELAY=30
export AFTERPROMPT_ON_PROMPT=notify
started=$(date +%s)
out=$(printf '%s' '{"session_id":"sess-1","prompt_id":"pr-1","hook_event_name":"UserPromptSubmit","prompt":"SECRET-PROMPT-BODY"}' | timeout 5 sh "$SCRIPT" hook start --agent codex)
status=$?
elapsed=$(($(date +%s) - started))
assert_eq "$status" 0 "hook start exits 0"
assert_eq "$out" "" "hook start stdout stays empty"
if [ "$elapsed" -lt 3 ]; then
  ok "hook start returns without sleeping the delay"
else
  bad "hook start returns without sleeping the delay (elapsed ${elapsed}s)"
fi

waiter=$(state_file sess-1).pr-1.waiter
i=0
while [ ! -f "$waiter" ] && [ "$i" -lt 30 ]; do
  i=$((i + 1))
  sleep 0.1
done
timer_pid=
if [ -f "$waiter" ]; then
  ok "detached timer records its pid"
  timer_pid=$(sed -n '1s/ .*//p' "$waiter")
else
  bad "detached timer records its pid"
fi

state=$(cat "$(state_file sess-1)" 2>/dev/null || true)
assert_contains "$state" "phase=waiting" "start records a waiting turn"
assert_contains "$state" "prompt=pr-1" "start records the prompt id"
assert_not_contains "$state" "SECRET-PROMPT-BODY" "state does not store the prompt text"
assert_not_contains "$(log_text)" "SECRET-PROMPT-BODY" "dry-run log does not store the prompt text"

out=$(printf '%s' '{"session_id":"sess-1","hook_event_name":"Stop"}' | sh "$SCRIPT" hook stop)
assert_eq "$out" "" "quick stop stdout stays empty"
assert_not_contains "$(log_text)" "Your agent is done" "quick stop does not notify"
assert_not_contains "$(log_text)" "Your agent is thinking" "quick stop does not open a game"
if [ -f "$(state_file sess-1)" ]; then
  bad "quick stop removes the state file"
else
  ok "quick stop removes the state file"
fi
if [ -n "$timer_pid" ]; then
  i=0
  while ps -p "$timer_pid" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
    i=$((i + 1))
    sleep 0.1
  done
  if ps -p "$timer_pid" >/dev/null 2>&1; then
    bad "quick stop kills the detached timer"
  else
    ok "quick stop kills the detached timer"
  fi
fi
if [ -n "${CURL_LOG}" ] && [ -s "$CURL_LOG" ]; then
  bad "dry-run does not call curl"
else
  ok "dry-run does not call curl"
fi

# ─── notify mode after the delay ─────────────────────────────────

new_home
export AFTERPROMPT_DELAY=0
export AFTERPROMPT_ON_PROMPT=notify
mkdir -p "$HOME_DIR/runs"
printf '%s\n' 'phase=waiting' 'prompt=p9' >"$(state_file abc)"
sh "$SCRIPT" delayed --agent codex "$(state_file abc)" p9
text=$(log_text)
assert_contains "$text" "create-session agent=codex" "notify mode creates a codex session"
assert_contains "$text" "message=Your agent is thinking — your move" "thinking notification copy"
assert_contains "$text" "url=https://afterprompt.test/goo?session=s_dryrun&popup=1" "thinking notification carries the game URL"
assert_not_contains "$text" "open-window " "notify mode does not open a window by itself"
phase=$(sed -n 's/^phase=//p' "$(state_file abc)")
assert_eq "$phase" "notified" "notify mode records phase=notified"

# If notify-send is absent the click flag is none. Accept either, but a URL
# with a click-capable backend must say click=open.
if printf '%s' "$text" | grep -q 'via=osascript\|via=log'; then
  assert_contains "$text" "click=none" "osascript and log cannot open on click"
else
  assert_contains "$text" "click=open" "terminal-notifier and notify-send open on click"
fi

out=$(printf '%s' '{"session_id":"abc","hook_event_name":"Stop"}' | sh "$SCRIPT" hook stop)
assert_eq "$out" "" "stop stdout stays empty for codex"
text=$(log_text)
assert_contains "$text" "complete s_dryrun" "stop completes the session"
assert_contains "$text" "message=Your agent is done" "stop notification copy"
# The thinking line also contains a URL. Require the done line specifically.
if printf '%s\n' "$text" | grep -F 'message=Your agent is done' | grep -F 'url=' | grep -v 'goo?session' >/dev/null; then
  ok "done notification URL is empty"
else
  bad "done notification URL is empty"
fi
if [ -f "$(state_file abc)" ]; then
  bad "stop removes notified state"
else
  ok "stop removes notified state"
fi

# ─── open mode ───────────────────────────────────────────────────

new_home
export AFTERPROMPT_DELAY=0
export AFTERPROMPT_ON_PROMPT=open
mkdir -p "$HOME_DIR/runs"
printf '%s\n' 'phase=waiting' 'prompt=po' >"$(state_file open1)"
sh "$SCRIPT" delayed --agent claude "$(state_file open1)" po
text=$(log_text)
assert_contains "$text" "open-window https://afterprompt.test/goo?session=s_dryrun&popup=1" "open mode opens the game window"
assert_not_contains "$text" "Your agent is thinking" "open mode does not also post the thinking notification"
assert_eq "$(sed -n 's/^phase=//p' "$(state_file open1)")" "open" "open mode records phase=open"
assert_eq "$(sed -n 's/^window=//p' "$(state_file open1)")" "dry" "dry-run window kind is dry"

# ─── permission prompts ──────────────────────────────────────────

new_home
export AFTERPROMPT_DELAY=30
mkdir -p "$HOME_DIR/runs"
printf '%s\n' 'phase=waiting' 'prompt=pw' >"$(state_file perm)"
# A live waiter is optional; permission must still notify.
printf '%s' '{"session_id":"perm","hook_event_name":"Notification"}' | sh "$SCRIPT" hook stop >/dev/null
text=$(log_text)
assert_contains "$text" "message=Your agent needs you" "permission notification copy"
assert_not_contains "$text" "Your agent is done" "permission is not the done notification"
assert_eq "$(sed -n 's/^phase=//p' "$(state_file perm)")" "paused" "permission pauses the turn"

printf '%s' '{"session_id":"perm","hook_event_name":"Stop"}' | sh "$SCRIPT" hook stop >/dev/null
text=$(log_text)
assert_contains "$text" "message=Your agent is done" "stop after permission says the agent is done"
if [ -f "$(state_file perm)" ]; then
  bad "stop after permission clears state"
else
  ok "stop after permission clears state"
fi

new_home
mkdir -p "$HOME_DIR/runs"
printf '%s\n' 'phase=notified' 'prompt=pn' 'session=s_dryrun' 'token=t_dryrun' >"$(state_file played)"
printf '%s' '{"session_id":"played","hook_event_name":"PermissionRequest"}' | sh "$SCRIPT" hook stop >/dev/null
text=$(log_text)
assert_contains "$text" "complete s_dryrun" "permission completes an open session"
assert_contains "$text" "message=Your agent needs you" "codex permission uses the same copy"
assert_not_contains "$text" "Your agent is done" "codex permission does not also say done"
assert_eq "$(sed -n 's/^phase=//p' "$(state_file played)")" "paused" "codex permission pauses"

# ─── mode off, pretty JSON, previous session, reap, open-url ────

new_home
export AFTERPROMPT_ON_PROMPT=off
printf '%s' '{"session_id":"off1","prompt_id":"x"}' | sh "$SCRIPT" hook start >/dev/null
if [ -f "$(state_file off1)" ]; then
  bad "mode off does not arm a turn"
else
  ok "mode off does not arm a turn"
fi

new_home
export AFTERPROMPT_DELAY=30
pretty='{
  "session_id": "pretty",
  "prompt_id": "pp1",
  "hook_event_name": "UserPromptSubmit"
}'
printf '%s' "$pretty" | sh "$SCRIPT" hook start >/dev/null
assert_contains "$(cat "$(state_file pretty)" 2>/dev/null || true)" "prompt=pp1" "pretty-printed hook JSON is accepted"
printf '%s' '{"session_id":"pretty","hook_event_name":"SessionEnd"}' | sh "$SCRIPT" hook stop >/dev/null
assert_not_contains "$(log_text)" "Your agent is done" "session end during the delay stays quiet"

new_home
export AFTERPROMPT_DELAY=30
mkdir -p "$HOME_DIR/runs"
printf '%s\n' 'phase=notified' 'prompt=old' 'session=s_dryrun' 'token=t_dryrun' >"$(state_file again)"
printf '%s' '{"session_id":"again","prompt_id":"new"}' | sh "$SCRIPT" hook start >/dev/null
assert_contains "$(log_text)" "complete s_dryrun" "a new prompt completes the previous session"
assert_contains "$(cat "$(state_file again)")" "prompt=new" "a new prompt replaces the state"
assert_contains "$(cat "$(state_file again)")" "phase=waiting" "a new prompt waits again"

new_home
export AFTERPROMPT_OS=Darwin
mkdir -p "$HOME_DIR/runs"
printf '%s\n' 'phase=open' 'prompt=rw' 'session=s_dryrun' 'token=t_dryrun' 'window=app' >"$(state_file reap1)"
printf '%s' '{"session_id":"reap1","hook_event_name":"Stop"}' | sh "$SCRIPT" hook stop >/dev/null
assert_contains "$(log_text)" "reap s_dryrun" "darwin app window schedules a reap"
assert_contains "$(log_text)" "message=Your agent is done" "open-mode stop still notifies"

new_home
sh "$SCRIPT" open >/dev/null
assert_contains "$(log_text)" "open-window https://afterprompt.test/goo?popup=1" "practice open uses the popup URL"

good=$HOME_DIR/ok.url
sh "$SCRIPT" open-url "https://afterprompt.test/goo?session=s_abc&popup=1" >/dev/null
assert_contains "$(log_text)" "open-window https://afterprompt.test/goo?session=s_abc&popup=1" "open-url accepts our game URL"
: >"$HOME_DIR/dry-run.log"
sh "$SCRIPT" open-url "https://evil.test/goo?session=s_abc&popup=1" >/dev/null
assert_not_contains "$(log_text)" "open-window" "open-url refuses a foreign host"
sh "$SCRIPT" open-url "https://afterprompt.test/goo?session=s_abc&popup=1&next=https://evil.test" >/dev/null
assert_not_contains "$(log_text)" "open-window" "open-url refuses an extra query"

# ─── real post path, still with fakes ────────────────────────────

new_home
unset AFTERPROMPT_DRY_RUN
NOTIFY_LOG=$WORK/notifier.log
: >"$NOTIFY_LOG"
export NOTIFY_LOG
export PATH="$WORK/tn:$BIN:/usr/bin:/bin"
sh "$SCRIPT" post terminal-notifier "Your agent is done" >/dev/null
assert_contains "$(cat "$NOTIFY_LOG")" "-message Your agent is done" "post invokes terminal-notifier"
assert_not_contains "$(cat "$NOTIFY_LOG")" "-open" "done notification does not open a URL"
: >"$NOTIFY_LOG"
sh "$SCRIPT" post terminal-notifier "not a real message" "https://afterprompt.test/goo?session=s_x&popup=1" >/dev/null
if [ -s "$NOTIFY_LOG" ]; then
  bad "post refuses an unknown message"
else
  ok "post refuses an unknown message"
fi
sh "$SCRIPT" post terminal-notifier "Your agent is thinking — your move" "https://evil.test/goo?session=s_x&popup=1" >/dev/null
if [ -s "$NOTIFY_LOG" ]; then
  bad "post refuses a foreign click URL"
else
  ok "post refuses a foreign click URL"
fi
sh "$SCRIPT" post terminal-notifier "Your agent is thinking — your move" "https://afterprompt.test/goo?session=s_x&popup=1" >/dev/null
assert_contains "$(cat "$NOTIFY_LOG")" "-open https://afterprompt.test/goo?session=s_x&popup=1" "post passes the game URL to terminal-notifier"

cat >"$BIN/osascript" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NOTIFY_LOG:?}"
exit 0
EOF
chmod +x "$BIN/osascript"
: >"$NOTIFY_LOG"
export PATH="$BIN:/usr/bin:/bin"
sh "$SCRIPT" post osascript "Your agent needs you" >/dev/null
assert_contains "$(cat "$NOTIFY_LOG")" 'display notification "Your agent needs you" with title "AfterPrompt"' "osascript posts the banner"

# notify-send click falls through to open-url. Put the fake ahead of a real one.
cat >"$BIN/notify-send" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NOTIFY_LOG:?}"
if [ "${NOTIFY_ACTION:-ok}" = fail ]; then
  exit 1
fi
printf '%s\n' "${NOTIFY_ACTION:-}"
exit 0
EOF
chmod +x "$BIN/notify-send"
export AFTERPROMPT_DRY_RUN=1
export PATH="$BIN:/usr/bin:/bin"
: >"$NOTIFY_LOG"
: >"$HOME_DIR/dry-run.log"
export NOTIFY_ACTION=open
sh "$SCRIPT" post notify-send "Your agent is thinking — your move" "https://afterprompt.test/goo?session=s_click&popup=1" >/dev/null
assert_contains "$(log_text)" "open-window https://afterprompt.test/goo?session=s_click&popup=1" "notify-send action opens the game URL"
: >"$HOME_DIR/dry-run.log"
export NOTIFY_ACTION=fail
sh "$SCRIPT" post notify-send "Your agent is done" >/dev/null
assert_not_contains "$(log_text)" "open-window" "failed notify-send action does not open a URL"

export AFTERPROMPT_DRY_RUN=1
status=0
sh "$SCRIPT" not-a-command >/dev/null 2>&1 || status=$?
assert_eq "$status" 1 "unknown command exits 1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
