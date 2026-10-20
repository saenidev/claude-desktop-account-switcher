#!/bin/bash
# claude-desktop-account-switcher: switch Claude Desktop to another account in place
# when one runs out (or by hand), then reopen the sessions the switch cut off.
#
# The app's account is its claude.ai sign-in, the Cookies file in its one profile
# folder. Accounts not in use have theirs parked in $DIR/park/<accountUuid>/; a switch
# closes Claude, moves the sign-ins, and opens it again. Never reads, copies or prints
# a token. See README.md.
#
#   relay.sh launch --from <accountUuid> [--resets-at <iso>]   start an out-of-usage switch under launchd (returns at once)
#   relay.sh switch --from <accountUuid> [--resets-at <iso>]   do it (what launchd runs)
#   relay.sh plan   --from <accountUuid>                       print what a switch would do, change nothing
#   relay.sh status                                            accounts, cooldowns, running instance
#   relay.sh swap-later <name> [--resume <sessionId>]          switch to <name> by hand, under launchd (the /account button)
#   relay.sh signin-later <name> [--resume <sessionId>]        open Claude signed out to sign <name> in, then come back
#   relay.sh restart-later [--resume <sessionId>]              restart Claude on the same account, fixing settings and scratch paths
#   relay.sh doctor | history [<n>] | keepalive [<days>] [--force] | install-keepalive
#   relay.sh resume                                            reopen held sessions
#
# Left from the earlier one-app-per-account design (docs/history.md), unused now:
# relaunch, relaunch-later, sync, guard, install-agents.

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
  refresh_copy "$app"
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

# When a parked sign-in runs out (UTC): the claude.ai sessionKey cookie's expiry, read from
# the cookie database's metadata. The cookie's value is encrypted and never read.
signin_expires() {
  local f="$PARK/$1/Cookies"; [ -f "$f" ] || return 0
  sqlite3 "file:$f?immutable=1" "select datetime(max(expires_utc)/1000000-11644473600,'unixepoch') from cookies where name='sessionKey'" 2>/dev/null
}

signin_expires_epoch() {
  local f="$PARK/$1/Cookies"; [ -f "$f" ] || { echo 0; return; }
  sqlite3 "file:$f?immutable=1" "select coalesce(max(expires_utc)/1000000-11644473600, 0) from cookies where name='sessionKey'" 2>/dev/null || echo 0
}

# Keep parked sign-ins from expiring (after caam's keepalive: use the login in its own home,
# then re-read it; a clean exit alone isn't success). For each parked account with fewer than
# <days> left (default 7, or any with --force): open Claude in the background on a throwaway
# profile folder holding only that sign-in, let claude.ai load, quit that instance, park the
# sign-in again. The Claude window you use is never touched.
#   relay.sh keepalive [<days>] [--force]        (daily from a launchd agent: install-keepalive)
KEEP="$DIR/keepalive-profile"
cmd_keepalive() {
  local days=7 force="" a
  for a in "$@"; do case "$a" in --force) force=1 ;; *) days="$a" ;; esac; done
  local id now; now=$(date -u +%s)
  for id in $(jq -r '.accounts[].accountUuid' "$ACCOUNTS"); do
    local name; name=$(account_field "$id" name)
    [ "$(folder_account "$DEFAULT_DIR")" = "$id" ] && continue   # in use: the app keeps it fresh itself
    if [ ! -f "$PARK/$id/Cookies" ]; then
      log "keepalive: $name has no parked sign-in"; notify "$name is signed out. Run relay.sh signin-later $name."; continue
    fi
    local exp left; exp=$(signin_expires_epoch "$id"); left=$(( (exp - now) / 86400 ))
    if [ -z "$force" ] && [ "$left" -gt "$days" ]; then log "keepalive: $name good for $left more days"; continue; fi
    refresh_parked "$id"
    local after; after=$(signin_expires_epoch "$id")
    if [ "$after" -gt "$exp" ]; then
      log "keepalive: $name renewed, now good until $(date -u -r "$after" '+%F %T') UTC"
    else
      log "keepalive: $name not renewed; expires $(date -u -r "$exp" '+%F %T') UTC"
      [ "$left" -le 3 ] && notify "$name's sign-in expires in $left days and couldn't be renewed. Run relay.sh signin-later $name."
    fi
  done
}

refresh_parked() {
  local id="$1" f
  if ! mkdir "$LOCK" 2>/dev/null; then log "keepalive: a switch is running; skipped"; return 0; fi
  mkdir -p "$KEEP"
  for f in Cookies Cookies-journal; do [ -e "$PARK/$id/$f" ] && mv -f "$PARK/$id/$f" "$KEEP/$f"; done
  open -g -n -a "$APP" --args "--user-data-dir=$KEEP"
  local n=0 pid=""
  while [ $n -lt 90 ]; do
    pid=$(instance_pid "$KEEP")
    [ -n "$pid" ] && [ "$(folder_account "$KEEP")" = "$id" ] && break
    sleep 2; n=$((n+2))
  done
  if [ "$(folder_account "$KEEP")" = "$id" ]; then sleep 20; else log "keepalive: $(account_field "$id" name)'s sign-in did not load in the background instance"; fi
  pid=$(instance_pid "$KEEP"); [ -n "$pid" ] && quit_pid "$pid"
  for f in Cookies Cookies-journal; do [ -e "$KEEP/$f" ] && mv -f "$KEEP/$f" "$PARK/$id/$f"; done
  rmdir "$LOCK" 2>/dev/null
}

cmd_install_keepalive() {
  local plist="$HOME/Library/LaunchAgents/$LABEL.keepalive.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL.keepalive</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DIR/relay.sh</string><string>keepalive</string><string>27</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL.keepalive" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$plist" && log "keepalive: daily check installed (04:30)"
}

# Check the whole setup (after caam's doctor). Prints ok / !! per check; exits 1 if any failed.
cmd_doctor() {
  local bad=0
  ok()   { echo "ok  $*"; }
  fail() { echo "!!  $*"; bad=1; }
  [ -L "$DIR/relay.sh" ] && [ -e "$DIR/relay.sh" ] && ok "relay.sh -> $(readlink "$DIR/relay.sh")" || fail "$DIR/relay.sh is not a working link"
  [ -L "$DIR/mod" ] && [ -e "$DIR/mod/hooks/hooks.json" ] && ok "mod -> $(readlink "$DIR/mod")" || fail "$DIR/mod is not a working link"
  jq -e '.enabledPlugins["account-relay@account-relay-local"] == true' "$HOME/.claude/settings.json" >/dev/null 2>&1 && ok "mod installed and enabled" || fail "mod not enabled (claude plugin install account-relay@account-relay-local)"
  local n; n=$(jq '[.accounts[] | select(.accountUuid and .orgUuid and .name)] | length' "$ACCOUNTS" 2>/dev/null || echo 0)
  [ "$n" -ge 2 ] && ok "$n accounts in accounts.json" || fail "accounts.json needs 2+ accounts with name, accountUuid, orgUuid"
  local cur; cur=$(folder_account "$DEFAULT_DIR")
  [ -n "$(account_field "$cur" name)" ] && ok "Claude is signed in as $(account_field "$cur" name)" || fail "Claude is signed in as ${cur:-nobody}, which isn't in accounts.json"
  local id now; now=$(date -u +%s)
  for id in $(jq -r '.accounts[].accountUuid' "$ACCOUNTS"); do
    [ "$id" = "$cur" ] && continue
    local exp; exp=$(signin_expires_epoch "$id")
    if [ "$exp" -gt "$now" ]; then ok "$(account_field "$id" name) parked, $(( (exp - now) / 86400 )) days left"
    else fail "$(account_field "$id" name) has no live parked sign-in (relay.sh signin-later $(account_field "$id" name))"; fi
  done
  local pids; pids=$(default_pids | wc -l | tr -d ' ')
  [ "$pids" -le 1 ] && ok "$pids Claude window(s) on the profile folder" || fail "$pids Claude windows on one profile folder: quit all but one"
  local kind canon="" d
  for kind in claude-code-sessions local-agent-mode-sessions; do
    for d in "$DEFAULT_DIR/$kind"/*/*; do
      [ -d "$d" ] || continue; case "$d" in *.merged-*) continue ;; esac
      case "$(basename "$(dirname "$d")")" in ????????-????-????-????-????????????) ;; *) continue ;; esac   # account folders only
      if [ -L "$d" ]; then canon=$(readlink "$d"); else ok "$kind: shared list $(basename "$(dirname "$d")" | cut -c1-8)/$(basename "$d" | cut -c1-8)"; fi
    done
    [ -n "$canon" ] && [ ! -d "$canon" ] && fail "$kind: link points at a missing folder $canon"
  done
  launchctl print "gui/$(id -u)/$LABEL.keepalive" >/dev/null 2>&1 && ok "daily keep-alive installed" || fail "daily keep-alive not installed (relay.sh install-keepalive)"
  [ -d "$LOCK" ] && fail "a switch lock is held ($LOCK); remove it if no switch is running" || ok "no switch running"
  echo "auto-switch: $(jq -r 'if .armed then "on" else "off" end' "$DIR/config.json" 2>/dev/null || echo off)"
  return $bad
}

# Recent switches and sign-in events, newest last (after caam's history).
cmd_history() {
  grep -E 'swap: [a-z]+ -> |switch: .* is out|signin: |keepalive: .*(renewed|not renewed)|launched relay away|not switching' "$LOG" | tail -n "${1:-20}"
}

# An account's last usage reading, which the mod saves while that account is in use
# (after caam's `limits --cached`). A window past its reset time counts as reset.
usage_line() {
  jq -r --arg a "$1" --argjson now "$(date -u +%s)" '
    .[$a] // empty
    | (.windows | map(select(.kind == "five_hour" or .kind == "seven_day")
        | (if .kind == "five_hour" then "5-hour" else "weekly" end) as $k
        | if (.resetsAt // "") != "" and ((.resetsAt | sub("\\.[0-9]+"; "") | fromdateiso8601) <= $now)
          then "\($k) reset since" else "\($k) \(.percentUsed | round)%" end) | join(" · "))
      + " · as of \((($now - (.at / 1000)) / 60) | floor)m ago"' "$DIR/usage.json" 2>/dev/null | grep . || echo "no reading yet"
}

# Where an account's sign-in is: in Claude now, parked and ready, or nowhere (needs signin).
signin_state() {
  if [ "$(folder_account "$DEFAULT_DIR")" = "$1" ]; then echo "in Claude now"
  elif [ -f "$PARK/$1/Cookies" ]; then echo "parked, ready to switch to (sign-in good until $(signin_expires "$1") UTC)"
  else echo "not signed in (relay.sh signin-later $(account_field "$1" name))"; fi
}

cmd_status() {
  local pid; pid=$(default_pids | head -1)
  if [ -n "$pid" ]; then echo "Claude: running (pid $pid)"; else echo "Claude: not running"; fi
  echo "auto-switch: $(jq -r 'if .armed then "on" else "off" end' "$DIR/config.json" 2>/dev/null || echo off)"
  echo "accounts:"
  local id; for id in $(jq -r '.accounts[].accountUuid' "$ACCOUNTS"); do
    local until; until=$(jq -r --arg a "$id" '.cooldowns[$a] // empty' "$STATE")
    echo "  $(account_field "$id" name)  $(account_field "$id" email)  $(signin_state "$id")${until:+  (out of usage until $until)}"
    echo "      usage: $(usage_line "$id")"
  done
  echo "pending resumes:"; jq -r '.resume[] | "  \(.sessionId)  (\(.reason))"' "$HANDOFF"
}

cmd_plan() {
  parse_args "$@"
  local target; target=$(pick_target "$FROM")
  echo "from:   $(account_field "$FROM" name) ($FROM): $(signin_state "$FROM")"
  if [ -z "$target" ]; then echo "to:     nobody: every other account is cooling down"; return; fi
  echo "to:     $(account_field "$target" name) ($target): $(signin_state "$target")"
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

cmd_resume() {
  local pids; pids=$(all_instances)
  [ "$(echo "$pids" | grep -c .)" -eq 1 ] || { echo "run this with exactly one Claude window open" >&2; exit 1; }
  local app; app=$(app_of_pid "$pids")
  for id in $(jq -r '.resume[].sessionId' "$HANDOFF"); do send_link "$app" "claude://resume?session=$id" && log "resume: reopened session $id"; sleep 3; done
}

# ---- Keeping each account in its own app, one window per profile folder ----------------
#
# The app has no single-instance lock, and Dock, Spotlight and Finder launches never pass
# --user-data-dir, so any app opened by hand opens the default folder. An account can have
# its own app in accounts.json: an untouched copy of the real app (still Anthropic-signed,
# so no Keychain prompts, and it updates itself) with a Finder custom icon ("icon"). The
# sync job keeps each copy on the real app's version and its icon on; the guard closes any
# window opened in the wrong app or on a folder that already has one.

SETICON="$DIR/seticon.swift"

app_version() { plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist" 2>/dev/null; }

# The custom icon for an app copy (accounts.json "icon"), if any.
icon_for_app() {
  local i; i=$(jq -r --arg a "$1" --arg h "$HOME" '.accounts[] | select(.app != null) | select((.app | sub("^~"; $h)) == $a) | .icon // empty' "$ACCOUNTS" | head -1)
  [ -n "$i" ] && expand "$i"
}
# Every app copy named in accounts.json.
copies() { jq -r '.accounts[].app // empty' "$ACCOUNTS" | while read -r a; do expand "$a"; echo; done; }

# Put an app copy on the real app's version (only while it isn't running).
refresh_copy() {
  local app="$1"
  [ "$app" = "$APP" ] && return 0
  [ -n "$(instances_of "$app")" ] && return 0
  local want have; want=$(app_version "$APP"); have=$(app_version "$app")
  [ "$want" = "$have" ] && return 0
  local tmp="$app.new.$$"
  ditto "$APP" "$tmp" || { log "refresh: copying $APP failed"; return 1; }
  set_icon "$tmp" "$app"
  # A copy in the Trash still claims claude:// with LaunchServices until it's unregistered.
  if [ -d "$app" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app"
    mv "$app" "$HOME/.Trash/$(basename "$app" .app) $have $(date +%Y%m%d-%H%M%S).app"
  fi
  mv "$tmp" "$app"
  log "refresh: $app ${have:-missing} -> $want"
}

# Give a copy its account's icon. The copy updates itself, and an update drops the icon.
set_icon() {
  local app="$1" icon; icon=$(icon_for_app "${2:-$1}")
  [ -n "$icon" ] && [ -f "$icon" ] || return 0
  [ -e "$app/Icon"$'\r' ] && return 0
  swift "$SETICON" "$icon" "$app" >/dev/null 2>&1
}

# What the sync agent runs: every copy on the real app's version, with its icon.
cmd_sync() {
  local app
  while read -r app; do
    [ -n "$app" ] || continue
    refresh_copy "$app"
    # From a launchd agent this fails (macOS blocks it); the mod runs sync from inside Claude.
    if [ -d "$app" ] && [ ! -e "$app/Icon"$'\r' ] && set_icon "$app" && [ -e "$app/Icon"$'\r' ]; then
      log "sync: icon put back on $app ($(app_version "$app"))"
    fi
  done < <(copies)
}

# Profile folder of a main process, from its command line.
folder_of() {
  local args; args=$(ps -o args= -p "$1")
  if [[ "$args" == *"--user-data-dir="* ]]; then printf '%s' "${args#*--user-data-dir=}"; else printf '%s' "$DEFAULT_DIR"; fi
}
started_at() { date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p "$1" | sed 's/  */ /g; s/^ //; s/ $//')" +%s 2>/dev/null; }
quit_pid() { kill -TERM "$1"; wait_gone "$1" 20 || kill -KILL "$1"; }

# Two rules, checked every few seconds:
#  1. A window running the wrong app for its folder (the orange app opened by hand lands
#     on saenidev's folder) is closed, and the folder is opened in its own app instead.
#  2. If two windows share a folder, the newer one is closed: the older one has the
#     folder's sessions and sign-in in use, and the newcomer has had no time to do anything.
cmd_guard() {
  local pid
  for pid in $(all_instances); do
    local f app want; f=$(folder_of "$pid"); app=$(app_of_pid "$pid"); want=$(app_for_dir "$f")
    jq -e --arg d "$f" --arg h "$HOME" '.accounts[] | select((.userDataDir | sub("^~"; $h)) == $d)' "$ACCOUNTS" >/dev/null || continue
    [ "$app" = "$want" ] && continue
    log "guard: $f opened in $app (pid $pid), but it belongs in $want; moving it"
    quit_pid "$pid"
    if [ -z "$(instance_pid "$f")" ]; then
      launch_app "$f"
      notify "$(basename "$want" .app) opened instead: that account lives there."
    fi
  done
  local rows=""
  for pid in $(all_instances); do rows+="$(started_at "$pid") $pid $(folder_of "$pid")"$'\n'; done
  [ -n "$rows" ] || return 0
  local dup; dup=$(printf '%s' "$rows" | sort -n | awk '{f=$0; sub(/^[0-9]+ [0-9]+ /,"",f); if (seen[f]++) print $2}')
  for pid in $dup; do
    local f; f=$(folder_of "$pid")
    log "guard: a second window (pid $pid, $(app_of_pid "$pid")) opened on $f; quitting it"
    notify "A second Claude window opened on $(basename "$f"), the same account as one already open. It was closed."
    quit_pid "$pid"
  done
}

# Two standing launchd agents: the guard every 5 seconds, and sync whenever an app's
# Info.plist changes (an update), every 5 minutes, and at login.
cmd_install_agents() {
  local uid; uid=$(id -u)
  local agents="$HOME/Library/LaunchAgents"; mkdir -p "$agents"
  write_agent() {
    local label="$1" cmd="$2" trigger="$3" plist="$agents/$1.plist"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DIR/relay.sh</string><string>$cmd</string></array>
$trigger
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.out</string>
</dict></plist>
EOF
    launchctl bootout "gui/$uid/$label" 2>/dev/null
    launchctl bootstrap "gui/$uid" "$plist" && echo "loaded $label"
  }
  write_agent "$LABEL.guard" guard "  <key>StartInterval</key><integer>5</integer>"
  local watch="<string>$APP/Contents/Info.plist</string>" c
  while read -r c; do [ -n "$c" ] && watch+="<string>$c/Contents/Info.plist</string>"; done < <(copies)
  launchctl bootout "gui/$uid/$LABEL.reicon" 2>/dev/null; rm -f "$agents/$LABEL.reicon.plist"
  write_agent "$LABEL.sync" sync "  <key>WatchPaths</key><array>$watch</array>
  <key>StartInterval</key><integer>300</integer>"
}

# ---- Switching in place --------------------------------------------------------------
#
# The app's account is its claude.ai sign-in: the Cookies file in its profile folder
# (encrypted with the app's own Keychain key). Everything else in the folder (settings,
# extensions, session lists) stays put. A switch quits Claude, parks the current account's
# Cookies in park/<accountUuid>/, moves the target's in, and opens the same app again. The
# app sees the new sign-in and mints that account's Code tokens itself. Each sign-in is
# moved, never copied, so only one copy of it is ever in use.

PARK="$DIR/park"

# Every Claude window on the default folder, whatever app it runs.
default_pids() { local pid; for pid in $(all_instances); do [ "$(folder_of "$pid")" = "$DEFAULT_DIR" ] && echo "$pid"; done; }

quit_default() {
  local pids pid; pids=$(default_pids)
  [ -n "$pids" ] || return 0
  kill -TERM $pids 2>/dev/null
  for pid in $pids; do wait_gone "$pid" 30 || { kill -KILL "$pid"; wait_gone "$pid" 5; }; done
}

# Move the sign-in files: park the folder's current ones under $1, bring $2's in.
move_signin() {
  local out="$1" in="$2" f
  mkdir -p "$PARK/$out"
  for f in Cookies Cookies-journal; do [ -e "$DEFAULT_DIR/$f" ] && mv "$DEFAULT_DIR/$f" "$PARK/$out/$f"; done
  for f in Cookies Cookies-journal; do [ -e "$PARK/$in/$f" ] && mv "$PARK/$in/$f" "$DEFAULT_DIR/$f"; done
  return 0
}

# Switch the one Claude window to account $1 (a uuid). Returns non-zero, with the
# previous account restored, if the new sign-in doesn't come up.
swap_to() {
  local target="$1" cur; cur=$(folder_account "$DEFAULT_DIR")
  [ "$cur" = "$target" ] && { log "swap: already on $(account_field "$target" name)"; return 0; }
  [ -f "$PARK/$target/Cookies" ] || { log "swap: no parked sign-in for $(account_field "$target" name)"; return 1; }
  quit_default
  move_signin "$cur" "$target"
  apply_prefs_patch
  fix_scratch_paths
  mirror_prefs "$cur" "$target"
  open -a "$APP"
  local n=0; while [ "$(folder_account "$DEFAULT_DIR")" != "$target" ] && [ $n -lt 45 ]; do sleep 1; n=$((n+1)); done
  if [ "$(folder_account "$DEFAULT_DIR")" = "$target" ]; then
    log "swap: $(account_field "$cur" name) -> $(account_field "$target" name)"
    return 0
  fi
  log "swap: $(account_field "$target" name)'s sign-in did not come up; going back to $(account_field "$cur" name)"
  quit_default
  move_signin "$target" "$cur"
  open -a "$APP"
  return 1
}

# List a session to reopen, with why, before Claude closes: the app may bring the session
# back by itself before any link is sent, and the mod only sees entries already written.
hand_off() {
  jq_write "$HANDOFF" --arg s "$1" --arg r "$2" --arg at "$(date -u +%FT%TZ)" \
    '.resume = ([.resume[] | select(.sessionId != $s)] + [{sessionId: $s, cwd: "", reason: $r, at: $at}])'
}
drop_hand_off() { jq_write "$HANDOFF" --arg s "$1" '.resume |= map(select(.sessionId != $s))'; }

# Reopen the handed-off sessions in the (one) Claude window.
reopen_handoff() {
  local ids id; ids=$(jq -r '.resume[].sessionId' "$HANDOFF")
  for id in $ids; do send_link "$APP" "claude://resume?session=$id" && log "switch: reopened session $id"; sleep 3; done
  echo "$ids" | grep -c .
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

  local until="${RESETS_AT:-$(date -u -v+5H +%FT%TZ)}"
  jq_write "$STATE" --arg a "$FROM" --arg u "$until" '.cooldowns[$a] = $u'
  log "switch: $(account_field "$FROM" name) is out; cooling down until $until"

  local target; target=$(pick_target "$FROM")
  if [ -z "$target" ]; then
    notify "$(account_field "$FROM" name) is out of usage, and every other account is too."
    die "switch: no account to switch to"
  fi
  swap_to "$target" || die "could not switch to $(account_field "$target" name); stayed on $(account_field "$FROM" name)"
  jq_write "$STATE" --arg f "$FROM" --arg t "$target" --argjson at "$(date -u +%s)" '.switches += [{from: $f, to: $t, at: $at}] | .switches |= .[-20:]'
  sleep 12   # let the app load before handing it links
  local n; n=$(reopen_handoff)
  notify "Switched to $(account_field "$target" name). Reopened $n session(s)."
  log "switch: done"
}

# By hand: relay.sh swap <name> [--resume <sessionId>]. Run under launchd by swap-later.
cmd_swap() {
  local id; id=$(account_by_name "${1:-}"); [ -n "$id" ] || die "swap: no account named ${1:-}"
  local session=""; [ "${2:-}" = "--resume" ] && session="${3:-}"
  sleep 10   # let the caller's turn finish before its window quits
  [ -n "$session" ] && hand_off "$session" swap
  if ! swap_to "$id"; then
    [ -n "$session" ] && drop_hand_off "$session"
    die "swap to ${1} failed; stayed put"
  fi
  if [ -n "$session" ]; then
    sleep 12
    reopen_handoff >/dev/null
  fi
}
cmd_swap_later() { [ -n "$(account_by_name "${1:-}")" ] || die "swap-later: no account named ${1:-}"; run_job swap "$@" && log "swap: $1 queued under launchd"; }

# Some app preferences are stored per account (keys holding the account id, or
# "<account>/<org>"). Copy the outgoing account's onto the incoming one, so settings follow
# you across a switch. Only while Claude is closed: the running app rewrites this file.
PREFS="$DEFAULT_DIR/claude_desktop_config.json"
mirror_prefs() {
  local from="$1" to="$2" fo to_org
  fo=$(account_field "$from" orgUuid); to_org=$(account_field "$to" orgUuid)
  [ -f "$PREFS" ] || return 0
  cp -p "$PREFS" "$DIR/backups/claude_desktop_config.before-mirror.json"
  local tmp="$PREFS.tmp.$$"
  jq --arg f "$from" --arg t "$to" --arg fo "${fo:-none}" --arg to "${to_org:-none}" '
    walk(if type == "object" then
      . + (to_entries | map(select(.key | contains($f)))
           | map({key: (.key | gsub($f; $t) | gsub($fo; $to)), value}) | from_entries)
    else . end)' "$PREFS" > "$tmp" && jq empty "$tmp" && mv "$tmp" "$PREFS" && log "prefs: $(account_field "$from" name)'s per-account settings copied to $(account_field "$to" name)"
}

# A one-off settings fix ($DIR/prefs-patch.json), merged in the next time Claude is closed.
apply_prefs_patch() {
  [ -f "$DIR/prefs-patch.json" ] || return 0
  cp -p "$PREFS" "$DIR/backups/claude_desktop_config.before-patch.json"
  jq -s '.[0] * .[1]' "$PREFS" "$DIR/prefs-patch.json" > "$PREFS.tmp.$$" && mv "$PREFS.tmp.$$" "$PREFS" && mv "$DIR/prefs-patch.json" "$DIR/backups/prefs-patch.applied.json" && log "prefs: patch applied"
}

# The app files a session under Scratch only if its folder is inside the app's own
# scratch-workspaces. Sessions started in an old per-account profile folder
# (Claude-second) point outside it and show up as one project each. Point them back.
# Only while Claude is closed: the running app rewrites session files.
fix_scratch_paths() {
  local files f n=0
  files=$(grep -rlE 'Application Support/Claude-[^/"]+/scratch-workspaces/' "$DEFAULT_DIR/claude-code-sessions/" "$DEFAULT_DIR/local-agent-mode-sessions/" 2>/dev/null)
  [ -n "$files" ] || return 0
  mkdir -p "$DIR/backups/scratch-paths"
  while IFS= read -r f; do
    cp -p "$f" "$DIR/backups/scratch-paths/$(basename "$f")"
    sed -i '' -E "s#Application Support/Claude-[^/\"]+/scratch-workspaces/#Application Support/$(basename "$DEFAULT_DIR")/scratch-workspaces/#g" "$f" && n=$((n+1))
  done <<< "$files"
  log "scratch: pointed $n session(s) back into $(basename "$DEFAULT_DIR")/scratch-workspaces"
}

# Restart Claude in place (same account), applying any settings fix while it's closed.
cmd_restart() {
  local session=""; [ "${1:-}" = "--resume" ] && session="${2:-}"
  sleep 10
  [ -n "$session" ] && hand_off "$session" restart
  quit_default
  apply_prefs_patch
  fix_scratch_paths
  open -a "$APP"
  if [ -n "$session" ]; then
    sleep 15
    reopen_handoff >/dev/null
  fi
}

# Sign an account in by hand without losing the current one:
#   relay.sh signin <name> [--resume <sessionId>]   (run under launchd by signin-later)
# Parks the current sign-in, opens Claude signed out for you to sign in to <name>, then
# parks <name> and brings the previous account back. Gives up after 10 minutes.
cmd_signin() {
  local id; id=$(account_by_name "${1:-}"); [ -n "$id" ] || die "signin: no account named ${1:-}"
  local session=""; [ "${2:-}" = "--resume" ] && session="${3:-}"
  local cur; cur=$(folder_account "$DEFAULT_DIR")
  sleep 10
  [ -n "$session" ] && hand_off "$session" signin
  quit_default
  move_signin "$cur" "$id"   # nothing parked for $id, so Claude opens signed out
  open -a "$APP"
  notify "Sign in to ${1} in Claude. Your other account comes back afterwards."
  log "signin: waiting for ${1} to be signed in"
  local n=0; while [ "$(folder_account "$DEFAULT_DIR")" != "$id" ] && [ $n -lt 600 ]; do sleep 2; n=$((n+2)); done
  if [ "$(folder_account "$DEFAULT_DIR")" = "$id" ]; then log "signin: ${1} signed in"; sleep 8; else log "signin: no sign-in to ${1} within 10 minutes"; fi
  quit_default
  if [ "$(folder_account "$DEFAULT_DIR")" = "$id" ]; then move_signin "$id" "$cur"; else
    local f; for f in Cookies Cookies-journal; do [ -e "$PARK/$cur/$f" ] && mv -f "$PARK/$cur/$f" "$DEFAULT_DIR/$f"; done
  fi
  open -a "$APP"
  log "signin: back on $(account_field "$cur" name)"
  if [ -n "$session" ]; then
    sleep 15
    reopen_handoff >/dev/null
  fi
}

case "${1:-}" in
  resume) cmd_resume ;;
  launch) shift; cmd_launch "$@" ;;
  switch) shift; cmd_switch "$@" ;;
  plan)   shift; cmd_plan "$@" ;;
  status) cmd_status ;;
  swap)   shift; cmd_swap "$@" ;;
  signin) shift; cmd_signin "$@" ;;
  signin-later) shift; run_job signin "$@" ;;
  restart) shift; cmd_restart "$@" ;;
  restart-later) shift; run_job restart "$@" ;;
  swap-later) shift; cmd_swap_later "$@" ;;
  relaunch) shift; cmd_relaunch "$@" ;;
  relaunch-later) shift; cmd_relaunch_later "$@" ;;
  sync)   cmd_sync ;;
  guard)  cmd_guard ;;
  install-agents) cmd_install_agents ;;
  keepalive) shift; cmd_keepalive "$@" ;;
  install-keepalive) cmd_install_keepalive ;;
  doctor) cmd_doctor ;;
  history) shift; cmd_history "$@" ;;
  *) echo "usage: relay.sh launch|switch|plan --from <accountUuid> [--resets-at <iso>] | status | relaunch[-later] <name> [--resume <id>] | resume" >&2; exit 2 ;;
esac
