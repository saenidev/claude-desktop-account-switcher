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
    [[ "$args" == "$BIN"* ]] || continue
    [[ "$args" == *"--type="* ]] && continue
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
  local dir="$1"
  if [ "$dir" = "$DEFAULT_DIR" ]; then open -n -a "$APP"; else open -n -a "$APP" --args "--user-data-dir=$dir"; fi
}

# Every running Claude main process, whatever its folder.
all_instances() { ps -axo pid=,args= | awk -v bin="$BIN" 'index($0, bin) && !/--type=/ {print $1}'; }

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
  echo "accounts:"; jq -r '.accounts[] | "  \(.name)  \(.email)  \(.accountUuid)  \(.userDataDir)"' "$ACCOUNTS"
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

cmd_launch() {
  parse_args "$@"
  [ -n "$FROM" ] || die "launch needs --from"
  local plist="$DIR/$LABEL.plist" uid; uid=$(id -u)
  # A one-shot job: no KeepAlive, so a failed run is never retried in a loop.
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$DIR/relay.sh</string><string>switch</string>
    <string>--from</string><string>$FROM</string>
    <string>--resets-at</string><string>${RESETS_AT:-}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.out</string>
</dict></plist>
EOF
  launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$uid" "$plist" && log "launch: switch away from $FROM queued under launchd"
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
  # claude:// links go to whichever instance macOS picks, so only send them
  # when the target is the one Claude running.
  if [ "$(all_instances | wc -l | tr -d ' ')" -gt 1 ]; then
    log "switch: another Claude instance is running; not sending resume links (they could land in the wrong one)"
    notify "Switched to $(account_field "$target" name), but another Claude window is open, so sessions were not reopened. Close it and run: relay.sh resume"
    log "switch: done (resumes held)"; return
  fi
  local ids; ids=$(jq -r '.resume[].sessionId' "$HANDOFF")
  for id in $ids; do
    open "claude://resume?session=$id" && log "switch: reopened session $id"
    sleep 3
  done
  notify "Switched to $(account_field "$target" name). Reopened $(echo "$ids" | grep -c . | tr -d ' ') session(s)."
  log "switch: done"
}

cmd_resume() {
  [ "$(all_instances | wc -l | tr -d ' ')" -eq 1 ] || { echo "run this with exactly one Claude window open" >&2; exit 1; }
  for id in $(jq -r '.resume[].sessionId' "$HANDOFF"); do open "claude://resume?session=$id" && log "resume: reopened session $id"; sleep 3; done
}

case "${1:-}" in
  resume) cmd_resume ;;
  launch) shift; cmd_launch "$@" ;;
  switch) shift; cmd_switch "$@" ;;
  plan)   shift; cmd_plan "$@" ;;
  status) cmd_status ;;
  *) echo "usage: relay.sh launch|switch|plan --from <accountUuid> [--resets-at <iso>] | status" >&2; exit 2 ;;
esac
