#!/bin/bash
# account-relay: move Claude Desktop to another signed-in profile folder when an
# account runs out, then reopen the sessions the switch cut off.
#
# Never reads, copies or prints a token. Each account stays signed in to its own
# --user-data-dir folder, and that folder's app refreshes its own login.
#
#   relay.sh launch --from <accountUuid> [--resets-at <iso>]   start a switch under launchd (returns at once)
#   relay.sh switch --from <accountUuid> [--resets-at <iso>]   do the switch (what launchd runs)
#   relay.sh plan   --from <accountUuid>                       print what a switch would do, change nothing
#   relay.sh status                                            accounts, cooldowns, running instance
#   relay.sh relaunch <name> [--resume <sessionId>]            restart that account in its own app now (what relaunch-later runs)
#   relay.sh relaunch-later <name> [--resume <sessionId>]      the same under launchd, so it survives the app quitting
#   relay.sh resume                                            reopen held sessions (exactly one Claude window open)

set -u
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DIR="$HOME/.claude/account-relay"
ACCOUNTS="$DIR/accounts.json"
STATE="$DIR/state.json"
HANDOFF="$DIR/handoff.json"
LOG="$DIR/relay.log"
LOCK="$DIR/switch.lock"
APP="/Applications/Claude.app"
BIN="$APP/Contents/MacOS/Claude"
LABEL="com.jun.account-relay"
DEFAULT_DIR="$HOME/Library/Application Support/Claude"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"Claude account relay\"" >/dev/null 2>&1 || true; }
die() { log "ERROR $*"; notify "$*"; exit 1; }

expand() { local p="$1"; printf '%s' "${p/#\~/$HOME}"; }

# Each account can open with its own copy of the app (accounts.json "app"; default the real one),
# for example a copy with a different Dock icon. Every such app's main binary counts as a Claude window.
BINS=("$BIN")
while read -r a; do [ -n "$a" ] && BINS+=("$(expand "$a")/Contents/MacOS/Claude"); done < <(jq -r '.accounts[].app // empty' "$ACCOUNTS" 2>/dev/null)
is_main() {
  [[ "$1" == *"--type="* ]] && return 1
  local b; for b in "${BINS[@]}"; do [[ "$1" == "$b" || "$1" == "$b "* ]] && return 0; done; return 1
}
app_for_dir() {
  local a; a=$(jq -r --arg d "$1" --arg h "$HOME" '.accounts[] | select((.userDataDir | sub("^~"; $h)) == $d) | .app // empty' "$ACCOUNTS")
  expand "${a:-$APP}"
}
[ -f "$STATE" ] || echo '{"cooldowns":{},"switches":[]}' > "$STATE"
[ -f "$HANDOFF" ] || echo '{"resume":[]}' > "$HANDOFF"

# Write JSON atomically so a reader never sees half a file.
jq_write() { local file="$1"; shift; local tmp="$file.tmp.$$"; jq "$@" "$file" > "$tmp" && mv "$tmp" "$file"; }

account_field() { jq -r --arg u "$1" --arg f "$2" '.accounts[] | select(.accountUuid == $u) | .[$f] // empty' "$ACCOUNTS"; }

# The main Claude process for a profile folder. The default folder is the one
# launched without --user-data-dir.
instance_pid() {
  local want="$1" pid args
  while read -r pid args; do
    is_main "$args" || continue
    if [[ "$args" == *"--user-data-dir="* ]]; then
      local d="${args#*--user-data-dir=}"
      [ "$d" = "$want" ] && { echo "$pid"; return; }
    elif [ "$want" = "$DEFAULT_DIR" ]; then
      echo "$pid"; return
    fi
  done < <(ps -axo pid=,args=)
}

# The first other account whose cooldown has passed, in accounts.json order after $1.
pick_target() {
  local from="$1" now; now=$(date -u +%s)
  jq -r --arg from "$from" --argjson now "$now" --slurpfile st "$STATE" '
    (.accounts | map(.accountUuid)) as $ids
    | ($ids | index($from) // -1) as $i
    | [range(1; ($ids | length))] | map($ids[($i + .) % ($ids | length)])
    | map(select(. != $from))
    | map(select((($st[0].cooldowns[.] // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+";"") | fromdateiso8601) <= $now))
    | .[0] // empty' "$ACCOUNTS"
}

# Always a new instance: `open -a` alone would just bring forward whichever
# Claude is already running, even one on another profile folder.
launch_app() {
  local dir="$1" app; app=$(app_for_dir "$1")
  if [ "$dir" = "$DEFAULT_DIR" ]; then open -n -a "$app"; else open -n -a "$app" --args "--user-data-dir=$dir"; fi
}

# Every running Claude main process, whatever its folder.
all_instances() { local pid args; while read -r pid args; do is_main "$args" && echo "$pid"; done < <(ps -axo pid=,args=); }

# Main processes running one particular app bundle.
instances_of() {
  local bin="$1/Contents/MacOS/Claude" pid args
  while read -r pid args; do
    [[ "$args" == *"--type="* ]] && continue
    [[ "$args" == "$bin" || "$args" == "$bin "* ]] && echo "$pid"
  done < <(ps -axo pid=,args=)
}

# The app bundle a main process runs.
app_of_pid() { local args; args=$(ps -o args= -p "$1"); printf '%s' "${args%%/Contents/MacOS/Claude*}"; }

# Send a claude:// link to one app. A bare `open <link>` goes to whichever app macOS
# registered for claude:// (the orange one), and starts it if it isn't running, even
# when the window you meant runs a copy. Among instances of the same app, macOS still
# picks one, so callers check that only one instance of that app is open.
send_link() { open -a "$1" "$2"; }

wait_gone() { local pid="$1" n=0; while kill -0 "$pid" 2>/dev/null && [ $n -lt "$2" ]; do sleep 1; n=$((n+1)); done; ! kill -0 "$pid" 2>/dev/null; }
wait_up() { local dir="$1" n=0; while [ -z "$(instance_pid "$dir")" ] && [ $n -lt "$2" ]; do sleep 1; n=$((n+1)); done; [ -n "$(instance_pid "$dir")" ]; }

# The account the app in $1 last signed in as, from its own config.json (an id, not a secret).
folder_account() { jq -r '.lastKnownAccountUuid // empty' "$1/config.json" 2>/dev/null; }

parse_args() {
  FROM=""; RESETS_AT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) FROM="$2"; shift 2 ;;
      --resets-at) RESETS_AT="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

cmd_status() {
  echo "accounts:"; jq -r '.accounts[] | "  \(.name)  \(.email)  \(.accountUuid)  \(.userDataDir)  app: \(.app // "/Applications/Claude.app")"' "$ACCOUNTS"
  echo "cooldowns:"; jq -r '.cooldowns | to_entries[] | "  \(.key) until \(.value)"' "$STATE"
  echo "running instances:"
  jq -r '.accounts[] | .userDataDir' "$ACCOUNTS" | while read -r d; do
    d=$(expand "$d"); local pid; pid=$(instance_pid "$d")
    echo "  $(basename "$d"): ${pid:-not running}  signed in as $(folder_account "$d")"
  done
  echo "pending resumes:"; jq -r '.resume[] | "  \(.sessionId)  \(.cwd)  (\(.reason))"' "$HANDOFF"
}

cmd_plan() {
  parse_args "$@"
  local target from_dir to_dir; target=$(pick_target "$FROM")
  from_dir=$(expand "$(account_field "$FROM" userDataDir)")
  echo "from:   $(account_field "$FROM" name) ($FROM) in $from_dir, pid $(instance_pid "$from_dir")"
  if [ -z "$target" ]; then echo "to:     nobody: every other account is cooling down"; return; fi
  to_dir=$(expand "$(account_field "$target" userDataDir)")
  echo "to:     $(account_field "$target" name) ($target) in $to_dir, folder signed in as $(folder_account "$to_dir")"
  echo "resume: $(jq -r '[.resume[].sessionId] | join(", ")' "$HANDOFF")"
}

# Run "relay.sh <args>" once under launchd, so it outlives the Claude app that started it.
# A one-shot job: no KeepAlive, so a failed run is never retried in a loop.
run_job() {
  local plist="$DIR/$LABEL.plist" uid a args=""; uid=$(id -u)
  for a in "$@"; do args+="    <string>$a</string>"$'\n'; done
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$DIR/relay.sh</string>
$args  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.out</string>
</dict></plist>
EOF
  launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$uid" "$plist"
}

cmd_launch() {
  parse_args "$@"
  [ -n "$FROM" ] || die "launch needs --from"
  run_job switch --from "$FROM" --resets-at "${RESETS_AT:-}" && log "launch: switch away from $FROM queued under launchd"
}

account_by_name() { jq -r --arg n "$1" '.accounts[] | select(.name == $n) | .accountUuid' "$ACCOUNTS"; }

cmd_relaunch_later() {
  [ -n "$(account_by_name "${1:-}")" ] || die "relaunch-later: no account named ${1:-}"
  run_job relaunch "$@" && log "relaunch: $1 queued under launchd"
}

# Restart one account's window in the app accounts.json gives it, then reopen a session there.
cmd_relaunch() {
  local name="${1:-}" id; id=$(account_by_name "$name"); shift || true
  [ -n "$id" ] || die "relaunch: no account named $name"
  local session=""; [ "${1:-}" = "--resume" ] && session="${2:-}"
  local dir pid; dir=$(expand "$(account_field "$id" userDataDir)"); pid=$(instance_pid "$dir")
  sleep 10  # let the caller's turn finish before its app quits
  if [ -n "$pid" ]; then
    kill -TERM "$pid"; wait_gone "$pid" 30 || { kill -KILL "$pid"; wait_gone "$pid" 5; }
    log "relaunch: $name (pid $pid) closed"
  fi
  launch_app "$dir"
  wait_up "$dir" 60 || die "relaunch: $name did not start in $(app_for_dir "$dir")"
  log "relaunch: $name open in $(app_for_dir "$dir")"
  [ -n "$session" ] || return 0
  sleep 12
  if [ "$(instances_of "$(app_for_dir "$dir")" | wc -l | tr -d ' ')" -gt 1 ]; then
    jq_write "$HANDOFF" --arg s "$session" --arg at "$(date -u +%FT%TZ)" '.resume += [{sessionId: $s, cwd: "", reason: "relaunch", at: $at}]'
    log "relaunch: another Claude window is open; session $session held for relay.sh resume"
  else
    send_link "$(app_for_dir "$dir")" "claude://resume?session=$session" && log "relaunch: reopened session $session"
  fi
}

cmd_switch() {
  parse_args "$@"
  [ -n "$FROM" ] || die "switch needs --from"

  # One switch at a time, however many sessions hit the limit together.
  if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$LOCK"; mkdir "$LOCK" || exit 0
    else log "switch: another switch holds the lock; nothing to do"; exit 0; fi
  fi
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT

  # A second trigger from the account we already left is a no-op.
  local last; last=$(jq -r '.switches[-1] // empty | select(.from != null) | "\(.from) \(.at)"' "$STATE")
  if [ -n "$last" ] && [ "${last%% *}" = "$FROM" ] && [ $(( $(date -u +%s) - ${last##* } )) -lt 300 ]; then
    log "switch: already left $FROM in the last 5 minutes; nothing to do"; exit 0
  fi

  local cool="${RESETS_AT:-$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)}"
  jq_write "$STATE" --arg u "$FROM" --arg t "$cool" '.cooldowns[$u] = $t'
  log "switch: $(account_field "$FROM" name) is out; cooling down until $cool"

  local target; target=$(pick_target "$FROM")
  [ -n "$target" ] || die "every account is out of usage; staying put"

  local from_dir to_dir from_pid
  from_dir=$(expand "$(account_field "$FROM" userDataDir)")
  to_dir=$(expand "$(account_field "$target" userDataDir)")
  [ "$(folder_account "$to_dir")" = "$target" ] || die "$(account_field "$target" name)'s folder is not signed in as that account; sign in there once"

  from_pid=$(instance_pid "$from_dir")
  log "switch: $(account_field "$FROM" name) (pid ${from_pid:-none}) -> $(account_field "$target" name) in $to_dir"

  if [ -n "$from_pid" ]; then
    kill -TERM "$from_pid"
    wait_gone "$from_pid" 30 || { log "switch: app still up after 30 s; SIGKILL"; kill -KILL "$from_pid"; wait_gone "$from_pid" 5; }
  fi

  if [ -n "$(instance_pid "$to_dir")" ]; then
    log "switch: $(account_field "$target" name)'s app is already open; using it"
  else
    launch_app "$to_dir"
  fi
  if ! wait_up "$to_dir" 60; then
    log "switch: $to_dir did not start; going back to $from_dir"
    launch_app "$from_dir"
    die "could not open $(account_field "$target" name)'s app; went back"
  fi
  jq_write "$STATE" --arg f "$FROM" --arg t "$target" --argjson at "$(date -u +%s)" '.switches += [{from: $f, to: $t, at: $at}] | .switches |= .[-20:]'

  # Give the app time to load its web login before handing it links.
  sleep 12
  # Links go to the target's app, but macOS picks among several instances of
  # that app, so only send them when the target is its app's one instance.
  local to_app; to_app=$(app_for_dir "$to_dir")
  if [ "$(instances_of "$to_app" | wc -l | tr -d ' ')" -gt 1 ]; then
    log "switch: another window of $to_app is running; not sending resume links (they could land in the wrong one)"
    notify "Switched to $(account_field "$target" name), but another Claude window is open, so sessions were not reopened. Close it and run: relay.sh resume"
    log "switch: done (resumes held)"; return
  fi
  local ids; ids=$(jq -r '.resume[].sessionId' "$HANDOFF")
  for id in $ids; do
    send_link "$to_app" "claude://resume?session=$id" && log "switch: reopened session $id"
    sleep 3
  done
  notify "Switched to $(account_field "$target" name). Reopened $(echo "$ids" | grep -c . | tr -d ' ') session(s)."
  log "switch: done"
}

cmd_resume() {
  local pids; pids=$(all_instances)
  [ "$(echo "$pids" | grep -c .)" -eq 1 ] || { echo "run this with exactly one Claude window open" >&2; exit 1; }
  local app; app=$(app_of_pid "$pids")
  for id in $(jq -r '.resume[].sessionId' "$HANDOFF"); do send_link "$app" "claude://resume?session=$id" && log "resume: reopened session $id"; sleep 3; done
}

case "${1:-}" in
  resume) cmd_resume ;;
  launch) shift; cmd_launch "$@" ;;
  switch) shift; cmd_switch "$@" ;;
  plan)   shift; cmd_plan "$@" ;;
  status) cmd_status ;;
  relaunch) shift; cmd_relaunch "$@" ;;
  relaunch-later) shift; cmd_relaunch_later "$@" ;;
  *) echo "usage: relay.sh launch|switch|plan --from <accountUuid> [--resets-at <iso>] | status | relaunch[-later] <name> [--resume <id>] | resume" >&2; exit 2 ;;
esac
