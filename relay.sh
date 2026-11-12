#!/bin/bash
# claude-desktop-account-switcher: switch Claude Desktop to another account in place
# when one runs out (or by hand), then reopen the sessions the switch cut off.
#
# The app's account is its claude.ai sign-in, the Cookies file in its one profile
# folder. Accounts not in use have theirs parked in $DIR/park/<accountUuid>/; a switch
# closes Claude, moves the sign-ins, and opens it again. Sign-ins are moved, never read; the
# one token used is a terminal login's, sent to Anthropic for usage (`relay.sh usage`), never
# printed or logged. See README.md, and `relay.sh help` for the commands.

#
# On Linux there is no desktop app, so only the terminal half runs: terminal claude's login
# (~/.claude/.credentials.json) is swapped for another account's parked one when usage runs
# out, by a systemd timer (`relay.sh tick`) and by the mod. See "Linux" below.

set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
: "${USER:=$(id -un)}"

# What differs between a Mac's tools and Linux's.
LINUX=""; [ "$(uname)" = Linux ] && LINUX=1
if [ -n "$LINUX" ]; then
  mtime() { stat -c %Y "$1" 2>/dev/null; }
  file_mode() { stat -c %a "$1" 2>/dev/null; }
  in_5h() { date -u -d '+5 hours' +%FT%TZ; }
  utc_at() { date -u -d "@$1" '+%F %T'; }            # an epoch as a UTC date and time
  lstart_epoch() { date -d "$1" +%s 2>/dev/null; }   # ps's lstart as an epoch
else
  mtime() { stat -f %m "$1" 2>/dev/null; }
  file_mode() { stat -f %Lp "$1" 2>/dev/null; }
  in_5h() { date -u -v+5H +%FT%TZ; }
  utc_at() { date -u -r "$1" '+%F %T'; }
  lstart_epoch() { LC_ALL=C date -j -f '%a %b %d %T %Y' "$1" +%s 2>/dev/null; }
fi
# A fingerprint of stdin, to tell two secrets apart without printing either.
if command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 | cut -d' ' -f1; }; else sha() { sha256sum | cut -d' ' -f1; }; fi

DIR="$HOME/.claude/desktop-account-switcher"
ACCOUNTS="$DIR/accounts.json"
STATE="$DIR/state.json"
HANDOFF="$DIR/handoff.json"
LOG="$DIR/relay.log"
LOCK="$DIR/switch.lock"
PARK="$DIR/park"
USAGE="$DIR/usage.json"
# The app to switch. Tests point this at a stand-in app; nobody else needs to.
APP="${ACCOUNT_SWITCHER_APP:-/Applications/Claude.app}"
BIN="$APP/Contents/MacOS/Claude"
DEFAULT_DIR="$HOME/Library/Application Support/Claude"
PREFS="$DEFAULT_DIR/claude_desktop_config.json"
LABEL="local.desktop-account-switcher"
# The label older versions used: kept so a job they queued still runs as one, and so
# install-keepalive can take their keep-alive job out.
OLD_LABEL="com.jun.desktop-account-switcher"
PLUGIN="desktop-account-switcher@desktop-account-switcher-local"
# Claude Desktop versions this was checked against by hand (version prefixes). Others still
# switch, after check_app, but doctor says they're untested.
TESTED_VERSIONS="3.1623"

# This script's own folder, through the link in $DIR.
REPO() { local s="${BASH_SOURCE[0]}"; while [ -L "$s" ]; do s=$(readlink "$s"); done; cd "$(dirname "$s")" && pwd; }

log() { [ -d "$DIR" ] && printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; return 0; }
# The text goes to osascript as an argument, never inside the script, so a name with quotes
# or & shows as it is.
# A Linux server has nowhere to show one: there the text goes to the program $DIR/notify, if
# you put one there (to send it to your phone, say). What happened is in the log either way.
notify() {
  if [ -n "$LINUX" ]; then [ -x "$DIR/notify" ] && "$DIR/notify" "$1" >/dev/null 2>&1 </dev/null; return 0; fi
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Claude account switcher"' -e 'end run' "$1" >/dev/null 2>&1 || true
}
die() { log "ERROR $*"; notify "$*"; echo "$*" >&2; exit 1; }
# Fixed waits (letting a turn finish, letting the app load). ACCOUNT_SWITCHER_FAST shortens them for tests.
pause() { if [ -n "${ACCOUNT_SWITCHER_FAST:-}" ]; then sleep 1; else sleep "$1"; fi; }
# run_for <seconds> <command...>: run it, killing it if it's still going after <seconds>.
run_for() {
  local secs="$1" pid dog rc; shift
  "$@" & pid=$!
  ( sleep "$secs" & wait $!; kill "$pid" 2>/dev/null ) 2>/dev/null & dog=$!
  wait "$pid"; rc=$?
  pkill -P "$dog" sleep 2>/dev/null; kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  return $rc
}

# Put the finished temp file $2 in place of $1, with $1's mode. Some of the files rewritten are
# private (claude_desktop_config.json is 0600 and can hold secrets), so temp files are made
# under umask 077 and only then given the original's mode.
replace_file() { local mode; mode=$(file_mode "$1") && chmod "$mode" "$2"; mv "$2" "$1"; }
# A folder lock (mkdir is atomic) around a read, change and write of one file, for changes that
# can come at the same moment: the relay's own (a switch and the usage check started after
# every turn both write state.json) and the mod's in every session (handoff.json, usage.json).
# The mod takes the same lock (LOCK_SH there). One older than 10 seconds was left by a process
# that was killed. After 10 seconds without it the change goes ahead anyway rather than not at all.
LOCK_SH='i=0; until mkdir "$1" 2>/dev/null; do i=$((i+1)); [ $i -ge 100 ] && exit 1; [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s) )) -gt 10 ] && rmdir "$1" 2>/dev/null; sleep 0.1; done'
locked() {   # locked <lock folder> <command...>
  local l="$1" got="" rc; shift
  /bin/sh -c "$LOCK_SH" sh "$l" && got=1
  "$@"; rc=$?
  [ -n "$got" ] && rmdir "$l" 2>/dev/null
  return $rc
}
# Write JSON atomically so a reader never sees half a file; the switcher's own files under the
# lock <file>.lock (the app's files are changed only while it's closed).
jq_write() {
  case "$1" in "$DIR"/*) locked "$1.lock" jq_write_now "$@" ;; *) jq_write_now "$@" ;; esac
}
jq_write_now() {
  local file="$1"; shift; local tmp="$file.tmp.$$"
  if ( umask 077; jq "$@" "$file" > "$tmp" ); then replace_file "$file" "$tmp"; else rm -f "$tmp"; return 1; fi
}

# handoff.json is changed by the relay and by the mod in every session, often at once (several
# sessions hit a limit together, several reopened sessions start together): always under its lock.
handoff_write() { jq_write "$HANDOFF" "$@"; }
handoff_read() { locked "$HANDOFF.lock" jq "$@" "$HANDOFF"; }

account_field() { jq -r --arg u "$1" --arg f "$2" '.accounts[] | select(.accountUuid == $u) | .[$f] // empty' "$ACCOUNTS"; }
account_by_name() { jq -r --arg n "$1" '.accounts[] | select(.name == $n) | .accountUuid // empty' "$ACCOUNTS"; }
account_ids() { jq -r '.accounts[].accountUuid // empty' "$ACCOUNTS"; }
# A benched account stays set up but no automatic switch goes to it (relay.sh bench <name>).
benched() { jq -e --arg u "$1" 'any(.accounts[]; .accountUuid == $u and .benched == true)' "$ACCOUNTS" >/dev/null 2>&1; }

# The account the app in $1 last signed in as, from its own config.json (an id, not a secret).
folder_account() { jq -r '.lastKnownAccountUuid // empty' "$1/config.json" 2>/dev/null; }

app_version() { plutil -extract CFBundleShortVersionString raw "${1:-$APP}/Contents/Info.plist" 2>/dev/null; }
version_tested() { local v; v=$(app_version); for t in $TESTED_VERSIONS; do [[ "$v" == "$t" || "$v" == "$t".* ]] && return 0; done; return 1; }

# Claude Desktop keeps its sign-in and session list in files it never promised to keep the
# same. Before closing Claude to move anything, check they're where this expects; an app
# update that moved them stops the switch instead of losing a sign-in. Prints what's wrong.
# Being signed out isn't a changed layout: Cookies is still the app's cookie database, only
# without a claude.ai sign-in, and a switch or sign-in from there is fine (the signed-out
# Cookies is parked like any other, and counts as signed out).
check_app() {
  [ -n "$(folder_account "$DEFAULT_DIR")" ] || { echo "config.json has no lastKnownAccountUuid"; return 1; }
  sqlite3 "file:$DEFAULT_DIR/Cookies?mode=ro&immutable=1" "select count(*) from cookies" >/dev/null 2>&1 || { echo "there's no Cookies database"; return 1; }
  [ -d "$DEFAULT_DIR/claude-code-sessions" ] || { echo "there's no claude-code-sessions folder"; return 1; }
}
signed_in_now() { [ "$(signin_cookies "$DEFAULT_DIR/Cookies" live)" -ge 1 ] 2>/dev/null; }

# How many claude.ai sessionKey cookies the Cookies file $1 holds (one per claude.ai host it
# was set on); with "live", only those that haven't expired. Only names, hosts and expiry
# dates are read, never values.
signin_cookies() {
  local live=""; [ "${2:-}" = live ] && live=" and (expires_utc = 0 or expires_utc/1000000-11644473600 > cast(strftime('%s','now') as integer))"
  [ -f "$1" ] || { echo 0; return; }
  sqlite3 "file:$1?mode=ro&immutable=1" "select count(*) from cookies where name='sessionKey' and host_key like '%claude.ai'$live" 2>/dev/null || echo 0
}

# ---- One thing at a time -------------------------------------------------------------------
#
# One lock for everything that moves a sign-in: use, add and signin, restart, a limit switch,
# remove, and the keep-alive. It's a folder (mkdir is atomic) holding its owner's pid and
# command. A lock whose owner is gone was left by a run that was killed, and is taken over;
# so is one whose pid now belongs to a process started after the lock was made (the pid was
# reused, say after a restart of the Mac). A live owner keeps it however long it runs (a
# sign-in waits up to 10 minutes, on top of quitting and opening Claude twice).
HAVE_LOCK=""
lock_stale() {
  local pid made started; made=$(mtime "$LOCK") || return 1
  pid=$(cat "$LOCK/pid" 2>/dev/null)
  # Made but no pid yet: its owner is between mkdir and writing it, or was killed there.
  if [ -z "$pid" ]; then [ $(( $(date +%s) - made )) -gt 60 ]; return; fi
  kill -0 "$pid" 2>/dev/null || return 0
  started=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ')
  started=$(lstart_epoch "$started") || return 1
  [ "$started" -gt "$made" ]
}
lock_held() { [ -d "$LOCK" ] && ! lock_stale; }
lock_owner() { echo "$(cat "$LOCK/what" 2>/dev/null || echo unknown), pid $(cat "$LOCK/pid" 2>/dev/null || echo unknown)"; }
# lock_take <command>: returns 1 if something else holds the lock.
lock_take() {
  if ! mkdir "$LOCK" 2>/dev/null; then
    # Taking over a stale lock is itself one at a time: two runs that both found it stale
    # would otherwise each remove it, the second removing the first's new one.
    if ! mkdir "$LOCK.takeover" 2>/dev/null; then
      [ $(( $(date +%s) - $(mtime "$LOCK.takeover" || date +%s) )) -gt 10 ] && rmdir "$LOCK.takeover" 2>/dev/null
      return 1
    fi
    local took=""
    if lock_stale; then
      log "lock: taking over a lock left by a run that was cut off ($(lock_owner))"
      rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null && took=1
    fi
    rmdir "$LOCK.takeover"
    [ -n "$took" ] || return 1
  fi
  echo $$ > "$LOCK/pid"; echo "$1" > "$LOCK/what"; HAVE_LOCK=1
}
# Wait up to $2 seconds for the lock (the keep-alive holds it for a minute or so per account).
lock_wait() { local n=0; until lock_take "$1"; do [ $n -ge "$2" ] && return 1; sleep 2; n=$((n+2)); done; }
lock_release() { [ -n "$HAVE_LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"; HAVE_LOCK=""; }
# The commands that close Claude never run over each other.
lock_or_die() { lock_take "$1" || die "$1: a switch or sign-in is running; try again when it's done"; }

# When this process ends early (killed, or a die), first put back a sign-in it had moved
# half-way (UNDO says how), then let go of the lock. launchd stops a job with SIGTERM.
UNDO=""; RUN_OUT=""
on_exit() {
  local u="$UNDO"; UNDO=""; [ -n "$u" ] && eval "$u"
  lock_release; [ -n "$RUN_OUT" ] && rm -f "$RUN_OUT"
  return 0
}
trap on_exit EXIT
trap 'exit 143' TERM HUP

# ---- Claude's processes ------------------------------------------------------------------

is_main() { [[ "$1" != *"--type="* ]] && [[ "$1" == "$BIN" || "$1" == "$BIN "* ]]; }
all_instances() { local pid args; while read -r pid args; do is_main "$args" && echo "$pid"; done < <(ps -axo pid=,args=); }
folder_of() {
  local args; args=$(ps -o args= -p "$1")
  if [[ "$args" == *"--user-data-dir="* ]]; then printf '%s' "${args#*--user-data-dir=}"; else printf '%s' "$DEFAULT_DIR"; fi
}
# The main Claude process for a profile folder (the default one is launched without --user-data-dir).
instance_pid() { local pid; for pid in $(all_instances); do [ "$(folder_of "$pid")" = "$1" ] && { echo "$pid"; return; }; done; }
default_pids() { local pid; for pid in $(all_instances); do [ "$(folder_of "$pid")" = "$DEFAULT_DIR" ] && echo "$pid"; done; }

wait_gone() { local pid="$1" n=0; while kill -0 "$pid" 2>/dev/null && [ $n -lt "$2" ]; do sleep 1; n=$((n+1)); done; ! kill -0 "$pid" 2>/dev/null; }
quit_pid() { kill -TERM "$1"; wait_gone "$1" 20 || kill -KILL "$1"; }

quit_default() {
  local pids pid; pids=$(default_pids)
  [ -n "$pids" ] || return 0
  # The mod honours a hand-off entry only if Claude was closed after it was written. A session
  # mid-turn now (busy/, under 6 hours old) is cut off by this quit, whatever it was for: it's
  # listed to reopen on whichever account Claude comes back on, with the account it was on.
  local busy f; busy=$(for f in "$DIR"/busy/*.json; do [ -f "$f" ] && jq -c . "$f" 2>/dev/null; done \
    | jq -sc --argjson now "$(date +%s)000" '[.[] | select(.sessionId and .v == 2 and .busy != false and ($now - (.at // 0)) < 21600000)]')
  handoff_write --argjson b "${busy:-[]}" --arg at "$(date -u +%FT%TZ)" '
    .closedAt = $at
    | ([.resume[].sessionId]) as $have
    | .resume += [$b[] | select(.sessionId as $s | $have | index($s) | not)
        | {sessionId, cwd: (.cwd // ""), reason: "closed", account: "", from: (.account // ""), at: $at}]'
  local before; before=$(app_version)
  kill -TERM $pids 2>/dev/null
  for pid in $pids; do wait_gone "$pid" 30 || { kill -KILL "$pid"; wait_gone "$pid" 5; }; done
  # No turn outlives Claude.
  rm -f "$DIR"/busy/*.json
  let_update_install "$before"
}

# Claude downloads its updates by itself, and ShipIt (Squirrel) installs one when Claude quits.
# The relay quits Claude, so that's when a downloaded update lands. Opening Claude again while
# ShipIt is still waiting keeps the old version running until some later quit, when the update
# replaces the app underneath it (seen on 2026-10-20: a relay restart at 20:25, the install at
# 20:31). So after quitting, wait for ShipIt to finish, and open the new version.
SHIPIT_STATE="$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt/ShipItState.plist"
# Only Claude's own ShipIt, inside its bundle: other apps' updaters are ShipIt too.
shipit_running() {
  local p s="$APP/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"
  for p in $(pgrep -f 'Squirrel.framework/Resources/ShipIt'); do
    case "$(ps -p "$p" -o args= 2>/dev/null)" in "$s"*|*" $s"*) return 0 ;; esac
  done
  return 1
}
# A downloaded update waiting to be installed: ShipIt's state names an update bundle that's there.
update_waiting() {
  local b; b=$(jq -r '.updateBundleURL // empty' "$SHIPIT_STATE" 2>/dev/null | sed 's#^file://##; s#%20# #g')
  [ -n "$b" ] && [ -d "$b" ]
}
let_update_install() {
  local before="$1" n=0
  shipit_running || update_waiting || return 0
  log "update: Claude $before closed with an update waiting; letting it install before reopening"
  sleep 2
  while shipit_running && [ $n -lt 180 ]; do sleep 2; n=$((n+2)); done
  local after; after=$(app_version)
  if [ "$after" != "$before" ]; then log "update: Claude $before -> $after installed while closed"; notify "Claude updated to $after."
  elif shipit_running; then log "update: ShipIt still running after 3 minutes; opening Claude $before anyway"
  else log "update: nothing installed; Claude stays at $before"; fi
}

# Quit Claude before changing its files. An update that installed during the quit may keep
# them elsewhere, so check them again; if they're not where this expects, open Claude again
# with nothing changed and return 1.
quit_checked() {
  local before why; before=$(app_version)
  quit_default
  [ "$(app_version)" = "$before" ] && return 0
  why=$(check_app) && return 0
  log "update: Claude $(app_version) doesn't keep its files where this expects ($why); opening it again with nothing changed"
  notify "Claude updated to $(app_version), and its files changed ($why). Nothing was switched. Run relay.sh doctor."
  open_app
  return 1
}

open_app() { open -a "$APP"; }
send_link() { open -a "$APP" "$1"; }

# ---- Running under launchd -----------------------------------------------------------------
#
# Anything that closes Claude must outlive it, and a process started from inside Claude (the
# mod, a Code tab session's shell, its terminal panel) is closed with it. So those commands
# queue themselves as a one-shot launchd job and return; the job runs them for real.

# The job's plist sets ACCOUNT_SWITCHER_JOB; a job queued by the old version has its label instead.
in_job() { [ -n "${ACCOUNT_SWITCHER_JOB:-}" ] || [ "${XPC_SERVICE_NAME:-}" = "$OLD_LABEL" ]; }

# Text for a plist: & < > escaped, so an account name holding them stays one argument.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Whether a switch, sign-in or restart is under way: the job is running, or something holds
# the lock (the keep-alive takes it too).
job_running() { launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q 'state = running' || lock_held; }

# A one-shot job: no KeepAlive, so a failed run is never retried in a loop. There's one
# label, and booting out a running job kills it, so a job is never started over one that's
# running: returns 2 then, and the caller says so.
# With RUN_JOB_OVER_LOCK set, only a running job stops it, not the lock (the limit switch waits
# for a keep-alive to let go of it rather than being dropped).
RUN_JOB_OVER_LOCK=""
run_job() {
  local plist="$DIR/$LABEL.plist" uid a args="" env=""; uid=$(id -u)
  if [ -n "$RUN_JOB_OVER_LOCK" ]; then launchctl print "gui/$uid/$LABEL" 2>/dev/null | grep -q 'state = running' && return 2
  else job_running && return 2; fi
  for a in "$@"; do args+="    <string>$(xml "$a")</string>"$'\n'; done
  [ -n "${ACCOUNT_SWITCHER_APP:-}" ] && env+="<key>ACCOUNT_SWITCHER_APP</key><string>$(xml "$ACCOUNT_SWITCHER_APP")</string>"
  [ -n "${ACCOUNT_SWITCHER_FAST:-}" ] && env+="<key>ACCOUNT_SWITCHER_FAST</key><string>1</string>"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$(xml "$DIR/relay.sh")</string>
$args  </array>
  <key>EnvironmentVariables</key><dict><key>ACCOUNT_SWITCHER_JOB</key><string>1</string>$env</dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$(xml "$DIR/launchd.out")</string>
  <key>StandardErrorPath</key><string>$(xml "$DIR/launchd.out")</string>
</dict></plist>
EOF
  # A finished job stays loaded; it has to go before the label can be loaded again.
  launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$uid" "$plist"
}

# Run "$@" now if this is already the launchd job, else queue it as one.
now_or_job() {
  if in_job; then "cmd_$1" "${@:2}"; return; fi
  run_job "$@"
  case $? in
    0) ;;
    2) log "$1 ${2:-}: not started; a switch or sign-in is running"; echo "$1: a switch or sign-in is running; try again when it's done" >&2; exit 1 ;;
    *) die "couldn't start $1 under launchd" ;;
  esac
  log "$1 ${2:-}: queued under launchd"
  echo "Started. Claude closes in about 10 seconds; progress is in $LOG."
}

# ---- Choosing an account ---------------------------------------------------------------------

parse_args() {
  FROM=""; RESETS_AT=""; LIMIT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      # An option given last with no value is empty, not a crash under set -u.
      --from) FROM="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --resets-at) RESETS_AT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --limit) LIMIT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      *) shift ;;
    esac
  done
}

# The first other account that isn't benched, whose cooldown has passed and whose last usage
# reading has no window used up, in accounts.json order after $1. A used-up window that hasn't
# reset yet is still used up however old the reading is: usage only goes down at a reset.
# Windows counted: 5-hour and weekly, and the model's own weekly limit named in $2 (say "Fable
# weekly") when that is what ran out. $3, if given, lists the only accounts to consider (one id a line).
# If usage.json can't be read (a bad file, a time jq can't parse), the switch still happens:
# it's logged, and the pick is made again without the usage figures.
# $4 and $5 are for the Linux timer's switches (watch): $4 is the percent that rules an account
# out (default 100: only a used-up window does), and $5, when set, makes every window count,
# each model's own weekly limit too.
pick_target() {
  local from="$1" label="${2:-}" only="${3:-}" full="${4:-100}" all="${5:-}" now out err; now=$(date -u +%s)
  local prog='
    def epoch: sub("\\.[0-9]+";"") | sub("[+]00:00$";"Z") | fromdateiso8601;
    def spent($a): [($u[0][$a].windows // [])[]
      | select($all != "" or .kind == "five_hour" or .kind == "seven_day" or ($label != "" and .label == $label))
      | select(.percentUsed >= $full and ((.resetsAt // "") != "") and ((.resetsAt | epoch) > $now))] | length > 0;
    ($only | split("\n") | map(select(. != ""))) as $only
    | (.accounts | map(.accountUuid // empty)) as $ids
    | [.accounts[] | select(.benched == true) | .accountUuid] as $benched
    | ($ids | index($from) // -1) as $i
    | [range(1; ($ids | length) + 1)] | map($ids[($i + .) % ($ids | length)])
    | map(select(. != $from))
    | map(select(. as $a | $benched | index($a) | not))
    | map(select(($only | length) == 0 or (. as $a | $only | index($a))))
    | map(select((($st[0].cooldowns[.] // "1970-01-01T00:00:00Z") | epoch) <= $now))
    | map(select(spent(.) | not))
    | .[0] // empty'
  local args=(-r --arg from "$from" --arg label "$label" --arg only "$only" --argjson full "$full" --arg all "$all" --argjson now "$now" --slurpfile st "$STATE")
  if out=$(jq "${args[@]}" --slurpfile u "$USAGE" "$prog" "$ACCOUNTS" 2>&1); then printf '%s\n' "$out" | grep .; return 0; fi
  err=$(printf '%s' "$out" | head -1)
  log "switch: couldn't read the usage figures ($err); picking without them"
  jq "${args[@]}" --argjson u '[{}]' "$prog" "$ACCOUNTS" 2>/dev/null
}

# ---- Parked sign-ins ---------------------------------------------------------------------------

# When a parked sign-in runs out (UTC): the claude.ai sessionKey cookie's expiry, read from
# the cookie database's metadata. The cookie's value is encrypted and never read.
signin_expires() {
  local f="$PARK/$1/Cookies"; [ -f "$f" ] || return 0
  sqlite3 "file:$f?mode=ro&immutable=1" "select datetime(max(expires_utc)/1000000-11644473600,'unixepoch') from cookies where name='sessionKey'" 2>/dev/null
}

signin_expires_epoch() {
  local f="$PARK/$1/Cookies"; [ -f "$f" ] || { echo 0; return; }
  sqlite3 "file:$f?mode=ro&immutable=1" "select coalesce(max(expires_utc)/1000000-11644473600, 0) from cookies where name='sessionKey'" 2>/dev/null || echo 0
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
  for id in $(account_ids); do
    local name; name=$(account_field "$id" name)
    [ "$(folder_account "$DEFAULT_DIR")" = "$id" ] && continue   # in use: the app keeps it fresh itself
    if [ ! -f "$PARK/$id/Cookies" ]; then
      log "keepalive: $name has no parked sign-in"; notify "$name is signed out. Run relay.sh signin $name."; continue
    fi
    local exp left; exp=$(signin_expires_epoch "$id"); left=$(( (exp - now) / 86400 ))
    if [ "$exp" -le "$now" ]; then
      log "keepalive: $name's parked sign-in has run out"; notify "$name's sign-in has run out. Run relay.sh signin $name."; continue
    fi
    if [ -z "$force" ] && [ "$left" -gt "$days" ]; then log "keepalive: $name good for $left more days"; continue; fi
    refresh_parked "$id"
    [ $? -eq 2 ] && continue   # a switch or sign-in was running: skipped, not a failed renewal
    local after; after=$(signin_expires_epoch "$id")
    if [ "$after" -gt "$exp" ]; then
      log "keepalive: $name renewed, now good until $(utc_at "$after") UTC"
    else
      log "keepalive: $name not renewed; expires $(utc_at "$exp") UTC"
      [ "$left" -le 3 ] && notify "$name's sign-in expires in $left days and couldn't be renewed. Run relay.sh signin $name."
    fi
  done
  cli_renew_all   # and the parked terminal logins
}

# Returns 2 when it didn't run because a switch or sign-in holds the lock.
refresh_parked() {
  local id="$1" f
  if ! lock_take keepalive; then log "keepalive: a switch or sign-in is running; skipped $(account_field "$id" name)"; return 2; fi
  recover_signin
  # A switch between the check and the lock may have taken this sign-in into Claude.
  if [ ! -f "$PARK/$id/Cookies" ] || [ "$(folder_account "$DEFAULT_DIR")" = "$id" ]; then
    log "keepalive: $(account_field "$id" name) isn't parked any more; skipped"; lock_release; return 2
  fi
  mkdir -p "$KEEP"
  # The profile remembers the last account it loaded; forget it, so loading this one shows.
  [ -f "$KEEP/config.json" ] && jq_write "$KEEP/config.json" 'del(.lastKnownAccountUuid)'
  # Which account's sign-in is in the throwaway profile, so a run killed half-way can be put back.
  echo "$id" > "$KEEP/account"
  UNDO=put_back_keepalive
  for f in Cookies Cookies-journal; do [ -e "$PARK/$id/$f" ] && mv -f "$PARK/$id/$f" "$KEEP/$f"; done
  open -g -n -a "$APP" --args "--user-data-dir=$KEEP"
  local n=0 pid=""
  while [ $n -lt 90 ]; do
    pid=$(instance_pid "$KEEP")
    [ -n "$pid" ] && [ "$(folder_account "$KEEP")" = "$id" ] && break
    sleep 2; n=$((n+2))
  done
  if [ "$(folder_account "$KEEP")" = "$id" ]; then pause 20; else log "keepalive: $(account_field "$id" name)'s sign-in did not load in the background instance"; fi
  pid=$(instance_pid "$KEEP"); [ -n "$pid" ] && quit_pid "$pid"
  for f in Cookies Cookies-journal; do [ -e "$KEEP/$f" ] && mv -f "$KEEP/$f" "$PARK/$id/$f"; done
  rm -f "$KEEP/account"; UNDO=""
  lock_release
  return 0
}

# A keep-alive killed half-way leaves a parked sign-in in the throwaway profile, maybe with
# its background instance still open. Close that instance and park the sign-in again under
# the account keepalive-profile/account names; with no such account, or a sign-in already
# parked there, it goes to backups/ instead of overwriting anything.
put_back_keepalive() {
  local id f pid b; id=$(cat "$KEEP/account" 2>/dev/null)
  pid=$(instance_pid "$KEEP"); [ -n "$pid" ] && quit_pid "$pid"
  if [ ! -e "$KEEP/Cookies" ] && [ ! -e "$KEEP/Cookies-journal" ]; then rm -f "$KEEP/account"; return 0; fi
  if [ -n "$(account_field "$id" name)" ] && [ ! -e "$PARK/$id/Cookies" ]; then
    mkdir -p "$PARK/$id"
    for f in Cookies Cookies-journal; do [ -e "$KEEP/$f" ] && mv -f "$KEEP/$f" "$PARK/$id/$f"; done
    log "recover: put $(account_field "$id" name)'s sign-in back from the keep-alive profile (a keep-alive was cut off)"
  else
    b=$(backup_dir keepalive-leftover)
    for f in Cookies Cookies-journal; do [ -e "$KEEP/$f" ] && mv -f "$KEEP/$f" "$b/$f"; done
    log "recover: the keep-alive profile held a sign-in for ${id:-an unknown account} that couldn't go back to park/; it's in $b"
  fi
  rm -f "$KEEP/account"
}

# The sign-in is the profile's Cookies; Claude closed for a sign-in leaves the account's
# parked under park/<account>/ while you sign in. A sign-in killed then (or a Mac that shut
# down) leaves Claude signed out with the sign-in still parked. If the profile has no live
# claude.ai sign-in but the account the app reports has one parked, close Claude, put it
# back (a signed-out Cookies goes to backups/), and open Claude again if it was open. A
# keep-alive cut off the same way is put back first. Run under the lock, at the start of
# every command that moves a sign-in. With --check, only says what it would put back.
recover_signin() {
  local check="${1:-}" id was="" who
  if [ -e "$KEEP/Cookies" ]; then
    who=$(account_field "$(cat "$KEEP/account" 2>/dev/null)" name)
    if [ -n "$check" ]; then echo "the keep-alive profile still holds ${who:-an unknown account}'s sign-in from a keep-alive that was cut off"
    else put_back_keepalive; fi
  fi
  if [ -f "$SWAPPING" ]; then
    if [ -n "$check" ]; then echo "a switch was cut off while it moved the sign-ins ($(swap_names))"
    else finish_swap; fi
  fi
  id=$(folder_account "$DEFAULT_DIR")
  [ -n "$id" ] && [ -f "$PARK/$id/Cookies" ] && [ "$(signin_cookies "$DEFAULT_DIR/Cookies" live)" = 0 ] || return 0
  if [ -n "$check" ]; then echo "Claude is signed out and $(account_field "$id" name)'s sign-in is still parked, from a sign-in that was cut off"; return 0; fi
  [ -n "$(default_pids)" ] && { quit_default; was=1; }
  move_pair "$PARK/$id" "$DEFAULT_DIR" signed-out-cookies
  log "recover: put $(account_field "$id" name)'s sign-in back into Claude (left parked by a sign-in that was cut off)"
  [ -n "$was" ] && open_app
  return 0
}

# A switch writes swap.inflight ("<from> <to>") just before it moves the sign-ins, adds each
# move ("<source><tab><destination>") just before making it, and "back" before it moves them
# back; it removes the file once the new account is up or the old one is back. Found later,
# the switch was cut off half-way (the Mac shut down, the job was killed): Claude's Cookies may
# be <to>'s while the app still reports <from>, and moving them now would park <to>'s sign-in
# as <from>'s. If the app came up on <to> (and the switch wasn't going back), it had worked;
# otherwise its moves are undone, last first, which puts every file back where it was.
SWAPPING="$DIR/swap.inflight"
swap_names() { local f t; read -r f t < "$SWAPPING"; echo "$(account_field "$f" name) to $(account_field "$t" name)"; }
# With "open" (the switch's own undo, as it's killed), Claude is opened again even if the
# switch had closed it.
finish_swap() {
  local from to was="${1:-}" src dst b="" n=0; read -r from to < "$SWAPPING"
  if [ -n "$to" ] && ! grep -qx back "$SWAPPING" && [ "$(folder_account "$DEFAULT_DIR")" = "$to" ]; then
    log "recover: the cut-off switch to $(account_field "$to" name) had worked"
    rm -f "$SWAPPING"; cli_follow "$to"; return 0
  fi
  [ -n "$(default_pids)" ] && { quit_default; was=1; }
  # No moves noted: none made, or the file is from a relay that didn't note them. Then how far
  # the move got is read from where the files are (park the current sign-in, then bring the
  # new one in): Claude holds <to>'s only once nothing is left parked for <to>; <from>'s is
  # still in Claude until it has been parked. With none made, this moves nothing.
  if [ "$(wc -l < "$SWAPPING")" -le 1 ]; then
    [ -n "$to" ] && [ ! -e "$PARK/$to/Cookies" ] && [ -e "$DEFAULT_DIR/Cookies" ] && move_pair "$DEFAULT_DIR" "$PARK/$to"
    [ -n "$from" ] && [ -e "$PARK/$from/Cookies" ] && [ ! -e "$DEFAULT_DIR/Cookies" ] && move_pair "$PARK/$from" "$DEFAULT_DIR"
  fi
  # Something at both ends of a move: Claude, opened in the meantime, made the one in its own
  # folder (it writes nowhere else). If that's the destination, the move hadn't been made.
  while IFS=$'\t' read -r src dst; do
    if [ -e "$src" ] && [ -e "$dst" ]; then
      [ -n "$b" ] || b=$(backup_dir cut-off-switch); n=$((n+1))
      if [[ "$dst" == "$DEFAULT_DIR/"* ]]; then mv -f "$dst" "$b/$n-${dst##*/}"; continue; fi
      mv -f "$src" "$b/$n-${src##*/}"
    fi
    if [ -e "$dst" ]; then mv -f "$dst" "$src"; fi
  done < <(sed 1d "$SWAPPING" | grep -vx back | tail -r)
  [ $n -gt 0 ] && log "recover: Claude was opened during the cut-off switch; what it made is kept in ${b#$DIR/}"
  rm -f "$SWAPPING"
  [ -n "$(default_pids)" ] || link_sessions "$from"
  log "recover: a switch from $(account_field "$from" name) to $(account_field "$to" name) was cut off; put $(account_field "$from" name)'s sign-in back"
  [ -n "$was" ] && open_app
  return 0
}

# The daily 04:30 keep-alive job. Replaces one installed under the old label.
cmd_install_keepalive() {
  local agents="$HOME/Library/LaunchAgents" uid; uid=$(id -u); mkdir -p "$agents"
  if [ -f "$agents/$OLD_LABEL.keepalive.plist" ]; then
    launchctl bootout "gui/$uid/$OLD_LABEL.keepalive" 2>/dev/null
    rm -f "$agents/$OLD_LABEL.keepalive.plist" && log "keepalive: removed the job under the old label $OLD_LABEL.keepalive"
  fi
  local plist="$agents/$LABEL.keepalive.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL.keepalive</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DIR/relay.sh</string><string>keepalive</string><string>27</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
</dict></plist>
EOF
  launchctl bootout "gui/$uid/$LABEL.keepalive" 2>/dev/null
  launchctl bootstrap "gui/$uid" "$plist" && log "keepalive: daily check installed (04:30)"
}

# ---- Terminal claude -----------------------------------------------------------------------
#
# Terminal `claude` follows the app. Its login is the Keychain item "Claude Code-credentials"
# (mirrored in ~/.claude/.credentials.json) and its account in ~/.claude.json's oauthAccount.
# The login of an account not in use is parked in its own Keychain item (service
# "desktop-account-switcher-cli", account = accountUuid), never in a file; its oauthAccount record (no
# secret) in park/<uuid>/oauthAccount.json. A swap first saves the live login to the outgoing
# account's park, so the parked copy is always the newest (refresh tokens rotate; replaying a
# stale one can revoke the family). Values go Keychain to Keychain through `security -i` on
# stdin as hex: never printed, logged, or put on a command line.
CLI_SVC="Claude Code-credentials"
CLI_PARK_SVC="desktop-account-switcher-cli"
CLI_MIRROR="$HOME/.claude/.credentials.json"
cli_account() { jq -r '.oauthAccount.accountUuid // empty' "$HOME/.claude.json" 2>/dev/null; }
keychain_put() {   # keychain_put <service> <account>, the secret on stdin
  local v hex; v=$(cat)   # $(...) drops the newline `security -w` adds after the value
  [ -n "$v" ] || return 1
  hex=$(printf '%s' "$v" | xxd -p | tr -d '\n'); v=""
  printf 'add-generic-password -U -s "%s" -a "%s" -X %s\n' "$1" "$2" "$hex" | security -i >/dev/null 2>&1
}
# Write the secret on stdin to the file $1, which only you can read, in one move, so nothing
# reading it (a running claude) ever sees half of it. An empty secret is never written.
secret_file() {
  local tmp="$1.tmp.$$"
  if ( umask 077; cat > "$tmp" ) && [ -s "$tmp" ]; then mv -f "$tmp" "$1"; else rm -f "$tmp"; return 1; fi
}
# Where the logins are. On a Mac the Keychain, as above. Linux has none: the live login is the
# file ~/.claude/.credentials.json (0600), and an account's parked one is
# park/<uuid>/credentials.json, 0600 like the live one beside it. Each prints a login on
# stdout or takes one on stdin; nothing else ever sees one.
if [ -n "$LINUX" ]; then
  live_login() { cat "$CLI_MIRROR" 2>/dev/null; }
  live_has() { [ -s "$CLI_MIRROR" ]; }
  live_store() { mkdir -p "$(dirname "$CLI_MIRROR")"; secret_file "$CLI_MIRROR"; }
  parked_login() { cat "$PARK/$1/credentials.json" 2>/dev/null; }
  cli_parked() { [ -s "$PARK/$1/credentials.json" ]; }
  parked_store() { mkdir -p "$PARK/$1"; chmod 700 "$PARK" "$PARK/$1"; secret_file "$PARK/$1/credentials.json"; }
  parked_drop() { rm -f "$PARK/$1/credentials.json"; }
else
  live_login() { security find-generic-password -s "$CLI_SVC" -a "$USER" -w 2>/dev/null; }
  live_has() { security find-generic-password -s "$CLI_SVC" -a "$USER" >/dev/null 2>&1; }
  live_store() {   # the Keychain item, and its mirror file where claude keeps one
    local v; v=$(cat); [ -n "$v" ] || return 1
    printf '%s' "$v" | keychain_put "$CLI_SVC" "$USER" || return 1
    [ -f "$CLI_MIRROR" ] && printf '%s\n' "$v" | secret_file "$CLI_MIRROR"
    return 0
  }
  parked_login() { security find-generic-password -s "$CLI_PARK_SVC" -a "$1" -w 2>/dev/null; }
  cli_parked() { security find-generic-password -s "$CLI_PARK_SVC" -a "$1" >/dev/null 2>&1; }
  parked_store() { keychain_put "$CLI_PARK_SVC" "$1"; }
  parked_drop() { security delete-generic-password -s "$CLI_PARK_SVC" -a "$1" >/dev/null 2>&1; }
fi
cli_park() {       # save the live terminal login as <uuid>'s parked one
  local id="$1" other live
  # The live login byte for byte the same as another account's parked one means the live
  # login is that account's token while ~/.claude.json says <uuid>: parking it would put
  # the wrong account's login under <uuid>.
  live=$(live_login | sha)
  for other in $(account_ids); do
    [ "$other" = "$id" ] && continue
    if cli_parked "$other" && [ "$(parked_login "$other" | sha)" = "$live" ]; then
      log "terminal: the live terminal login is the same as $(account_field "$other" name)'s parked one, not $(account_field "$id" name)'s; not parking it as $(account_field "$id" name)"
      return 1
    fi
  done
  live_login | parked_store "$id" || return 1
  mkdir -p "$PARK/$id"; jq '.oauthAccount' "$HOME/.claude.json" > "$PARK/$id/oauthAccount.json"
  cli_dead "$id" && jq_write "$STATE" --arg a "$id" 'del(.cliDead[$a])'
  return 0
}
cli_restore() {    # make <uuid>'s parked login the live terminal login
  local id="$1"
  parked_login "$id" | live_store || return 1
  [ -f "$PARK/$id/oauthAccount.json" ] && jq_write "$HOME/.claude.json" --slurpfile o "$PARK/$id/oauthAccount.json" '.oauthAccount = $o[0]'
}
# Move terminal claude to <uuid> if a parked login exists for it; otherwise leave it alone
# and return 1, so a caller that says it moved is telling the truth.
# Terminal logins move one at a time (a switch moving it, and a terminal limit moving it too).
swap_cli() { locked "$DIR/cli.lock" swap_cli_now "$@"; }
swap_cli_now() {
  local target="$1" cur; cur=$(cli_account)
  [ "$cur" = "$target" ] && return 0
  if ! cli_parked "$target"; then log "terminal: no parked terminal login for $(account_field "$target" name); terminal stays on $(account_field "$cur" name)"; return 1; fi
  if cli_dead "$target"; then log "terminal: $(account_field "$target" name)'s parked terminal login no longer works (relay.sh cli-login $(account_field "$target" name)); terminal stays on $(account_field "$cur" name)"; return 1; fi
  # With no live login there's nothing to save first (logged out, or the item was deleted).
  if [ -n "$cur" ] && live_has && ! cli_park "$cur"; then
    log "terminal: couldn't save $(account_field "$cur" name)'s terminal login; not swapping"; return 1
  fi
  cli_restore "$target" && log "terminal: $(account_field "$cur" name) -> $(account_field "$target" name)" \
    && swap_rc_pointers "$cur" "$target"
}
# After the app moved: terminal claude follows, and with it everything that runs the real claude
# on this login (Sesame Link, LearnHarness, ...), running sessions included: claude reads the
# login again on its next request. With no parked login, say how to make one. With one that no
# longer works, only a new sign-in can move the terminal, so open one.
cli_follow() {
  local id="$1" name; name=$(account_field "$id" name)
  swap_cli "$id" && return 0
  if cli_dead "$id"; then
    notify "Terminal claude stayed on $(account_field "$(cli_account)" name): $name's terminal login no longer works. Sign in from the Terminal window that just opened."
    cli_signin_window "$id"
  elif ! cli_parked "$id"; then
    notify "Terminal claude stayed on $(account_field "$(cli_account)" name). Run relay.sh cli-login $name once so it follows the app."
  fi
  return 0
}
# A Terminal window on cli-login, which needs one click in the browser and leaves the terminal on
# the app's account.
cli_signin_window() {
  [ -n "$LINUX" ] && return 0   # no windows on a server: the notification says what to run
  local name f="$DIR/cli-login.command"; name=$(account_field "$1" name)
  printf '#!/bin/bash\nexec /bin/bash %q cli-login %q\n' "$DIR/relay.sh" "$name" > "$f"; chmod +x "$f"
  log "terminal: opening a sign-in window for $name's terminal login"
  open "$f" || log "terminal: couldn't open the sign-in window; run relay.sh cli-login $name"
}
# Keep the live login's parked copy current, so a `/login` by hand, which replaces the live login
# without parking it, can't lose the outgoing account's newest copy. A login being written has
# its token in the Keychain a moment before ~/.claude.json names its account, so both must hold
# still across a few seconds before anything is parked.
cli_keep_parked() {
  local id live; id=$(cli_account); [ -n "$(account_field "$id" name)" ] || return 0
  live=$(live_login | sha)
  [ "$live" != "$(printf '' | sha)" ] || return 0
  [ "$live" != "$(parked_login "$id" | sha)" ] || return 0
  pause 3
  [ "$(cli_account)" = "$id" ] && [ "$(live_login | sha)" = "$live" ] || return 0
  locked "$DIR/cli.lock" cli_park "$id"
}
# Terminal `claude rc` keeps, per project folder, the session it reattaches on its next start
# (~/.claude/projects/<folder>/bridge-pointer.json). That session is the terminal account's;
# on another account the reattach finds nothing and rc starts with no session at all. So a
# terminal move parks the outgoing account's pointers (park/<uuid>/rc-pointers/) and puts the
# incoming account's back; a folder it has none for keeps its environment and forgets the
# session, so rc makes a new one. A folder being served right now is left alone.
RC_POINTERS="$HOME/.claude/projects"
swap_rc_pointers() {   # swap_rc_pointers <from uuid or ""> <to uuid>
  local from="$1" to="$2" p key pid saved n=0
  for p in "$RC_POINTERS"/*/bridge-pointer.json; do
    [ -f "$p" ] || continue
    key=$(basename "$(dirname "$p")"); pid=$(jq -r '.pid // empty' "$p" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= | grep -q 'claude'; then
      log "remote control: $key is being served now; its pointer stays"; continue
    fi
    [ -n "$from" ] && { mkdir -p "$PARK/$from/rc-pointers"; cp -p "$p" "$PARK/$from/rc-pointers/$key.json"; }
    saved="$PARK/$to/rc-pointers/$key.json"
    if [ -f "$saved" ]; then cp -p "$saved" "$p"
    else jq_write "$p" '.sessionId = "" | with_entries(select(.key | test("SessionIds") | not))'; fi
    n=$((n+1))
  done
  # Folders the incoming account served before that have no pointer now.
  for saved in "$PARK/$to/rc-pointers"/*.json; do
    [ -f "$saved" ] || continue
    key=$(basename "$saved" .json)
    [ -d "$RC_POINTERS/$key" ] && [ ! -e "$RC_POINTERS/$key/bridge-pointer.json" ] && cp -p "$saved" "$RC_POINTERS/$key/bridge-pointer.json" && n=$((n+1))
  done
  [ "$n" -gt 0 ] && log "remote control: $n terminal rc pointer(s) moved to $(account_field "$to" name)"
  return 0
}
# Save the live terminal login as its account's parked copy (run once per account after `claude /login`).
cmd_cli_save() {
  local cur; cur=$(cli_account); [ -n "$(account_field "$cur" name)" ] || die "terminal is logged in as ${cur:-nobody}, not an account in accounts.json"
  locked "$DIR/cli.lock" cli_park "$cur" && log "terminal: saved $(account_field "$cur" name)'s terminal login" && echo "saved $(account_field "$cur" name)'s terminal login"
}
cmd_cli_use() {
  local id; id=$(account_by_name "${1:-}"); [ -n "$id" ] || die "cli-use: no account named ${1:-}"
  swap_cli "$id" || { echo "terminal claude stays on $(account_field "$(cli_account)" name): see $LOG" >&2; return 1; }
  echo "terminal claude is on $(account_field "$(cli_account)" name)"
}
# Give <name> a parked terminal login: save the live one, run `claude auth login` for <name>,
# park what it signed in to if that's <name>, and leave the terminal on the app's account, so
# from then on the terminal follows the app to <name> too. Signing in to anyone else puts the
# previous terminal login back.
cmd_cli_login() {
  local id name email cur got app; id=$(account_by_name "${1:-}"); [ -n "$id" ] || die "cli-login: no account named ${1:-}"
  name=$(account_field "$id" name); email=$(account_field "$id" email); cur=$(cli_account)
  if [ -n "$cur" ] && live_has; then
    [ -n "$(account_field "$cur" name)" ] || die "cli-login: terminal claude is logged in as $cur, not an account in accounts.json; signing in would lose that login"
    [ "$cur" = "$id" ] || locked "$DIR/cli.lock" cli_park "$cur" || die "cli-login: couldn't save $(account_field "$cur" name)'s terminal login; not signing in"
  fi
  echo "Sign in as $name${email:+ ($email)} in the browser that opens."
  log "terminal: signing terminal claude in as $name"
  if ! claude auth login --claudeai ${email:+--email "$email"}; then
    cli_put_back "$cur" "$id"
    die "cli-login: the sign-in to $name didn't finish; terminal claude is on $(account_field "$(cli_account)" name)"
  fi
  got=$(cli_account)
  if [ "$got" != "$id" ]; then
    local who; who=$(account_field "$got" name); who=${who:-${got:-nobody}}
    cli_put_back "$cur" "$id"
    die "cli-login: that sign-in was $who, not $name; terminal claude is on $(account_field "$(cli_account)" name). Your browser approves whichever account it's signed in to: switch it to $name at claude.ai (or copy the sign-in link into a browser signed in as $name), then run this again."
  fi
  locked "$DIR/cli.lock" cli_park "$id" || die "cli-login: signed in as $name, but couldn't park that login"
  log "terminal: parked $name's terminal login"
  # Back where it was (its rc pointers never left that account), then on to the app's account.
  cli_put_back "$cur" "$id"
  app=$(folder_account "$DEFAULT_DIR")
  [ -n "$app" ] && [ "$app" != "$(cli_account)" ] && cli_parked "$app" && swap_cli "$app"
  echo "$name has a terminal login now; terminal claude is on $(account_field "$(cli_account)" name) and follows the app"
}
# Put <uuid>'s parked terminal login back after a cli-login for <other uuid> that didn't take.
cli_put_back() { [ -n "$1" ] && [ "$1" != "$2" ] && cli_parked "$1" && locked "$DIR/cli.lock" cli_restore "$1"; }
# A terminal run hit the limit: cool that account down and move only the terminal login.
cmd_cli_switch() {
  local from; from=$(cli_account); [ -n "$from" ] || die "cli-switch: terminal isn't logged in"
  # A limit a session hit shows in its account's usage. If the terminal's account reads as
  # having usage left, it isn't the one that ran out: another session's limit already moved the
  # terminal off that account (several hit it together), or the failure wasn't a usage limit.
  # Cooling it down and moving on would spend the next account for nothing. Where usage can't
  # be read, the session is taken at its word.
  # --unsure (from the mod): the session couldn't tell whether its failure was a usage limit,
  # so nothing moves unless the reading says so.
  local kind="" label="" unsure=""
  [ "${1:-}" = --unsure ] && { unsure=1; shift; }
  if usage_read "$from"; then
    IFS=$'\t' read -r kind label _ <<< "$(watch_state "$from" 95)"
    case "$kind" in out|scoped|near) ;; *)
      log "terminal: a session hit a limit, but $(account_field "$from" name), which terminal claude is on now, has usage left; not switching"; return 0 ;;
    esac
  elif [ -n "$unsure" ]; then
    log "terminal: a session's request was refused, maybe for a usage limit, and $(account_field "$from" name)'s usage can't be read; not switching"; return 0
  fi
  # Cooling down until the reset the session reported, else the one the reading gives.
  local until="${1:-}"
  [ -z "$until" ] && [ "$kind" = out ] && until="$label"
  [ -n "$until" ] || until=$(in_5h)
  [ "$kind" = scoped ] || label=""
  jq_write "$STATE" --arg a "$from" --arg u "$until" '.cooldowns[$a] = $u | del(.pinned)'
  # Only accounts with a parked terminal login: the terminal can't move to any other.
  local ready target=""; ready=$(cli_ready)
  [ -n "$ready" ] && target=$(pick_target "$from" "$label" "$ready")
  [ -n "${target:-}" ] || { log "terminal: $(account_field "$from" name) is out, and no other account with a parked terminal login has usage and isn't benched"; notify "Terminal: every account with a terminal login is out of usage or benched."; return 1; }
  swap_cli "$target"
}

# Run a scripted claude, and if it fails on a usage limit, move the terminal login to the
# next account and run it once more (after caam's `run`). Output passes through unchanged.
#   relay.sh run -- -p "prompt" [claude args...]
cmd_run() {
  [ "${1:-}" = "--" ] && shift
  local rc; RUN_OUT=$(mktemp "${TMPDIR:-/tmp}/relay-run.XXXXXX")   # on_exit removes it, however this ends
  # stdout and stderr each stay where they were, and both are copied to the file for the check.
  claude "$@" 2> >(tee -a "$RUN_OUT" >&2) | tee -a "$RUN_OUT"; rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ] && grep -qiE "hit your( weekly| 5-hour)? limit|usage[ _]limit[ _]reached|out of (extra )?usage" "$RUN_OUT"; then
    log "run: claude hit a limit on $(account_field "$(cli_account)" name)'s terminal login; switching and retrying once"
    local moved=""
    if [ -n "$LINUX" ]; then lock_wait run "$LOCK_WAIT" && { cmd_cli_switch && moved=1; lock_release; }
    else cmd_cli_switch && moved=1; fi
    if [ -n "$moved" ]; then claude "$@"; rc=$?; fi
  fi
  return "$rc"
}

# A parked terminal login isn't used, so its access token (good for about 8 hours) runs out:
# its account's usage can't be read live after that, and a login left unused long enough may
# stop working. To renew one (after caam's keepalive), the real claude runs one tiny prompt in a
# throwaway home holding only that login, as a file: with HOME there, claude finds no login
# Keychain, keeps its login in ~/.claude/.credentials.json and renews it in that file, never
# touching the live terminal login. Whatever it leaves is parked again, renewed or not, so the
# parked copy stays the newest (renewing rotates the refresh token). Under cli.lock, so no
# terminal move puts the parked copy live halfway. The prompt is a few tokens of Haiku on that
# account; one at a limit is renewed all the same, as claude renews before it asks.
RENEW_HOME="$DIR/cli-renew"
RENEW_EVERY=3600   # seconds between tries for one account, renewed or not
cli_expires() {    # cli_expires <uuid>: its parked terminal login's access token expiry (epoch), or nothing
  parked_login "$1" | jq -r '(.claudeAiOauth.expiresAt // empty) / 1000 | floor' 2>/dev/null
}
# Due: parked, not the live one (claude renews that itself), expired or within 30 minutes of
# it, and not tried in the last hour.
cli_renew_due() {
  local exp; [ "$(cli_account)" != "$1" ] && cli_parked "$1" && ! cli_dead "$1" || return 1
  exp=$(cli_expires "$1"); [ -n "$exp" ] && [ "$exp" -lt $(( $(date +%s) + 1800 )) ] || return 1
  [ $(( $(date +%s) - $(jq -r --arg a "$1" '.cliRenewTriedAt[$a] // 0' "$STATE") )) -ge "$RENEW_EVERY" ]
}
# A parked login claude couldn't renew because it no longer works: its refresh token was used
# by something else after it was parked (a claude still running on that account when the
# terminal moved, or another tool holding a copy), which revokes the copy here. Marked in
# state.json (cliDead) so no terminal move puts it live, until cli-login parks a new one.
cli_dead() { jq -e --arg a "$1" '.cliDead[$a] // empty' "$STATE" >/dev/null 2>&1; }
# cli_renew <uuid>: 0 renewed, 1 not renewed, 2 nothing to renew.
cli_renew() { locked "$DIR/cli.lock" cli_renew_now "$@"; }
cli_renew_now() {
  local id="$1" name before after h="$RENEW_HOME" f="$RENEW_HOME/.claude/.credentials.json"
  name=$(account_field "$id" name)
  [ "$(cli_account)" != "$id" ] && cli_parked "$id" || return 2
  before=$(cli_expires "$id")
  [ -n "$before" ] || { log "terminal: $name's parked terminal login isn't a claude.ai login; not renewing it"; return 2; }
  jq_write "$STATE" --arg a "$id" --argjson t "$(date +%s)" '.cliRenewTriedAt[$a] = $t'
  rm -rf "$h"; mkdir -p "$h/.claude" "$h/work"; chmod 700 "$h"
  ( umask 077; parked_login "$id" > "$f" )
  local out; out=$(cd "$h/work" && run_for 120 env -i HOME="$h" USER="$USER" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 \
      claude -p "Reply with the word ok." --model haiku --max-turns 1 --tools "" --strict-mcp-config --no-session-persistence 2>&1)
  # What claude left is the newest copy: park it if it changed and is still a login.
  local tok='.claudeAiOauth | "\(.refreshToken) \(.expiresAt)"'
  if jq -e '.claudeAiOauth.refreshToken' "$f" >/dev/null 2>&1 \
    && [ "$(jq -r "$tok" "$f" | sha)" != "$(parked_login "$id" | jq -r "$tok" 2>/dev/null | sha)" ]; then
    parked_store "$id" < "$f" || log "terminal: couldn't park $name's renewed terminal login"
  fi
  rm -rf "$h"
  after=$(cli_expires "$id")
  if [ "${after:-0}" -gt "$before" ]; then jq_write "$STATE" --arg a "$id" 'del(.cliDead[$a])'; log "terminal: renewed $name's parked terminal login, good until $(utc_at "$after") UTC"; return 0; fi
  out=$(printf '%s' "$out" | tr -s '\n' ' ' | cut -c1-200)
  if printf '%s' "$out" | grep -qiE 'revoked|invalid_grant|invalid.*(refresh|token)|log ?in again|/login'; then
    jq_write "$STATE" --arg a "$id" --argjson t "$(date +%s)" '.cliDead[$a] = $t'
    log "terminal: $name's parked terminal login no longer works ($out); terminal claude won't move to it until relay.sh cli-login $name"
    notify "$name's terminal login no longer works. Run relay.sh cli-login $name in a terminal."
    CLI_SIGNIN_DUE+=" $id"
    return 1
  fi
  log "terminal: $name's parked terminal login wasn't renewed (it ran out $(utc_at "$before") UTC): $out"; return 1
}
# relay.sh cli-renew [<name>...] [--force]: renew parked terminal logins that are due (all
# parked ones but the live one, or the ones named); --force ignores when each was last tried.
cmd_cli_renew() {
  local force="" names=() a id ids=""
  for a in "$@"; do case "$a" in --force) force=1 ;; *) names+=("$a") ;; esac; done
  if [ ${#names[@]} -gt 0 ]; then
    for a in "${names[@]}"; do id=$(account_by_name "$a"); [ -n "$id" ] || die "cli-renew: no account named $a"; ids+="$id "; done
  else ids=$(account_ids); fi
  for id in $ids; do
    local name; name=$(account_field "$id" name)
    if [ "$(cli_account)" = "$id" ]; then echo "$name: terminal claude is on it; claude renews it itself"; continue; fi
    cli_parked "$id" || { echo "$name: no parked terminal login (relay.sh cli-login $name)"; continue; }
    if cli_dead "$id" && [ -z "$force" ]; then echo "$name: its parked terminal login no longer works: relay.sh cli-login $name (or --force to try again)"; continue; fi
    [ -n "$force" ] && jq_write "$STATE" --arg a "$id" 'del(.cliRenewTriedAt[$a])'
    local exp; exp=$(cli_expires "$id")
    [ -n "$exp" ] || { echo "$name: its parked terminal login isn't a claude.ai login"; continue; }
    if [ -z "$force" ] && ! cli_renew_due "$id"; then
      if [ "$exp" -ge $(( $(date +%s) + 1800 )) ]; then echo "$name: good until $(utc_at "$exp") UTC"
      else echo "$name: tried in the last hour; --force to try again"; fi
      continue
    fi
    cli_renew "$id"
    case $? in
      0) echo "$name: renewed, good until $(utc_at "$(cli_expires "$id")") UTC" ;;
      1) if cli_dead "$id"; then echo "$name: its parked terminal login no longer works: relay.sh cli-login $name"; else echo "$name: not renewed; see $LOG"; fi ;;
      *) echo "$name: nothing to renew" ;;
    esac
  done
}
# Renew every parked terminal login that's due (from usage --renew and the daily keep-alive), and
# ask for a new sign-in as soon as one is found dead, so it's ready before the next switch needs it.
CLI_SIGNIN_DUE=""
cli_renew_all() {
  local id
  cli_keep_parked
  for id in $(account_ids); do cli_renew_due "$id" && cli_renew "$id"; done
  for id in $CLI_SIGNIN_DUE; do cli_signin_window "$id"; done
  return 0
}
# What else uses the terminal login. Anything that runs the real claude on it follows a move by
# itself. Two kinds don't: a process given its own login (CLAUDE_CODE_OAUTH_TOKEN,
# CLAUDE_CONFIG_DIR) stays on that account, and an app that keeps its own copy of the login can
# renew that copy after the terminal moved, which spends the parked one and revokes it. Prints
# one "ok|~~|!! text" line each. Environment values never leave this function: names only.
cli_consumers() {
  local c="$HOME/.config/codexbar/config.json" src pid env pinned=""
  if [ -f "$c" ]; then
    src=$(jq -r '.providers[]? | select(.id == "claude") | if .enabled == false then "off" else (.source // "auto") end' "$c" 2>/dev/null)
    case "$src" in
      oauth|auto) echo "!! CodexBar keeps its own copy of the terminal login (Claude source: $src), which revokes parked logins: set its Claude source to CLI" ;;
      "") ;;
      *) echo "ok CodexBar holds no copy of the terminal login (Claude source: $src)" ;;
    esac
  fi
  for pid in $(pgrep -x claude 2>/dev/null); do
    if [ -n "$LINUX" ]; then env=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null); else env=$(ps -E -p "$pid" -o command= 2>/dev/null | tr ' ' '\n'); fi
    env=$(printf '%s\n' "$env" | grep -oE '^(CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CONFIG_DIR|CLAUDE_CODE_ENTRYPOINT=claude-desktop)' | tr '\n' ' ')
    case "$env" in *claude-desktop*) continue ;; *CLAUDE_*) pinned+=" $pid" ;; esac
  done
  [ -z "$pinned" ] || echo "~~ claude process(es)$pinned have a login of their own and won't follow a switch"
  [ -f "$CLI_MIRROR" ] && echo "ok running terminal claude follows a move on its next request" \
    || echo "~~ no $CLI_MIRROR: running terminal claude takes up to a minute to follow a move"
}

# ---- Looking at it -----------------------------------------------------------------------------

# Check the whole setup (after caam's doctor). Prints ok / ~~ (a warning) / !! per check; exits 1 if any failed.
cmd_doctor() {
  local bad=0
  ok()   { echo "ok  $*"; }
  warn() { echo "~~  $*"; }
  fail() { echo "!!  $*"; bad=1; }
  local v why; v=$(app_version)
  if [ -z "$v" ]; then fail "Claude Desktop isn't in $APP"
  elif version_tested; then ok "Claude Desktop $v"
  else warn "Claude Desktop $v hasn't been tested with this switcher (tested: $TESTED_VERSIONS); switches still check the app's files first"; fi
  if update_waiting || shipit_running; then ok "a Claude update is downloaded and installs at the next quit (a switch or restart lets it finish first)"; fi
  why=$(check_app) && ok "Claude's sign-in and session files are where the switcher expects" || fail "Claude's files aren't where the switcher expects ($why): switching is off until this is fixed"
  [ -z "$why" ] && ! signed_in_now && warn "Claude is signed out of $(account_field "$(folder_account "$DEFAULT_DIR")" name): sign in in Claude, or switch to another account (relay.sh use <name>)"
  [ -L "$DIR/relay.sh" ] && [ -e "$DIR/relay.sh" ] && ok "relay.sh -> $(readlink "$DIR/relay.sh")" || fail "$DIR/relay.sh is not a working link (relay.sh setup)"
  [ -L "$DIR/mod" ] && [ -e "$DIR/mod/hooks/hooks.json" ] && ok "mod -> $(readlink "$DIR/mod")" || fail "$DIR/mod is not a working link (relay.sh setup)"
  jq -e --arg p "$PLUGIN" '.enabledPlugins[$p] == true' "$HOME/.claude/settings.json" >/dev/null 2>&1 && ok "mod installed and enabled" || fail "mod not enabled (relay.sh setup)"
  local n; n=$(jq '[.accounts[] | select(.accountUuid and .orgUuid and .name)] | length' "$ACCOUNTS" 2>/dev/null || echo 0)
  [ "$n" -ge 2 ] && ok "$n accounts in accounts.json" || fail "$n account(s) in accounts.json; add another with relay.sh add <name>"
  local cur; cur=$(folder_account "$DEFAULT_DIR")
  [ -n "$(account_field "$cur" name)" ] && ok "Claude is signed in as $(account_field "$cur" name)" || fail "Claude is signed in as ${cur:-nobody}, which isn't in accounts.json"
  local id now; now=$(date -u +%s)
  for id in $(account_ids); do benched "$id" && ok "$(account_field "$id" name) is benched: automatic switches skip it (relay.sh unbench $(account_field "$id" name))"; done
  [ "$n" -ge 2 ] && [ -n "$(bench_note)" ] && warn "$(bench_note)"
  for id in $(account_ids); do
    [ "$id" = "$cur" ] && continue
    local exp; exp=$(signin_expires_epoch "$id")
    if [ "$exp" -gt "$now" ]; then ok "$(account_field "$id" name) parked, $(( (exp - now) / 86400 )) days left"
    else fail "$(account_field "$id" name) has no live parked sign-in (relay.sh signin $(account_field "$id" name))"; fi
  done
  local pids; pids=$(default_pids | wc -l | tr -d ' ')
  [ "$pids" -le 1 ] && ok "$pids Claude window(s) on the profile folder" || fail "$pids Claude windows on one profile folder: quit all but one"
  local kind canon d pair
  for kind in claude-code-sessions local-agent-mode-sessions; do
    canon=$(shared_list "$kind")
    for d in "$DEFAULT_DIR/$kind"/*/*; do
      [ -d "$d" ] && [ ! -L "$d" ] || continue; case "$d" in *.merged-*) continue ;; esac
      case "$(basename "$(dirname "$d")")" in ????????-????-????-????-????????????) ;; *) continue ;; esac   # account folders only
      pair="$(basename "$(dirname "$d")" | cut -c1-8)/$(basename "$d" | cut -c1-8)"
      if [ -z "$canon" ] || [ "$d" = "$canon" ]; then ok "$kind: shared list $pair"
      else fail "$kind: $pair is a session list of its own, not linked to the shared one (relay.sh restart links it)"; fi
    done
    [ -n "$canon" ] && [ ! -d "$canon" ] && fail "$kind: link points at a missing folder $canon"
    for id in $(jq -r '.accounts[] | select((.orgUuid // "") != "") | .accountUuid // empty' "$ACCOUNTS"); do
      [ -n "$canon" ] && [ ! -e "$DEFAULT_DIR/$kind/$id/$(account_field "$id" orgUuid)" ] && fail "$kind: $(account_field "$id" name) has no link to the shared list (relay.sh restart adds it)"
    done
    [ -n "$canon" ] && [ -L "$DEFAULT_DIR/$kind/$cur/$(account_field "$cur" orgUuid)" ] \
      && fail "$kind: $(account_field "$cur" name)'s list is a link, and Claude saves no session there (relay.sh restart moves the shared list to it)"
  done
  local tcur; tcur=$(cli_account)
  if [ -z "$tcur" ]; then warn "terminal claude isn't logged in; it won't follow the app"
  else
    [ -n "$(account_field "$tcur" name)" ] && ok "terminal claude is on $(account_field "$tcur" name)" || fail "terminal claude is on $tcur, not an account in accounts.json"
    for id in $(account_ids); do
      [ "$id" = "$tcur" ] && continue
      if cli_dead "$id"; then fail "$(account_field "$id" name)'s parked terminal login no longer works (used or revoked elsewhere after it was parked), so terminal claude stays put when the app moves to it: relay.sh cli-login $(account_field "$id" name)"
      elif cli_parked "$id"; then ok "$(account_field "$id" name) has a parked terminal login"
      else warn "$(account_field "$id" name) has no parked terminal login, so terminal claude stays put when the app moves to it: relay.sh cli-login $(account_field "$id" name)"; fi
    done
    local line
    while IFS= read -r line; do
      case "$line" in "ok "*) ok "${line#ok }" ;; "~~ "*) warn "${line#\~\~ }" ;; *) fail "${line#!! }" ;; esac
    done < <(cli_consumers)
  fi
  local lost; lost=$(check_sessions)
  [ -z "$lost" ] && ok "no sessions lost from the shared list since the last check" \
    || fail "$(echo "$lost" | grep -c .) session(s) gone from the shared list with no deletion marker: $(echo $lost) (copies may be in $DIR/backups)"
  cmd_usage --quiet
  for id in $(account_ids); do ok "$(account_field "$id" name) usage: $(usage_line "$id") ($(usage_reach "$id"))"; done
  launchctl print "gui/$(id -u)/$LABEL.keepalive" >/dev/null 2>&1 && ok "daily keep-alive installed" || fail "daily keep-alive not installed (relay.sh install-keepalive)"
  if lock_held; then ok "a switch, sign-in or keep-alive is running now ($(lock_owner))"
  else
    [ -d "$LOCK" ] && warn "a lock is left from a run that was cut off ($(lock_owner)); the next switch takes it over" || ok "no switch running"
    # Sign-ins left out of place by a run that was killed; the next use, restart or switch puts them back.
    local r; while IFS= read -r r; do [ -n "$r" ] && fail "$r (relay.sh restart puts it back)"; done < <(recover_signin --check)
  fi
  echo "auto-switch: $(jq -r 'if .armed then "on" else "off" end' "$DIR/config.json" 2>/dev/null || echo off)"
  return $bad
}

# Recent switches and sign-in events, newest last (after caam's history).
cmd_history() {
  grep -E 'swap: [^ ]+ -> |switch: .* is out|signin: |add: |keepalive: .*(renewed|not renewed)|launched relay away|not switching|removed |bench: |terminal: [^ ]+ -> |watch: |update: [0-9a-f]+ -> ' "$LOG" | tail -n "${1:-20}"
}

# An account's last usage reading: from Anthropic (relay.sh usage), or saved by the mod while
# that account is in use (after caam's `limits --cached`). A window past its reset time counts
# as reset.
usage_line() {
  jq -r --arg a "$1" --argjson now "$(date -u +%s)" '
    .[$a] // empty
    | (.windows | map(
        (if .kind == "five_hour" then "5-hour" elif .kind == "seven_day" then "weekly" else (.label // .kind) end) as $k
        | if (.resetsAt // "") != "" and ((.resetsAt | sub("\\.[0-9]+"; "") | sub("[+]00:00$"; "Z") | fromdateiso8601) <= $now)
          then "\($k) reset since" else "\($k) \(.percentUsed | round)%" end) | join(" · "))
      + " · as of \((($now - (.at / 1000)) / 60) | floor)m ago"' "$USAGE" 2>/dev/null | grep . || echo "no reading yet"
}

# ---- Usage from Anthropic -------------------------------------------------------------
#
# Each account's usage windows from api.anthropic.com/api/oauth/usage, read with that account's
# terminal login: the live one for the account terminal claude is on, the parked Keychain copy
# for the others (after Claude Graft's usage monitor). It has windows the app's sessions don't
# report, like a model's own weekly limit ("Fable weekly"). A login whose access token has
# expired is skipped, never renewed: renewing rotates the refresh token, and the parked copy is
# the only one. Its account keeps its last figures. The token goes to curl on stdin (-K -):
# never on a command line, in a log or on screen.
USAGE_EVERY=600     # seconds between checks, unless --force
USAGE_LOCK="$DIR/usage.lock"

# The terminal login of account $1 (JSON on stdout), live or parked.
cli_login() {
  if [ "$(cli_account)" = "$1" ]; then live_login; else parked_login "$1"; fi
}

# Account $1's windows as usage.json holds them, on stdout. Returns 1 when it has no usable
# login, 2 when Anthropic is rate-limiting usage checks, 3 on any other failure.
fetch_usage() {
  local login out code
  login=$(cli_login "$1"); [ -n "$login" ] || return 1
  [ "$(printf '%s' "$login" | jq -r '(.claudeAiOauth.expiresAt // 0) / 1000 | floor' 2>/dev/null || echo 0)" -gt "$(( $(date +%s) + 60 ))" ] || { login=""; return 1; }
  out=$(printf '%s' "$login" | jq -r '"header = \"Authorization: Bearer \(.claudeAiOauth.accessToken)\""' \
    | curl -sS -m 15 -K - -H 'anthropic-beta: oauth-2025-04-20' -H 'Accept: application/json' -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage 2>/dev/null)
  login=""
  code=${out##*$'\n'}; out=${out%$'\n'*}
  [ "$code" = 429 ] && return 2
  [ "$code" = 200 ] || return 3
  printf '%s' "$out" | jq -c '
    def z: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z");
    [ (.five_hour // empty | {kind: "five_hour", percentUsed: .utilization, resetsAt: (.resets_at // "" | z)}),
      (.seven_day // empty | {kind: "seven_day", percentUsed: .utilization, resetsAt: (.resets_at // "" | z)}),
      (.limits[]? | select(.kind == "weekly_scoped")
        | {kind: "weekly_scoped", label: "\(.scope.model.display_name // "scoped") weekly", percentUsed: .percent, resetsAt: (.resets_at // "" | z)}) ]' || return 3
}

# Read account $1's usage from Anthropic into usage.json. Returns what fetch_usage returned;
# on 2, Anthropic is rate-limiting these checks and none is made for 15 minutes.
usage_read() {
  local windows rc; windows=$(fetch_usage "$1"); rc=$?
  case $rc in
    0) jq_write "$USAGE" --arg a "$1" --argjson w "$windows" --argjson at "$(date +%s)000" '.[$a] = {at: $at, source: "anthropic", windows: $w}' ;;
    2) jq_write "$STATE" --argjson t $(( $(date -u +%s) + 900 )) '.usageWaitUntil = $t'
       log "usage: Anthropic is rate-limiting usage checks; next try in 15 minutes" ;;
    3) log "usage: couldn't read $(account_field "$1" name)'s usage from Anthropic" ;;
  esac
  return $rc
}

# Whether account $1's usage can be read from Anthropic now, and if not, why.
usage_reach() {
  local exp; exp=$(cli_login "$1" | jq -r '(.claudeAiOauth.expiresAt // 0) / 1000 | floor' 2>/dev/null)
  if [ -z "$exp" ]; then echo "not read live: no terminal login (relay.sh cli-save)"
  elif [ "$(cli_account)" != "$1" ] && cli_dead "$1"; then echo "not read live: its parked terminal login no longer works (relay.sh cli-login $(account_field "$1" name))"
  elif [ "$exp" -le "$(date +%s)" ]; then echo "not read live: its parked terminal login's token expired $(( ($(date +%s) - exp) / 3600 ))h ago (relay.sh cli-renew)"
  else echo "read live from Anthropic"; fi
}

# relay.sh usage [--force] [--renew]: read every account's usage from Anthropic into usage.json (at
# most every 10 minutes unless --force; after a 429, not before the wait is over), then print it.
# --renew (the mod's background check) first renews parked terminal logins that are due.
cmd_usage() {
  local force="" quiet="" renew="" a
  for a in "$@"; do case "$a" in --force) force=1 ;; --quiet) quiet=1 ;; --renew) renew=1 ;; esac; done
  local now last until; now=$(date -u +%s)
  last=$(jq -r '.usageCheckedAt // 0' "$STATE"); until=$(jq -r '.usageWaitUntil // 0' "$STATE")
  # A check takes 30 seconds at most; a lock older than 2 minutes is left from one that was killed.
  [ -n "$(find "$USAGE_LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$USAGE_LOCK"
  if [ "$now" -lt "$until" ]; then :
  elif { [ -n "$force" ] || [ $((now - last)) -ge $USAGE_EVERY ]; } && mkdir "$USAGE_LOCK" 2>/dev/null; then
    local id
    [ -n "$renew" ] && cli_renew_all
    for id in $(account_ids); do usage_read "$id"; [ $? -eq 2 ] && break; done
    jq_write "$STATE" --argjson t "$now" '.usageCheckedAt = $t'
    rmdir "$USAGE_LOCK"
  fi
  [ -n "$quiet" ] && return 0
  for id in $(account_ids); do echo "$(account_field "$id" name): $(usage_line "$id") ($(usage_reach "$id"))"; done
}

# Sessions that go missing (after Claude Graft's record sweep). Deleting a session in the app
# removes its local_<id>.json and leaves a deleted_<id> marker; a session file gone with no
# marker was lost, by a folder moved out from under the app or its launch sweep (as happened
# once with the second profile's links). seen-sessions.json lists every session seen; each
# check reports the ones lost since, logs them, and forgets them, so each is reported once.
# Copies may be in backups/ (each shared-list change takes one).
SEEN="$DIR/seen-sessions.json"
check_sessions() {
  local kind canon ids lost all_lost=""
  [ -f "$SEEN" ] || echo '{}' > "$SEEN"
  for kind in claude-code-sessions local-agent-mode-sessions; do
    canon=$(shared_list "$kind"); [ -n "$canon" ] && [ -d "$canon" ] || continue
    ids=$(find "$canon" -maxdepth 1 -name 'local_*.json' | sed 's#.*/local_##; s#\.json$##' | sort)
    lost=$(jq -r --arg k "$kind" '.[$k][]?' "$SEEN" | sort | comm -23 - <(printf '%s\n' "$ids") \
      | while read -r id; do [ -n "$id" ] && [ ! -e "$canon/deleted_$id" ] && echo "$id"; done)
    [ -n "$lost" ] && { log "sessions: $kind lost $(echo "$lost" | grep -c .) session(s) with no deletion marker: $(echo $lost)"; all_lost+="$lost"$'\n'; }
    jq_write "$SEEN" --arg k "$kind" --arg ids "$ids" '.[$k] = ($ids | split("\n") | map(select(. != "")))'
  done
  printf '%s' "$all_lost"
}
# Check after Claude has opened and swept its folders.
report_lost() {
  local lost; pause "${1:-0}"; lost=$(check_sessions)
  [ -n "$lost" ] && notify "$(echo "$lost" | grep -c .) session(s) went missing from Claude's list. See relay.sh doctor."
  return 0
}

# Where an account's sign-in is: in Claude now, parked and ready, or nowhere (needs signin).
signin_state() {
  if [ "$(folder_account "$DEFAULT_DIR")" = "$1" ]; then echo "in Claude now"
  elif parked_live "$1"; then echo "parked, ready to switch to (sign-in good until $(signin_expires "$1") UTC)"
  elif [ -n "$(signin_expires "$1")" ]; then echo "parked sign-in ran out on $(signin_expires "$1") UTC (relay.sh signin $(account_field "$1" name))"
  else echo "not signed in (relay.sh signin $(account_field "$1" name))"; fi
}

# Whether account $1 has a parked sign-in that hasn't run out: the only kind a switch can use.
parked_live() { [ "$(signin_cookies "$PARK/$1/Cookies" live)" -ge 1 ] 2>/dev/null; }
# The accounts a switch can go to (one id a line): not the one in Claude, with a live parked
# sign-in, and not among the ids in $1 (ones already tried).
switch_ready() {
  local id on; on=$(folder_account "$DEFAULT_DIR")
  for id in $(account_ids); do
    [ "$id" != "$on" ] && parked_live "$id" && ! printf '%s\n' "${1:-}" | grep -qxF "$id" && echo "$id"
  done
  return 0
}

cmd_status() {
  cmd_usage --quiet
  local pid; pid=$(default_pids | head -1)
  if [ -n "$pid" ]; then echo "Claude: $(app_version), running (pid $pid)"; else echo "Claude: $(app_version), not running"; fi
  if update_waiting || shipit_running; then echo "update: downloaded; installs the next time Claude quits (a switch or restart lets it finish first)"; fi
  echo "auto-switch: $(jq -r 'if .armed then "on" else "off" end' "$DIR/config.json" 2>/dev/null || echo off)"
  echo "terminal claude: on $(account_field "$(cli_account)" name)"
  echo "accounts:"
  local id; for id in $(account_ids); do
    local until; until=$(jq -r --arg a "$id" '.cooldowns[$a] // empty | select(fromdateiso8601 > now)' "$STATE")
    local bench=""; benched "$id" && bench="  (benched: automatic switches skip it)"
    echo "  $(account_field "$id" name)  $(account_field "$id" email)  $(signin_state "$id")${until:+  (out of usage until $until)}$bench"
    echo "      usage: $(usage_line "$id")"
  done
  echo "pending resumes:"; jq -r '.resume[] | "  \(.sessionId)  (\(.reason))"' "$HANDOFF"
}

cmd_plan() {
  parse_args "$@"
  local ready target=""; ready=$(switch_ready)
  [ -n "$ready" ] && target=$(pick_target "$FROM" "$LIMIT" "$ready")
  echo "from:   $(account_field "$FROM" name) ($FROM): $(signin_state "$FROM")${LIMIT:+, out of $LIMIT}"
  if [ -z "$target" ]; then echo "to:     nobody: every other account is cooling down, used up, signed out or benched"; return; fi
  echo "to:     $(account_field "$target" name) ($target): $(signin_state "$target")"
  echo "resume: $(jq -r '[.resume[].sessionId] | join(", ")' "$HANDOFF")"
}

# ---- Switching in place --------------------------------------------------------------
#
# The app's account is its claude.ai sign-in: the Cookies file in its profile folder
# (encrypted with the app's own Keychain key). Everything else in the folder (settings,
# extensions, session lists) stays put. A switch quits Claude, parks the current account's
# Cookies in park/<accountUuid>/, moves the target's in, and opens the same app again. The
# app sees the new sign-in and mints that account's Code tokens itself. Each sign-in is
# moved, never copied, so only one copy of it is ever in use.

# Move a sign-in (Cookies and Cookies-journal, always together: a journal left beside another
# account's Cookies would be rolled into it) from folder $1 to folder $2. Nothing is ever
# overwritten: a sign-in already in $2 goes to backups/<time>-$3 first.
move_pair() {
  local from="$1" to="$2" f b
  [ -e "$from/Cookies" ] || [ -e "$from/Cookies-journal" ] || return 0
  mkdir -p "$to"
  if [ -e "$to/Cookies" ] || [ -e "$to/Cookies-journal" ]; then
    b=$(backup_dir "${3:-replaced-signin}")
    for f in Cookies Cookies-journal; do [ -e "$to/$f" ] && move_noted "$to/$f" "$b/$f"; done
    log "signin: ${to#$DIR/} already held a sign-in; it's kept in ${b#$DIR/}"
  fi
  for f in Cookies Cookies-journal; do [ -e "$from/$f" ] && move_noted "$from/$f" "$to/$f"; done
  return 0
}
# A switch (NOTE_MOVES set) adds each move to swap.inflight before making it.
move_noted() { [ -z "${NOTE_MOVES:-}" ] || printf '%s\t%s\n' "$1" "$2" >> "$SWAPPING"; mv -f "$1" "$2"; }
# A new folder in backups/ (two in the same second each get their own).
backup_dir() { local b="$DIR/backups/$(date +%Y%m%d-%H%M%S)-$1"; [ -e "$b" ] && b="$b-$$-$RANDOM"; mkdir -p "$b"; echo "$b"; }

# Move the sign-in files: park the folder's current ones under $1, bring $2's in.
move_signin() { move_pair "$DEFAULT_DIR" "$PARK/$1"; move_pair "$PARK/$2" "$DEFAULT_DIR"; }

# Everything done while Claude is closed, whatever closed it. $1: the account it opens on
# next, when that isn't the one it reports now (a switch).
while_closed() {
  apply_prefs_patch
  fix_scratch_paths
  drop_old_link
  fill_orgs
  link_sessions "${1:-}"
  apply_sessions_patch
  share_presets
}

# Switch the one Claude window to account $1 (a uuid). Returns 1 if it didn't close Claude
# (nothing to switch to, or the app's files aren't where this expects), and 3, with the
# previous account restored, if the new sign-in didn't come up.
swap_to() {
  local target="$1" cur why; cur=$(folder_account "$DEFAULT_DIR")
  [ "$cur" = "$target" ] && { log "swap: already on $(account_field "$target" name)"; return 0; }
  [ -f "$PARK/$target/Cookies" ] || { log "swap: no parked sign-in for $(account_field "$target" name)"; return 1; }
  parked_live "$target" || { log "swap: $(account_field "$target" name)'s parked sign-in has run out (relay.sh signin $(account_field "$target" name))"; return 1; }
  why=$(check_app) || { log "swap: not switching: $why (Claude Desktop $(app_version) may keep it elsewhere now)"; notify "Not switching: Claude's files changed ($why). Run relay.sh doctor."; return 1; }
  quit_checked || { log "swap: not switching to $(account_field "$target" name): Claude's files changed in an update"; return 1; }
  # From here until the new account is up or the old one is back, a cut-off run is put right
  # (finish_swap): as it's killed, or by the next command.
  echo "$cur $target" > "$SWAPPING"; UNDO="finish_swap open"
  NOTE_MOVES=1 move_signin "$cur" "$target"
  while_closed "$target"
  mirror_prefs "$cur" "$target"
  mirror_rc "$cur" "$target"
  forget_rc_links
  open_app
  # 45 seconds for the new sign-in to come up (ACCOUNT_SWITCHER_FAST: 10, for the tests).
  local n=0 max=45; [ -n "${ACCOUNT_SWITCHER_FAST:-}" ] && max=10
  while [ "$(folder_account "$DEFAULT_DIR")" != "$target" ] && [ $n -lt $max ]; do sleep 1; n=$((n+1)); done
  if [ "$(folder_account "$DEFAULT_DIR")" = "$target" ]; then
    rm -f "$SWAPPING"; UNDO=""
    log "swap: $(account_field "$cur" name) -> $(account_field "$target" name)"
    cli_follow "$target"
    return 0
  fi
  log "swap: $(account_field "$target" name)'s sign-in did not come up; going back to $(account_field "$cur" name)"
  quit_default
  echo back >> "$SWAPPING"
  NOTE_MOVES=1 move_signin "$target" "$cur"
  rm -f "$SWAPPING"; UNDO=""
  link_sessions "$cur"
  open_app
  return 3
}

# List a session to reopen, with why, before Claude closes: the app may bring the session
# back by itself before any link is sent, and the mod only sees entries already written.
# $3 is the account Claude will be on when it reopens; the mod acts on an entry only in a
# session on that account.
hand_off() {
  handoff_write --arg s "$1" --arg r "$2" --arg a "${3:-}" --arg at "$(date -u +%FT%TZ)" \
    '.resume = ([.resume[] | select(.sessionId != $s)] + [{sessionId: $s, cwd: "", reason: $r, account: $a, at: $at}])'
}
drop_hand_off() { handoff_write --arg s "$1" '.resume |= map(select(.sessionId != $s))'; }
# When no switch happened after all: the entries the mod wrote for this usage limit (not yet
# given an account, or given one of the accounts in $2 that the switch then failed to reach),
# and the sessions this run cut off since $1 (an ISO time; reopened on the spent account
# they'd only hit the limit again). Entries an earlier switch gave its account are its own.
drop_limit_hand_offs() {
  handoff_write --arg since "$1" --arg tried "${2:-}" '($tried | split("\n") | map(select(. != ""))) as $t
    | .resume |= map(select(((.reason | test("^(limit hit|mid-turn)")) and (((.account // "") == "") or ((.account // "") as $a | $t | index($a))))
        or (.reason == "closed" and .at >= $since) | not))'
  log "switch: dropped the hand-off entries for this limit"
}

# Reopen the handed-off sessions in the Claude window, after every command that closed Claude
# (--resume or not: sessions cut off mid-turn are listed too). Only those the mod will act on:
# written before Claude was last closed (within 15 minutes), and meant for the account it's
# on now (or for any). Others are left from a switch that went back, or never happened.
reopen_handoff() {
  local ids id; ids=$(handoff_read -r --arg on "$(folder_account "$DEFAULT_DIR")" --argjson now "$(date -u +%s)" '
    def epoch: try (sub("\\.[0-9]+"; "") | sub("[+]00:00$"; "Z") | fromdateiso8601) catch 0;
    ((.closedAt // "") | epoch) as $closed
    | .resume[] | select(((.account // "") == "" or .account == $on) and $closed > 0
        and $closed + 1 >= (.at | epoch) and $now - $closed < 900) | .sessionId')
  # $1: seconds to let the app load first, when there's anything to reopen.
  [ -n "$ids" ] && [ -n "${1:-}" ] && pause "$1"
  for id in $ids; do send_link "claude://resume?session=$id" && log "switch: reopened session $id"; sleep 3; done
  printf '%s' "$ids" | grep -c .
}

cmd_resume() {
  [ -n "$(default_pids)" ] || die "resume: Claude isn't running"
  reopen_handoff >/dev/null
}

# Out of usage: what the mod starts (launch), and what the launchd job runs (switch).
cmd_launch() {
  parse_args "$@"
  [ -n "$FROM" ] || die "launch needs --from"
  RUN_JOB_OVER_LOCK=1 run_job switch --from "$FROM" --resets-at "${RESETS_AT:-}" --limit "${LIMIT:-}"
  case $? in
    0) log "launch: switch away from $FROM queued under launchd" ;;
    # Several sessions hit the limit together, or a switch was already going: the one
    # running reopens the sessions the mod listed, so this is fine, not a failure.
    # The account is still out: its cooldown is kept, so whatever comes next doesn't pick it.
    2) jq_write "$STATE" --arg a "$FROM" --arg u "${RESETS_AT:-$(in_5h)}" '.cooldowns[$a] = $u'
       log "launch: a switch is already under way; not starting another ($(account_field "$FROM" name) cools down until $(jq -r --arg a "$FROM" '.cooldowns[$a]' "$STATE"))" ;;
    *) die "launch: couldn't start the switch under launchd" ;;
  esac
}

cmd_switch() {
  parse_args "$@"
  [ -n "$FROM" ] || die "switch needs --from"

  local since; since=$(date -u +%FT%TZ)

  # One switch at a time, however many sessions hit the limit together. The job only starts
  # when no other relay job runs, so whatever holds the lock is the keep-alive (a minute or
  # so per account): wait for it rather than leave the account spent.
  lock_wait switch 600 || { log "switch: the lock stayed held ($(lock_owner)); not switching"; drop_limit_hand_offs "$since"; exit 1; }
  recover_signin

  local until="${RESETS_AT:-$(in_5h)}"
  jq_write "$STATE" --arg a "$FROM" --arg u "$until" '.cooldowns[$a] = $u'
  log "switch: $(account_field "$FROM" name) is out${LIMIT:+ ($LIMIT)}; cooling down until $until"

  # A trigger that arrives after Claude has left that account (several sessions hit the limit
  # together, or it was switched by hand meanwhile) has nothing to switch away from. Its
  # entries are left as they are: the switch that left reopens what it closed.
  local on; on=$(folder_account "$DEFAULT_DIR")
  if [ -n "$on" ] && [ "$on" != "$FROM" ]; then
    log "switch: Claude is on $(account_field "$on" name) now, not $(account_field "$FROM" name); nothing to do"; exit 0
  fi

  cmd_usage --force --quiet   # pick by the other accounts' figures as of now, where a login allows
  # Each account that's ready (a live parked sign-in, not cooling down, no window used up), in
  # order, until one comes up. One that doesn't is left out and the next is tried.
  local tried="" target ready rc stamp="" said=""
  while :; do
    ready=$(switch_ready "$tried"); target=""
    [ -n "$ready" ] && target=$(pick_target "$FROM" "$LIMIT" "$ready")
    [ -n "$target" ] || break
    # The mod's entries for this limit come back on the account switched to.
    handoff_write --arg t "$target" --arg was "$stamp" '.resume |= map(if (.reason | test("^(limit hit|mid-turn)")) and ((.account // "") == "" or ($was != "" and .account == $was)) then . + {account: $t} else . end)'
    stamp="$target"
    swap_to "$target"; rc=$?
    [ $rc -eq 0 ] && break
    tried+="$target"$'\n'
    if [ $rc -ne 3 ]; then
      drop_limit_hand_offs "$since" "$tried"
      die "could not switch to $(account_field "$target" name); stayed on $(account_field "$FROM" name)"
    fi
    log "switch: trying the next account"; said=1
  done
  if [ -z "$target" ]; then
    drop_limit_hand_offs "$since" "$tried"
    if [ -n "$said" ]; then
      notify "$(account_field "$FROM" name) is out of usage, and no other account's sign-in came up. Run relay.sh doctor."
      die "switch: no other account's sign-in came up; stayed on $(account_field "$FROM" name)"
    fi
    notify "$(account_field "$FROM" name) is out of usage, and every other account is too (or signed out, or benched)."
    die "switch: no account to switch to"
  fi
  jq_write "$STATE" --arg f "$FROM" --arg t "$target" --argjson at "$(date -u +%s)" '.switches += [{from: $f, to: $t, at: $at}] | .switches |= .[-20:]'
  local n; n=$(reopen_handoff 12)   # after letting the app load
  notify "Switched to $(account_field "$target" name). Reopened $n session(s)."
  report_lost
  log "switch: done"
}

# By hand: relay.sh use <name> [--resume <sessionId>].
cmd_swap() {
  local id; id=$(account_by_name "${1:-}"); [ -n "$id" ] || die "use: no account named ${1:-}"
  local session=""; [ "${2:-}" = "--resume" ] && session="${3:-}"
  lock_or_die use
  recover_signin
  pause 10   # let the caller's turn finish before its window quits
  [ -n "$session" ] && hand_off "$session" swap "$id"
  if ! swap_to "$id"; then
    [ -n "$session" ] && drop_hand_off "$session"
    die "switch to ${1} failed; stayed put"
  fi
  reopen_handoff 12 >/dev/null
  report_lost 5
}

# Some app preferences are stored per account (keys holding the account id, or
# "<account>/<org>"). Copy the outgoing account's onto the incoming one, so settings follow
# you across a switch. Only while Claude is closed: the running app rewrites this file.
mirror_prefs() {
  local from="$1" to="$2" fo to_org
  fo=$(account_field "$from" orgUuid); to_org=$(account_field "$to" orgUuid)
  [ -f "$PREFS" ] || return 0
  cp -p "$PREFS" "$DIR/backups/claude_desktop_config.before-mirror.json"
  [ -n "$from" ] && [ -n "$to" ] || return 0
  # An org not known yet (an account just added) is left as it is in the key, never replaced
  # by a placeholder.
  jq_write "$PREFS" --arg f "$from" --arg t "$to" --arg fo "$fo" --arg to "$to_org" '
    walk(if type == "object" then
      . + (to_entries | map(select(.key | contains($f)))
           | map({key: (.key | gsub($f; $t) | if $fo != "" and $to != "" then gsub($fo; $to) else . end), value}) | from_entries)
    else . end)' && log "prefs: $(account_field "$from" name)'s per-account settings copied to $(account_field "$to" name)"
}

# Remote Control's on/off is kept per account (identities["org:account"].serve in
# remote-control-state.json); an account with none starts with it off. Carry the on/off over,
# never the environments, which belong to each account.
# Each session's transcript names the Remote Control link it last had ("bridge-session"
# records), and turning Remote Control on reattaches that link. A link made on another account
# can't be: the switch fails ("Previous session is unavailable") until Claude Code has written
# an empty record, and works on the next try. So while Claude is closed for a switch, write that
# empty record for every session that had a link; turning Remote Control on then starts a new
# link on the new account the first time.
forget_rc_links() {
  local f last sid n=0
  while IFS= read -r f; do
    last=$(grep '"type":"bridge-session"' "$f" | tail -1)
    [ -n "$(printf '%s' "$last" | jq -r '.bridgeSessionId // empty' 2>/dev/null)" ] || continue
    sid=$(printf '%s' "$last" | jq -r '.sessionId // empty' 2>/dev/null); [ -n "$sid" ] || continue
    jq -cn --arg s "$sid" '{type: "bridge-session", sessionId: $s, bridgeSessionId: "", lastSequenceNum: 0}' >> "$f" && n=$((n+1))
  done < <(grep -l '"type":"bridge-session"' "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null)
  # The app keeps its own list of a session's links (bridgeSessionIds) and hands the last one to
  # Claude Code to reattach. find doesn't follow the other accounts' links to the shared list,
  # so each session file is seen once.
  while IFS= read -r f; do
    jq_write "$f" '.bridgeSessionIds = []' && n=$((n+1))
  done < <(find "$DEFAULT_DIR/claude-code-sessions" -name 'local_*.json' -type f -exec grep -l '"bridgeSessionIds": *\[ *"' {} + 2>/dev/null)
  [ "$n" -gt 0 ] && log "remote control: forgot $n Remote Control link record(s); sessions start new links on the new account"
  return 0
}
mirror_rc() {
  local f="$DEFAULT_DIR/remote-control-state.json" fk tk serve
  [ -f "$f" ] || return 0
  # Both keys need the org; one not known yet is left alone.
  [ -n "$(account_field "$1" orgUuid)" ] && [ -n "$(account_field "$2" orgUuid)" ] || return 0
  fk="$(account_field "$1" orgUuid):$1"; tk="$(account_field "$2" orgUuid):$2"
  serve=$(jq -r --arg k "$fk" '.identities[$k].serve // empty' "$f")
  [ -n "$serve" ] || return 0
  [ "$(jq -r --arg k "$tk" '.identities[$k].serve // empty' "$f")" = "$serve" ] && return 0
  cp -p "$f" "$DIR/backups/remote-control-state.before-mirror.json"
  jq_write "$f" --arg k "$tk" --arg s "$serve" '.identities[$k] = ((.identities[$k] // {folders: {}, pendingDelete: [], pendingUnarchive: []}) + {serve: $s})' \
    && log "remote control: $serve on $(account_field "$2" name), as on $(account_field "$1" name)"
}

# The New session picker's saved environments (the app's "session presets": a name, a folder
# or SSH place, a model and settings) are kept per account, in ccd-session-presets.json under
# byAccount[<account>]. Make every account's list the same one. $DIR/presets-shared.json is the
# list as last shared and the accounts that were given it; what one of those accounts' lists
# has changed since then is carried to the others: an environment added, changed (the most
# recently used copy wins) or deleted. An account not given it yet (a new one, with the list
# the app made for it) only adds: what it lacks was never deleted there. The first time, with
# nothing shared yet, that makes the lists one. Two accounts' own environments with the
# same name and place become one (the one already shared, else the most recently used), and the
# sessions started from the other (envScopeId, startedFromEnvironmentId in their records, which
# the sidebar groups by) are pointed at it. Only while Claude is closed: the running app
# rewrites these files.
PRESETS_JQ='
  def key: if (.id | type) == "string" then .id else tojson end;
  def newest: sort_by([-(.v.lastUsedAt // 0), .src]);
  ($base[0].shared // null) as $b
  | ($base[0].accounts // []) as $synced
  | (($b.presets // []) | map({key: key, value: .}) | from_entries) as $bb
  | . as $root
  | [$ids[] | . as $i | $root.byAccount[$i]? | select(. != null) | . + {synced: any($synced[]; . == $i)}] as $cats
  | if ($cats | length) == 0 then {shared: null, moved: {}} else
    ([$cats[] | select(.synced) | [.presets[] | key] as $have | $bb | keys[] | select(. as $k | all($have[]; . != $k))] | unique) as $gone
    | ([$bb | to_entries[] | {k: .key, src: -1, v: .value}]
       + [$cats | to_entries[] | .key as $src | .value.presets[] | {k: key, src: $src, v: .} | select($bb[.k] != .v)]
       | group_by(.k)
       | map(.[0].k as $k | ((map(select(.src >= 0)) | newest | .[0]) // .[0]) | {k: $k, v, src, inbase: ($bb | has($k))})
       | map(select(.k as $k | all($gone[]; . != $k)))) as $all
    | ($all | group_by([.v.name, .v.target]) | map(
        if length < 2 or all(.[]; .inbase) then {keep: ., drop: []}
        elif any(.[]; .inbase) then {keep: map(select(.inbase)), drop: map(select(.inbase | not))}
        elif (map(.src) | unique | length) < 2 then {keep: ., drop: []}
        else newest | {keep: [.[0]], drop: .[1:]} end)) as $groups
    | ([($root.byAccount[$ids[0]].presets // [])[] | key] | to_entries | map({key: .value, value: .key}) | from_entries) as $pos
    | ([$cats[] | select(.synced or $b == null) | select(.builtIns != $b.builtIns) | .builtIns][0] // $b.builtIns) as $bi
    | {shared: ({presets: ([$groups[].keep[]] | sort_by([($pos[.k] // 1e9), -(.v.lastUsedAt // 0)]) | map(.v))}
                + (if $bi != null then {builtIns: $bi} else {} end)
                + (if $b.seededFromDraft == true or any($cats[]; .seededFromDraft == true) then {seededFromDraft: true} else {} end)),
       moved: ($groups | map(.keep[0] as $to | .drop[] | select(.k | test("^[A-Za-z0-9_-]+$")) | {key: .k, value: {to: $to.k, name: ($to.v.name // "")}}) | from_entries)}
  end'
share_presets() {
  local f="$DEFAULT_DIR/ccd-session-presets.json" shared="$DIR/presets-shared.json" plan="$DIR/presets-plan.$$"
  local live ids base n b="" old new name files s moved
  [ -f "$f" ] && [ -f "$ACCOUNTS" ] || return 0
  live=$(folder_account "$DEFAULT_DIR")
  # The account the app last ran as comes first: its list is the one you've been changing.
  ids=$(jq -c --arg l "$live" '[.accounts[].accountUuid // empty] | map(select(. == $l)) + map(select(. != $l))' "$ACCOUNTS") || return 0
  [ "$(jq 'length' <<< "$ids")" -ge 2 ] || return 0
  base="$shared"; [ -s "$base" ] || base=/dev/null
  if ! ( umask 077; jq -c --argjson ids "$ids" --slurpfile base "$base" "$PRESETS_JQ" "$f" > "$plan" ) 2>/dev/null; then
    rm -f "$plan"; log "environments: couldn't read the app's saved environments (ccd-session-presets.json); left as they are"; return 0
  fi
  n=$(jq '.shared.presets | length' "$plan")
  # Nothing saved on any account, or more than the app takes in one list (200).
  if [ "$(jq '.shared == null' "$plan")" = true ]; then rm -f "$plan"; return 0; fi
  if [ "$n" -gt 200 ]; then rm -f "$plan"; log "environments: $n saved environments between the accounts, more than the app keeps in one list (200); left as they are"; return 0; fi
  if jq -e --argjson ids "$ids" --slurpfile p "$plan" --slurpfile base "$base" '. as $r | $base[0].shared == $p[0].shared and all($ids[]; . as $i | $r.byAccount[$i] == $p[0].shared and any($base[0].accounts[]?; . == $i))' "$f" >/dev/null 2>&1; then
    rm -f "$plan"; return 0
  fi
  cp -p "$f" "$DIR/backups/ccd-session-presets.before-share.json"
  while IFS=$'\t' read -r old new name; do
    [ -n "$old" ] && [ -n "$new" ] || continue
    files=$(grep -rlF --include='local_*.json' "$old" "$DEFAULT_DIR/claude-code-sessions/" 2>/dev/null); moved=0
    if [ -n "$files" ]; then
      [ -n "$b" ] || b=$(backup_dir environments)
      while IFS= read -r s; do
        cp -p "$s" "$b/$(basename "$s")"
        sed -i '' "s/$old/$new/g" "$s" && moved=$((moved+1))
      done <<< "$files"
    fi
    log "environments: two accounts each had \"$name\" for the same place; kept one, and pointed $moved session(s) started from the other at it${b:+ (their records as they were are in ${b#$DIR/})}"
  done < <(jq -r '.moved | to_entries[] | [.key, .value.to, .value.name] | @tsv' "$plan")
  if jq_write "$f" --argjson ids "$ids" --slurpfile p "$plan" 'reduce $ids[] as $i (.; .byAccount[$i] = $p[0].shared)' \
     && ( umask 077; jq --argjson ids "$ids" '{shared, accounts: $ids}' "$plan" > "$shared.tmp.$$" ) && mv -f "$shared.tmp.$$" "$shared"; then
    log "environments: every account has the same $n saved environment(s)"
  fi
  rm -f "$plan" "$shared.tmp.$$"
}

# A one-off settings fix ($DIR/prefs-patch.json), merged in the next time Claude is closed.
apply_prefs_patch() {
  [ -f "$DIR/prefs-patch.json" ] || return 0
  cp -p "$PREFS" "$DIR/backups/claude_desktop_config.before-patch.json"
  jq_write "$PREFS" --slurpfile patch "$DIR/prefs-patch.json" '. * $patch[0]' \
    && mv "$DIR/prefs-patch.json" "$DIR/backups/prefs-patch.applied.json" && log "prefs: patch applied"
}

# A one-off session list fix ($DIR/sessions-patch/local_*.json: session records to add or
# replace, such as ones the app couldn't save), moved into the shared list the next time
# Claude is closed. The records they replace are backed up first.
apply_sessions_patch() {
  local src="$DIR/sessions-patch" canon b f n=0
  ls "$src"/local_*.json >/dev/null 2>&1 || return 0
  canon=$(shared_list claude-code-sessions)
  [ -d "$canon" ] || { log "sessions: no shared list; the session patch waits"; return 0; }
  b=$(backup_dir sessions-patch)
  for f in "$src"/local_*.json; do
    [ -e "$canon/${f##*/}" ] && cp -p "$canon/${f##*/}" "$b/"
    mv -f "$f" "$canon/" && n=$((n+1))
  done
  rmdir "$src" 2>/dev/null
  log "sessions: patch applied: $n session record(s) put in the shared list (the ones replaced are in ${b#$DIR/})"
}

# ~/.claude/account-relay is the old name of $DIR, left as a link for sessions still running
# the old mod. Once Claude has quit none are left, so the link goes.
drop_old_link() {
  local old="$HOME/.claude/account-relay"
  [ -L "$old" ] && rm "$old" && log "removed the old link $old"
  return 0
}

# The app files a session under Scratch only if its folder is inside the app's own
# scratch-workspaces. Sessions started in another profile folder (Claude-<name>) point
# outside it and show up as one project each. Point them back.
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

# Restart Claude in place (same account), doing everything that needs it closed.
cmd_restart() {
  local session=""; [ "${1:-}" = "--resume" ] && session="${2:-}"
  lock_or_die restart
  recover_signin
  pause 10
  [ -n "$session" ] && hand_off "$session" restart "$(folder_account "$DEFAULT_DIR")"
  if ! quit_checked; then
    [ -n "$session" ] && drop_hand_off "$session"
    die "restart: Claude updated and its files changed; reopened it without changing anything. Run relay.sh doctor."
  fi
  while_closed
  open_app
  reopen_handoff 15 >/dev/null
  report_lost 5
}

# ---- Accounts ------------------------------------------------------------------------------

# Add account $2 (an accountUuid the app reported) as $1. Fills an entry with only a name, or
# adds one; never re-points an entry that already has an accountUuid (returns 1 then). An id
# already in accounts.json is left under its own name.
add_account() {
  local name="$1" id="$2" other; other=$(account_field "$id" name)
  if [ -n "$other" ]; then log "accounts: that sign-in is $other, already in accounts.json; kept as $other"; notify "That was $other, not a new account. Kept it as $other."; return 0; fi
  if [ -n "$(account_by_name "$name")" ]; then log "accounts: $name is already set up as another account; $id not added"; return 1; fi
  jq_write "$ACCOUNTS" --arg n "$name" --arg u "$id" '
    if any(.accounts[]; .name == $n) then .accounts |= map(if .name == $n and ((.accountUuid // "") == "") then . + {accountUuid: $u} else . end)
    else .accounts += [{name: $n, accountUuid: $u}] end'
  log "accounts: added $name ($id)"
}

# The org of account $1, from the session folders the app makes for it
# (claude-code-sessions/<account>/<org>/): the only one, or else the only one no other
# account in accounts.json has. Empty when that doesn't settle it.
new_org() {
  local id="$1" d b orgs="" others
  for d in "$DEFAULT_DIR"/claude-code-sessions/"$id"/* "$DEFAULT_DIR"/local-agent-mode-sessions/"$id"/*; do
    b=$(basename "$d"); [[ "$b" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] && orgs+="$b"$'\n'
  done
  orgs=$(printf '%s' "$orgs" | sort -u)
  [ "$(printf '%s' "$orgs" | grep -c .)" -eq 1 ] && { echo "$orgs"; return; }
  others=$(jq -r --arg u "$id" '.accounts[] | select(.accountUuid != $u) | .orgUuid // empty' "$ACCOUNTS")
  orgs=$(printf '%s\n' "$orgs" | grep . | grep -vxF -f <(printf '%s\n' "$others" | grep . || echo none))
  [ "$(printf '%s' "$orgs" | grep -c .)" -eq 1 ] && echo "$orgs"
}

# Fill in orgUuid for accounts that don't have it yet (a new one, before the app had made
# its session folder).
fill_orgs() {
  local id org
  for id in $(jq -r '.accounts[] | select((.orgUuid // "") == "") | .accountUuid // empty' "$ACCOUNTS"); do
    org=$(new_org "$id")
    if [ -n "$org" ]; then
      jq_write "$ACCOUNTS" --arg u "$id" --arg o "$org" '.accounts |= map(if .accountUuid == $u then . + {orgUuid: $o} else . end)'
      log "accounts: $(account_field "$id" name)'s org is $org"
    else log "accounts: $(account_field "$id" name)'s org isn't known yet; it's filled in on a later switch or restart"; fi
  done
}

# The shared session folder for one kind (claude-code-sessions or local-agent-mode-sessions):
# what the existing links point at. Empty before there's a shared list.
shared_list() { local l; for l in "$DEFAULT_DIR/$1"/*/*; do [ -L "$l" ] && { readlink "$l"; return; }; done; }

# One session list for every account: each account/org folder under claude-code-sessions/ and
# local-agent-mode-sessions/ links to one shared folder. The first time, the shared folder is
# the first account's own (the one setup added). A real folder of an account in accounts.json (the app makes one
# when a new account first loads) has its sessions moved into the shared folder (backed up
# first), is kept as <org>.merged-<stamp>, and becomes a link. An account whose org is known
# gets its link even before the app makes the folder. Then the shared folder moves to $1, the
# account Claude opens on next (default: the one it reports now), since the app saves no
# session into a link of its own (ENOTDIR, logged, and the session is gone from the list at
# the next start). Only while Claude is closed: the running app rewrites session files.
link_sessions() {
  local live="${1:-$(folder_account "$DEFAULT_DIR")}" stamp kind root canon d id org f moved first; stamp=$(date +%Y%m%d-%H%M%S)
  first=$(jq -r '[.accounts[] | select(.accountUuid and .orgUuid)] | if length >= 2 then .[0].accountUuid else empty end' "$ACCOUNTS")
  for kind in claude-code-sessions local-agent-mode-sessions; do
    root="$DEFAULT_DIR/$kind"; canon=$(shared_list "$kind")
    [ -n "$canon" ] && [ ! -e "$canon" ] && { live_list "$root" "$canon" "$live"; canon=$(shared_list "$kind"); }
    if [ -z "$canon" ]; then
      [ -n "$first" ] || continue   # fewer than two accounts: nothing to share yet
      canon="$root/$first/$(account_field "$first" orgUuid)"; mkdir -p "$canon"
      log "sessions: $kind: $(account_field "$first" name)'s list is now the shared one"
    fi
    [ -d "$canon" ] || { log "sessions: $kind: the shared list $canon is missing; nothing linked"; continue; }
    for id in $(account_ids); do
      for d in "$root/$id"/*; do
        [ -d "$d" ] && [ ! -L "$d" ] && [ "$d" != "$canon" ] || continue
        case "$d" in *.merged-*) continue ;; esac
        mkdir -p "$DIR/backups/$stamp-shared-list/$kind/$id"
        ditto "$d" "$DIR/backups/$stamp-shared-list/$kind/$id/$(basename "$d")"
        moved=0; for f in "$d"/* "$d"/.[!.]*; do [ -e "$f" ] && mv -n "$f" "$canon/" && moved=$((moved+1)); done
        mv "$d" "$d.merged-$stamp" && ln -s "$canon" "$d"
        log "sessions: $kind/$(account_field "$id" name)/$(basename "$d") linked to the shared list ($moved item(s) moved in)"
      done
      org=$(account_field "$id" orgUuid)
      if [ -n "$org" ] && [ ! -e "$root/$id/$org" ]; then
        mkdir -p "$root/$id" && ln -s "$canon" "$root/$id/$org" && log "sessions: $kind/$(account_field "$id" name)/$org linked to the shared list"
      fi
    done
    live_list "$root" "$canon" "$live"
  done
}

# Make account $3's folder under $1 the shared folder $2 itself, and every link point at it.
# The shared folder's old place becomes a link too. A run cut off after the move (the old
# place missing) is finished here: shared_list still names the old place then.
live_list() {
  local root="$1" canon="$2" live="$3" org dest l
  org=$(account_field "$live" orgUuid); [ -n "$live" ] && [ -n "$org" ] || return 0
  dest="$root/$live/$org"
  [ "$dest" = "$canon" ] && return 0
  if [ -d "$canon" ] && [ ! -L "$canon" ]; then
    [ -L "$dest" ] || [ ! -e "$dest" ] || { log "sessions: ${root##*/}/$(account_field "$live" name) has a list of its own; not moving the shared one there"; return 0; }
    mkdir -p "$root/$live"; rm -f "$dest"; mv "$canon" "$dest" || return 0
  fi
  [ -d "$dest" ] && [ ! -L "$dest" ] || return 0
  [ -e "$canon" ] || ln -s "$dest" "$canon"
  for l in "$root"/*/*; do [ -L "$l" ] && [ "$(readlink "$l")" != "$dest" ] && ln -sfn "$dest" "$l"; done
  log "sessions: ${root##*/}: the shared list is $(account_field "$live" name)'s folder now"
}

# Sign an account in without losing the current one:
#   relay.sh signin <name> [--resume <sessionId>]
# Parks the current sign-in, opens Claude signed out for you to sign in to <name>, then
# parks <name> and brings the previous account back. Gives up after 10 minutes.
# <name> must be in accounts.json; `relay.sh add <name>` runs this for a new one (ADDING),
# where whatever account other than the current one you sign in to is added under that
# name, with the ids the app reports, and its session folders are linked to the shared list.
ADDING=""
cmd_signin() {
  local name="${1:-}"; [ -n "$name" ] || die "signin: which account? relay.sh signin <name>"
  local id; id=$(account_by_name "$name")
  if [ -n "$ADDING" ]; then [ -z "$id" ] || die "$name is already set up; to sign it in again use relay.sh signin $name"
  else [ -n "$id" ] || die "signin: there's no account named $name; to add one use relay.sh add $name"; fi
  local session=""; [ "${2:-}" = "--resume" ] && session="${3:-}"
  lock_or_die "$([ -n "$ADDING" ] && echo add || echo signin)"
  recover_signin
  local cur why; cur=$(folder_account "$DEFAULT_DIR")
  [ -n "$id" ] && [ "$id" = "$cur" ] && die "signin: Claude is on $name already; if it's signed out, sign in in Claude itself."
  why=$(check_app) || die "signin: not closing Claude: $why. Run relay.sh doctor."
  pause 10
  [ -n "$session" ] && hand_off "$session" signin "$cur"
  if ! quit_checked; then
    [ -n "$session" ] && drop_hand_off "$session"
    die "signin: Claude updated and its files changed; reopened it without changing anything. Run relay.sh doctor."
  fi
  # From here until the previous account is back, a kill puts its sign-in back (signin_undo).
  UNDO="signin_undo $cur"
  move_signin "$cur" "${id:-new}"   # nothing parked for it, so Claude opens signed out
  [ -n "$id" ] && link_sessions "$id"   # so a session started while signed in to it is saved
  open_app
  notify "Sign in to ${name} in Claude. Your other account comes back afterwards."
  log "signin: waiting for ${name} to be signed in$([ -z "$id" ] && echo " (a new account)")"
  # While signed out the app still reports the last account, so a new one shows as a change.
  local now n=0
  # Signing in to another account already set up instead of <name> counts too: it's kept
  # under its own name, rather than thrown away after the wait.
  signed_in() { now=$(folder_account "$DEFAULT_DIR"); if [ -n "$id" ]; then [ "$now" = "$id" ] || { [ "$now" != "$cur" ] && [ -n "$(account_field "$now" name)" ]; }; else [ -n "$now" ] && [ "$now" != "$cur" ]; fi; }
  while ! signed_in && [ $n -lt 600 ]; do sleep 2; n=$((n+2)); done
  local new=""
  if signed_in; then
    new="$now"
    if [ -n "$id" ] && [ "$new" != "$id" ]; then
      log "signin: that sign-in is $(account_field "$new" name), not ${name}; kept as $(account_field "$new" name)"
      notify "That was $(account_field "$new" name), not ${name}. Kept it as $(account_field "$new" name)."
    else log "signin: ${name} signed in"; fi
    # The app makes the account's session folder, which names its org, once the Code tab loads.
    n=0; while [ -z "$(new_org "$new")" ] && [ $n -lt 30 ]; do sleep 2; n=$((n+2)); done
    pause 8
  else log "signin: no sign-in to ${name} within 10 minutes"; fi
  quit_default
  if [ -n "$new" ]; then
    [ -z "$id" ] && add_account "$name" "$new"
    [ -z "$id" ] && ! cli_parked "$new" && [ "$(cli_account)" != "$new" ] \
      && notify "Added $name. So terminal claude follows the app to it, run relay.sh cli-login $name once."
    move_signin "$new" "$cur"
    while_closed "$cur"
  else
    # Whatever the app was left holding (signed out, or another account than the one asked
    # for) goes to backups/; the previous account's sign-in comes back whole.
    move_pair "$PARK/$cur" "$DEFAULT_DIR" unused-signin
    link_sessions "$cur"
  fi
  UNDO=""
  open_app
  log "signin: back on $(account_field "$cur" name)"
  reopen_handoff 15 >/dev/null
  report_lost 5
}

# A sign-in killed while Claude was open for it (launchd stops a job with SIGTERM): close
# Claude, park whatever got signed in under its account (or in backups/ if it isn't one in
# accounts.json, or one is parked there already), put $1's sign-in back, and open Claude.
signin_undo() {
  local cur="$1" now; quit_default
  now=$(folder_account "$DEFAULT_DIR")
  if [ -e "$DEFAULT_DIR/Cookies" ] && [ "$now" != "$cur" ]; then
    if [ -n "$(account_field "$now" name)" ] && [ ! -e "$PARK/$now/Cookies" ]; then move_pair "$DEFAULT_DIR" "$PARK/$now"
    else move_pair "$DEFAULT_DIR" "$(backup_dir cut-off-signin)"; fi
  fi
  # Anything else left in the profile (a signed-out Cookies) goes to backups/ as it comes back.
  [ -e "$PARK/$cur/Cookies" ] && move_pair "$PARK/$cur" "$DEFAULT_DIR" signed-out-cookies
  log "signin: cut off; put $(account_field "$cur" name)'s sign-in back"
  link_sessions "$cur"
  open_app
}

# relay.sh add <name> [--resume <sessionId>]: sign in a new account and add it as <name>,
# which must not be in accounts.json yet (to sign an account in again: relay.sh signin <name>).
cmd_add() { ADDING=1 cmd_signin "$@"; }

# Bench an account, or put it back (after CLIProxyAPI's "disabled"): a benched account stays set
# up, its parked sign-ins are kept alive and its usage is read, and use <name> still switches
# to it; only the automatic switches (the app's and the terminal's) skip it. Nothing is moved,
# so it doesn't need the lock.
#   relay.sh bench <name> / relay.sh unbench <name>
cmd_bench() {   # cmd_bench <true|false> <name>
  local verb; [ "$1" = true ] && verb=bench || verb=unbench
  local name="${2:-}" id; [ -n "$name" ] || die "$verb: which account? relay.sh $verb <name>"
  id=$(account_by_name "$name"); [ -n "$id" ] || die "$verb: no account named $name"
  jq_write "$ACCOUNTS" --arg u "$id" --argjson b "$1" '(.accounts[] | select(.accountUuid == $u)) |= (if $b then .benched = true else del(.benched) end)' \
    || die "$verb: couldn't write $ACCOUNTS"
  if [ "$1" = true ]; then
    log "bench: $name benched; automatic switches skip it"
    echo "Benched $name: automatic switches skip it. Its sign-ins are kept alive, and relay.sh use $name still switches to it."
  else
    log "bench: $name is back in automatic switching"
    echo "$name is back in automatic switching."
  fi
  [ "$(account_ids | grep -c .)" -ge 2 ] && [ -n "$(bench_note)" ] && echo "Note: $(bench_note)."
  return 0
}
# What automatic switching can't do with the benched accounts left out (with two or more
# accounts set up); nothing while two or more aren't benched.
bench_note() {
  local free; free=$(jq -r '.accounts[] | select(.benched != true) | .name' "$ACCOUNTS")
  case $(printf '%s' "$free" | grep -c .) in
    0) echo "every account is benched, so automatic switching never moves Claude" ;;
    1) echo "every account but $free is benched, so when $free runs out there's no account to switch to" ;;
  esac
}

# Take an account out: its parked sign-in moves to backups/ (still signed in there until you
# delete it), its parked terminal login is deleted, and it's dropped from accounts.json.
cmd_remove() {
  local name="${1:-}" id; id=$(account_by_name "$name"); [ -n "$id" ] || die "remove: no account named $name"
  # Not while a switch, sign-in or keep-alive may be moving this account's sign-in.
  lock_or_die remove
  if [ -n "$LINUX" ]; then
    [ "$id" = "$(cli_account)" ] && die "remove: terminal claude is on $name now; move to another account first (relay.sh use <name>)"
  else
    recover_signin
    [ "$id" = "$(folder_account "$DEFAULT_DIR")" ] && die "remove: Claude is on $name now; switch to another account first (relay.sh use <name>)"
  fi
  local b; b=$(backup_dir "removed-$name")
  jq --arg u "$id" '.accounts[] | select(.accountUuid == $u)' "$ACCOUNTS" > "$b/account.json"
  cli_parked "$id" && parked_drop "$id"
  [ -d "$PARK/$id" ] && mv "$PARK/$id" "$b/park"
  jq_write "$ACCOUNTS" --arg u "$id" 'del(.accounts[] | select(.accountUuid == $u))'
  jq_write "$STATE" --arg u "$id" 'del(.cooldowns[$u])'
  if [ -n "$LINUX" ]; then log "accounts: removed $name ($id); its parked login is deleted"; echo "Removed $name, and deleted its parked login."; return 0; fi
  log "accounts: removed $name ($id); its parked sign-in is in $b"
  echo "Removed $name. Its sign-in is kept in $b/park; delete that folder to sign it out for good."
  [ "$(cli_account)" = "$id" ] && echo "Terminal claude is still logged in as $name; use relay.sh cli-use <name> or claude /login to move it."
  return 0
}

# ---- Setup ---------------------------------------------------------------------------------

# Link $2 to $1, unless it already links to a working copy somewhere else (another checkout
# you use); never replace a real file.
link_to() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    local now; now=$(readlink "$dst")
    if [ "$now" = "$src" ]; then echo "ok  $dst -> $src"; return; fi
    if [ -e "$dst" ]; then echo "~~  $dst links to $now; left as it is (remove the link to use $src)"; return; fi
    ln -sfn "$src" "$dst" && echo "ok  $dst -> $src (was a broken link)"; return
  fi
  [ -e "$dst" ] && die "setup: $dst exists and isn't a link; move it aside first"
  ln -s "$src" "$dst" && echo "ok  $dst -> $src"
}

# The mod, installed as a Claude Code plugin from the link in $DIR. Claude Code reads it from
# there each time, so a newer mod in the repo needs no reinstall.
install_mod() {
  if jq -e --arg p "$PLUGIN" '.enabledPlugins[$p] == true' "$HOME/.claude/settings.json" >/dev/null 2>&1; then echo "ok  mod installed"; return 0; fi
  command -v claude >/dev/null || die "setup: needs the claude CLI to install the mod (https://claude.com/claude-code)"
  claude plugin marketplace add "$DIR/mod" >/dev/null && claude plugin install "$PLUGIN" --scope user >/dev/null || die "setup: installing the mod failed"
  echo "ok  mod installed (new sessions pick it up)"
}

# One-time setup on a Mac, run from the cloned repo: relay.sh setup <name for the account Claude is signed in to>.
# Safe to run again; it only adds what's missing.
cmd_setup() {
  local name="${1:-}" t v why repo; repo=$(REPO)
  [ "$(uname)" = Darwin ] || die "setup: macOS only"
  for t in jq sqlite3 plutil; do command -v "$t" >/dev/null || die "setup: needs $t (brew install $t)"; done
  v=$(app_version); [ -n "$v" ] || die "setup: Claude Desktop isn't in $APP"
  why=$(check_app) || die "setup: Claude Desktop $v doesn't keep its files where this expects ($why). Sign in to Claude first; if you are, this version isn't supported yet."
  signed_in_now || die "setup: Claude is signed out; sign in to Claude first."
  version_tested || echo "~~  Claude Desktop $v hasn't been tested with this switcher (tested: $TESTED_VERSIONS). Switches check the app's files first, but watch the first one."
  mkdir -p "$DIR/backups" "$PARK"
  [ -f "$ACCOUNTS" ] || echo '{"accounts":[]}' > "$ACCOUNTS"
  [ -f "$STATE" ] || echo '{"cooldowns":{},"switches":[]}' > "$STATE"
  [ -f "$HANDOFF" ] || echo '{"resume":[]}' > "$HANDOFF"
  [ -f "$USAGE" ] || echo "{}" > "$USAGE"
  link_to "$repo/relay.sh" "$DIR/relay.sh"
  link_to "$repo/mod" "$DIR/mod"
  local cur; cur=$(folder_account "$DEFAULT_DIR")
  if [ -z "$(account_field "$cur" name)" ]; then
    [ -n "$name" ] || die "setup: give the account Claude is signed in to a short name: relay.sh setup <name>"
    add_account "$name" "$cur" || die "setup: $name is already set up as another account; give the account Claude is signed in to another name"
    fill_orgs
  fi
  echo "ok  Claude is on $(account_field "$cur" name)"
  [ -f "$DIR/config.json" ] || { echo '{ "armed": true }' > "$DIR/config.json"; echo "ok  auto-switch on"; }
  install_mod
  launchctl print "gui/$(id -u)/$LABEL.keepalive" >/dev/null 2>&1 || { cmd_install_keepalive; echo "ok  daily keep-alive installed"; }
  log "setup: done ($repo)"
  echo
  if [ "$(account_ids | grep -c .)" -lt 2 ]; then
    echo "Next: add your other account with  $DIR/relay.sh add <name>"
    echo "(Claude closes and opens signed out; sign in to the other account and wait for the Code tab.)"
  else
    echo "Next: $DIR/relay.sh doctor"
  fi
}

# ---- Linux -----------------------------------------------------------------------------------
#
# A Linux server has no desktop app. What signs in there is terminal claude's login, the file
# ~/.claude/.credentials.json, and with it everything that runs the real claude or reads that
# file (T3 Code, a proxy, scripts). So the account in use is the terminal's, a switch is the
# terminal move above (swap_cli), and what a Mac leaves to the app is done by a systemd timer:
# every two minutes `relay.sh tick` reads usage, moves the login before the account runs out
# (or when it has), renews the parked logins, and pulls a new version of this repo.

UNIT="desktop-account-switcher"
# How long a command waits for the lock: a timer round holds it for seconds, or a couple of
# minutes while it renews a parked login (ACCOUNT_SWITCHER_FAST: 4 seconds, for the tests).
LOCK_WAIT=150; [ -n "${ACCOUNT_SWITCHER_FAST:-}" ] && LOCK_WAIT=4
[ -n "$LINUX" ] && export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # systemctl --user needs it
armed() { jq -e '.armed == true' "$DIR/config.json" >/dev/null 2>&1; }
# On unless config.json says "autoUpdate": false.
auto_update() { ! jq -e '.autoUpdate == false' "$DIR/config.json" >/dev/null 2>&1; }

# Add the account that the config file $2 (a ~/.claude.json) is signed in to, as $1.
account_from() {
  jq_write "$ACCOUNTS" --arg n "$1" --slurpfile c "$2" '($c[0].oauthAccount) as $o
    | .accounts += [{name: $n, accountUuid: $o.accountUuid, orgUuid: ($o.organizationUuid // ""), email: ($o.emailAddress // "")}]' \
    && log "accounts: added $1 ($(jq -r '.oauthAccount.accountUuid' "$2"))"
}

# First run on a Linux machine, from the cloned repo: relay.sh setup <name for the account
# terminal claude is signed in to>. Safe to run again; it only adds what's missing (a self-update
# runs it, so a new version sets up whatever it added).
cmd_setup_linux() {
  local name="${1:-}" t repo cur; repo=$(REPO)
  for t in jq curl git claude systemctl; do command -v "$t" >/dev/null || die "setup: needs $t"; done
  cur=$(cli_account)
  [ -n "$cur" ] && live_has || die "setup: terminal claude isn't signed in here; run claude auth login first"
  mkdir -p "$DIR/backups" "$PARK"; chmod 700 "$PARK"
  [ -f "$ACCOUNTS" ] || echo '{"accounts":[]}' > "$ACCOUNTS"
  [ -f "$STATE" ] || echo '{"cooldowns":{},"switches":[]}' > "$STATE"
  [ -f "$HANDOFF" ] || echo '{"resume":[]}' > "$HANDOFF"
  [ -f "$USAGE" ] || echo "{}" > "$USAGE"
  link_to "$repo/relay.sh" "$DIR/relay.sh"
  link_to "$repo/mod" "$DIR/mod"
  if [ -z "$(account_field "$cur" name)" ]; then
    [ -n "$name" ] || die "setup: give the account terminal claude is signed in to a short name: relay.sh setup <name>"
    [ -z "$(account_by_name "$name")" ] || die "setup: $name is already set up as another account; give the account terminal claude is signed in to another name"
    account_from "$name" "$HOME/.claude.json" || die "setup: couldn't write $ACCOUNTS"
  fi
  echo "ok  terminal claude is on $(account_field "$cur" name)"
  [ -f "$DIR/config.json" ] || { echo '{ "armed": true }' > "$DIR/config.json"; echo "ok  auto-switch on"; }
  install_mod
  install_timer && echo "ok  timer running (every two minutes)" || die "setup: couldn't start the timer (systemctl --user)"
  [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] \
    || echo "~~  the timer stops when you log out of this machine; to keep it running: sudo loginctl enable-linger $USER"
  log "setup: done ($repo)"
  echo
  if [ "$(account_ids | grep -c .)" -lt 2 ]; then
    echo "Next: add your other account with  $DIR/relay.sh add <name>"
    echo "(It prints a sign-in link: open it in a browser signed in to that account, and paste the code back.)"
  else
    echo "Next: $DIR/relay.sh doctor"
  fi
}

# The timer and the service it starts, as systemd user units. Written again only when they
# differ, so running setup twice (or after an update) changes nothing that's already right.
install_timer() {
  local d="$HOME/.config/systemd/user" f changed=""
  mkdir -p "$d"
  unit() {   # unit <file>, its text on stdin
    cat > "$1.new"
    if cmp -s "$1.new" "$1"; then rm -f "$1.new"; else mv -f "$1.new" "$1"; changed=1; fi
  }
  unit "$d/$UNIT.service" <<EOF
[Unit]
Description=Claude account switcher: read usage, move terminal claude's login, renew parked logins, update

[Service]
Type=oneshot
ExecStart=/bin/bash "$DIR/relay.sh" tick
TimeoutStartSec=15min
Nice=10
EOF
  unit "$d/$UNIT.timer" <<EOF
[Unit]
Description=Claude account switcher, every two minutes

[Timer]
OnBootSec=1min
OnUnitInactiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
  if [ -n "$changed" ]; then
    systemctl --user daemon-reload || return 1
    systemctl --user is-active --quiet "$UNIT.timer" && { systemctl --user restart "$UNIT.timer" || return 1; }
    log "timer: units written"
  fi
  systemctl --user enable --now "$UNIT.timer" >/dev/null 2>&1
}

# Sign an account in without touching the live login (after T3 Code's guide to separate Claude
# accounts): `claude auth login` runs with its config folder set to a throwaway one, so the new
# login lands there and is parked from there. A server has no browser, so claude prints a link:
# open it in a browser signed in to that account, and paste the code it shows back.
#   relay.sh add <name> [<email>]    a new account, under a name not used yet
#   relay.sh signin <name>           one already set up, whose login stopped working
LOGIN_DIR="$DIR/login"
cmd_login_linux() {
  local name="${1:-}" email="${2:-}" id got who what=signin h="$LOGIN_DIR"
  [ -n "$ADDING" ] && what=add
  [ -n "$name" ] || die "$what: which account? relay.sh $what <name>"
  id=$(account_by_name "$name")
  if [ -n "$ADDING" ]; then [ -z "$id" ] || die "$name is already set up; to sign it in again use relay.sh signin $name"
  else
    [ -n "$id" ] || die "$what: there's no account named $name; to add one use relay.sh add $name"
    email=$(account_field "$id" email)
  fi
  lock_wait "$what" "$LOCK_WAIT" || die "$what: a switch or sign-in is running; try again when it's done"
  rm -rf "$h"; mkdir -p "$h"; chmod 700 "$h"; UNDO='rm -rf "$LOGIN_DIR"'
  echo "Signing in $name${email:+ ($email)}. Open the link in a browser that's signed in to that account at claude.ai, and paste the code it shows back here."
  log "$what: signing $name in"
  CLAUDE_CONFIG_DIR="$h" claude auth login --claudeai ${email:+--email "$email"} \
    || die "$what: the sign-in to $name didn't finish; nothing changed"
  got=$(jq -r '.oauthAccount.accountUuid // empty' "$h/.claude.json" 2>/dev/null)
  [ -n "$got" ] && jq -e '.claudeAiOauth.refreshToken' "$h/.credentials.json" >/dev/null 2>&1 \
    || die "$what: claude finished, but left no login to keep; nothing changed"
  who=$(account_field "$got" name)
  local wrong="Your browser approves whichever account it's signed in to: open the link in a browser signed in as $name (a private window works), then run this again."
  if [ -n "$who" ] && [ "$who" != "$name" ]; then
    # Another account that's set up already: its new login is kept, unless it's the one in use.
    if [ "$(cli_account)" = "$got" ]; then die "$what: that sign-in was $who, which terminal claude is on already, not $name; nothing changed. $wrong"; fi
    keep_login "$got" "$h" && log "$what: that sign-in was $who, not $name; kept as $who's parked login"
    die "$what: that sign-in was $who, not $name; it's kept as $who's. $wrong"
  fi
  if [ -z "$who" ] && [ -z "$ADDING" ]; then
    die "$what: that sign-in was $(jq -r '.oauthAccount.emailAddress // "another account"' "$h/.claude.json"), not $name; nothing kept. $wrong"
  fi
  if [ -z "$who" ]; then account_from "$name" "$h/.claude.json" || die "$what: couldn't write $ACCOUNTS"; fi
  keep_login "$got" "$h" || die "$what: signed in as $name, but couldn't keep that login"
  rm -rf "$h"; UNDO=""
  log "$what: $name signed in"
  if [ "$(cli_account)" = "$got" ]; then echo "$name is signed in again; terminal claude is on it."
  else echo "$name is signed in: its login is parked, and terminal claude moves to it when $(account_field "$(cli_account)" name) runs out (or with relay.sh use $name)."; fi
}
# Keep the login in the config folder $2 as account $1's: the live one if terminal claude is on
# that account, its parked one otherwise.
keep_login() {
  local id="$1" h="$2"
  if [ "$(cli_account)" = "$id" ]; then
    live_store < "$h/.credentials.json" && jq_write "$HOME/.claude.json" --slurpfile c "$h/.claude.json" '.oauthAccount = $c[0].oauthAccount' || return 1
  else
    parked_store "$id" < "$h/.credentials.json" && jq '.oauthAccount' "$h/.claude.json" > "$PARK/$id/oauthAccount.json" || return 1
  fi
  cli_dead "$id" && jq_write "$STATE" --arg a "$id" 'del(.cliDead[$a])'
  return 0
}

# relay.sh use <name>: move terminal claude to <name> now. It stays there until that account
# runs out: the timer doesn't move it off early (pinned), as it would an account it chose itself.
cmd_use_linux() {
  local id; id=$(account_by_name "${1:-}"); [ -n "$id" ] || die "use: no account named ${1:-}"
  lock_wait use "$LOCK_WAIT" || die "use: a switch or sign-in is running; try again when it's done"
  swap_cli "$id" || die "use: terminal claude stays on $(account_field "$(cli_account)" name): see $LOG"
  jq_write "$STATE" --arg a "$id" '.pinned = $a | del(.watchSaid)'
  echo "terminal claude is on $(account_field "$(cli_account)" name); sessions already running follow on their next request"
}

# What account $1's last usage reading says, for the timer: one line, tab-separated.
#   out <latest reset> <which>     a 5-hour or weekly window is used up
#   scoped <label>                 a model's own weekly limit is used up
#   near <which>                   a 5-hour or weekly window is at $2 percent or more
#   warm                           one is within 10 points of that
#   fine
# A window past its reset time doesn't count: usage only goes down at a reset.
watch_state() {
  jq -r --arg a "$1" --argjson near "$2" --argjson now "$(date -u +%s)" '
    def epoch: sub("\\.[0-9]+";"") | sub("[+]00:00$";"Z") | fromdateiso8601;
    def which: map("\(if .kind == "five_hour" then "5-hour" else "weekly" end) \(.percentUsed | round)%") | join(", ");
    [(.[$a].windows // [])[] | select(((.resetsAt // "") != "") and ((.resetsAt | epoch) > $now))] as $w
    | [$w[] | select(.kind == "five_hour" or .kind == "seven_day")] as $main
    | [$main[] | select(.percentUsed >= 100)] as $out
    | [$w[] | select(.kind == "weekly_scoped" and .percentUsed >= 100)] as $scoped
    | [$main[] | select(.percentUsed >= $near)] as $nearly
    | if ($out | length) > 0 then "out\t\($out | map(.resetsAt) | sort | last)\t\($out | which)"
      elif ($scoped | length) > 0 then "scoped\t\($scoped[0].label)"
      elif ($nearly | length) > 0 then "near\t\($nearly | which)"
      elif any($main[]; .percentUsed >= $near - 10) then "warm"
      else "fine" end' "$USAGE" 2>/dev/null
}
# The accounts terminal claude can move to: a parked login that still works (one id a line).
cli_ready() { local id; for id in $(account_ids); do cli_parked "$id" && ! cli_dead "$id" && echo "$id"; done; return 0; }
# Log (and notify) what the timer found, once: again only when it changes. said "" forgets it.
said() {
  [ "$(jq -r '.watchSaid // ""' "$STATE")" = "$1" ] && return 0
  jq_write "$STATE" --arg k "$1" '.watchSaid = $k'
  [ -n "$1" ] && { log "watch: $2"; notify "$2"; }
  return 0
}

# The timer's switch. With auto-switch on, terminal claude moves:
#   when its account is out (a 5-hour or weekly window used up): to the next account that
#     isn't, and the spent one cools down until its reset, as after a limit in a session;
#   before that, at 95% ("switchAt" in config.json): to the next account under 95%, so sessions
#     that are running never meet the limit. With no such account it stays, and uses the rest;
#   when a model's own weekly limit is used up: to an account with nothing used up at all.
# The last two never move it off an account you chose with `use`. Six moves in an hour stop it
# for the rest of that hour: something is wrong, and logins shouldn't be shuffled over it.
WATCH_MAX=6
watch() {
  armed || return 0
  local live name near kind a b target="" why ready now; now=$(date -u +%s)
  live=$(cli_account); name=$(account_field "$live" name)
  if [ -z "$name" ]; then said "unknown:$live" "terminal claude is on ${live:-no account}, which isn't set up here, so nothing is switched (relay.sh doctor)"; return 0; fi
  near=$(jq -r '.switchAt // 95' "$DIR/config.json" 2>/dev/null); case "$near" in ''|*[!0-9]*) near=95 ;; esac
  IFS=$'\t' read -r kind a b <<< "$(watch_state "$live" "$near")"
  # Close to a limit, the account in use is read every round, not every ten minutes.
  if [ "${kind:-fine}" != fine ] && [ "$now" -ge "$(jq -r '.usageWaitUntil // 0' "$STATE")" ] \
    && [ $(( now - $(jq -r --arg a "$live" '(.[$a].at // 0) / 1000 | floor' "$USAGE") )) -ge 100 ]; then
    usage_read "$live"; IFS=$'\t' read -r kind a b <<< "$(watch_state "$live" "$near")"
  fi
  local pinned; pinned=$(jq -r '.pinned // ""' "$STATE")
  ready=$(cli_ready | grep -vxF "$live")
  case "${kind:-fine}" in
    out)
      jq_write "$STATE" --arg a "$live" --arg u "$a" '.cooldowns[$a] = $u | del(.pinned)'
      why="$name is out of usage ($b)"
      [ -n "$ready" ] && target=$(pick_target "$live" "" "$ready") ;;
    scoped)
      [ "$pinned" = "$live" ] && return 0
      why="$name's $a limit is used up"
      [ -n "$ready" ] && target=$(pick_target "$live" "$a" "$ready" 100 all) ;;
    near)
      [ "$pinned" = "$live" ] && return 0
      why="$name is nearly out ($a)"
      [ -n "$ready" ] && target=$(pick_target "$live" "" "$ready" "$near") ;;
    *) said ""; return 0 ;;
  esac
  if [ -z "$target" ]; then
    # Nearly out with nowhere better to go is nothing to say: it uses the rest of this account.
    [ "$kind" = out ] && said "out:$live:$a" "$why, and no other account has usage left and a login that works"
    return 0
  fi
  if [ "$(jq --argjson now "$now" '[(.watchMoves // [])[] | select($now - . < 3600)] | length' "$STATE")" -ge "$WATCH_MAX" ]; then
    said "stopped" "$WATCH_MAX switches in the last hour, so the timer has stopped switching until an hour passes without one (relay.sh history)"
    return 0
  fi
  if swap_cli "$target"; then
    jq_write "$STATE" --argjson now "$now" '.watchMoves = ([(.watchMoves // [])[] | select($now - . < 3600)] + [$now]) | del(.pinned) | del(.watchSaid)'
    log "watch: $why; terminal claude moved to $(account_field "$target" name)"
    notify "$why. Moved to $(account_field "$target" name)."
  else said "failed:$live:$target" "$why, but the move to $(account_field "$target" name) didn't work (relay.sh doctor)"; fi
}

# One round of the timer. Skipped while a sign-in or a switch by hand holds the lock.
UPDATE_EVERY=3600
cmd_tick() {
  lock_take tick || exit 0
  jq_write "$STATE" --argjson t "$(date +%s)" '.tickAt = $t'
  cmd_usage --quiet --renew
  watch
  if auto_update \
    && [ $(( $(date +%s) - $(jq -r '.updateCheckedAt // 0' "$STATE") )) -ge "$UPDATE_EVERY" ]; then
    cmd_self_update >/dev/null 2>&1
  fi
  return 0
}

# relay.sh self-update: bring this checkout up to its branch on GitHub (the timer does it every
# hour; "autoUpdate": false in config.json turns that off). Only ever a fast-forward of a clean
# checkout: one with changes of its own is left alone, and says so. relay.sh and the mod are
# links into the checkout, so the new version is in use from the next command; then the new
# relay.sh runs setup, for anything it added.
cmd_self_update() {
  local repo before after; repo=$(REPO)
  [ -f "$STATE" ] && jq_write "$STATE" --argjson t "$(date +%s)" '.updateCheckedAt = $t'
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "self-update: $repo isn't a git checkout" >&2; return 1; }
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    log "update: $repo has changes of its own; not updating it"; echo "self-update: $repo has changes of its own; not updating it" >&2; return 1
  fi
  before=$(git -C "$repo" rev-parse --short HEAD)
  if ! run_for 120 git -C "$repo" pull --ff-only --quiet >/dev/null 2>&1; then
    log "update: couldn't pull into $repo (no network, or its branch has moved apart from GitHub's)"; echo "self-update: couldn't pull; see $LOG" >&2; return 1
  fi
  after=$(git -C "$repo" rev-parse --short HEAD)
  if [ "$before" = "$after" ]; then echo "up to date ($after)"; return 0; fi
  log "update: $before -> $after ($(git -C "$repo" log -1 --format=%s))"
  [ -n "$LINUX" ] && /bin/bash "$repo/relay.sh" setup >/dev/null 2>&1
  echo "updated $before -> $after"
}

cmd_status_linux() {
  cmd_usage --quiet
  local cur id; cur=$(cli_account)
  echo "terminal claude: on $(account_field "$cur" name)${cur:+ ($cur)}"
  echo "auto-switch: $(armed && echo on || echo off)"
  echo "accounts:"
  for id in $(account_ids); do
    local until bench="" where; until=$(jq -r --arg a "$id" '.cooldowns[$a] // empty | select(fromdateiso8601 > now)' "$STATE")
    benched "$id" && bench="  (benched: automatic switches skip it)"
    if [ "$id" = "$cur" ]; then where="in use"
    elif cli_dead "$id"; then where="its parked login no longer works (relay.sh signin $(account_field "$id" name))"
    elif cli_parked "$id"; then where="parked, ready to switch to"
    else where="not signed in (relay.sh signin $(account_field "$id" name))"; fi
    echo "  $(account_field "$id" name)  $(account_field "$id" email)  $where${until:+  (out of usage until $until)}$bench"
    echo "      usage: $(usage_line "$id")"
  done
  local t; t=$(jq -r '.tickAt // 0' "$STATE")
  if systemctl --user is-active --quiet "$UNIT.timer" 2>/dev/null; then echo "timer: running$([ "$t" -gt 0 ] && echo ", last round $(( $(date +%s) - t ))s ago")"
  else echo "timer: not running (relay.sh setup)"; fi
  echo "version: $(git -C "$(REPO)" log -1 --format='%h %s' 2>/dev/null || echo unknown)"
}

cmd_doctor_linux() {
  local bad=0 id n cur line repo; repo=$(REPO)
  ok()   { echo "ok  $*"; }
  warn() { echo "~~  $*"; }
  fail() { echo "!!  $*"; bad=1; }
  command -v claude >/dev/null && ok "claude CLI: $(command -v claude)" || fail "the claude CLI isn't on the PATH this uses ($PATH)"
  [ -L "$DIR/relay.sh" ] && [ -e "$DIR/relay.sh" ] && ok "relay.sh -> $(readlink "$DIR/relay.sh")" || fail "$DIR/relay.sh is not a working link (relay.sh setup)"
  [ -L "$DIR/mod" ] && [ -e "$DIR/mod/hooks/hooks.json" ] && ok "mod -> $(readlink "$DIR/mod")" || fail "$DIR/mod is not a working link (relay.sh setup)"
  jq -e --arg p "$PLUGIN" '.enabledPlugins[$p] == true' "$HOME/.claude/settings.json" >/dev/null 2>&1 && ok "mod installed and enabled" || fail "mod not enabled (relay.sh setup)"
  n=$(jq '[.accounts[] | select(.accountUuid and .name)] | length' "$ACCOUNTS" 2>/dev/null || echo 0)
  [ "$n" -ge 2 ] && ok "$n accounts in accounts.json" || fail "$n account(s) in accounts.json; add another with relay.sh add <name>"
  cur=$(cli_account)
  if [ -z "$cur" ] || ! live_has; then fail "terminal claude isn't signed in (claude auth login)"
  elif [ -n "$(account_field "$cur" name)" ]; then ok "terminal claude is on $(account_field "$cur" name)"
  else fail "terminal claude is on $cur, which isn't set up here (relay.sh setup <name>)"; fi
  for id in $(account_ids); do benched "$id" && ok "$(account_field "$id" name) is benched: automatic switches skip it (relay.sh unbench $(account_field "$id" name))"; done
  [ "$n" -ge 2 ] && [ -n "$(bench_note)" ] && warn "$(bench_note)"
  for id in $(account_ids); do
    [ "$id" = "$cur" ] && continue
    if cli_dead "$id"; then fail "$(account_field "$id" name)'s parked login no longer works (used or revoked elsewhere after it was parked): relay.sh signin $(account_field "$id" name)"
    elif cli_parked "$id"; then ok "$(account_field "$id" name) has a parked login"
    else fail "$(account_field "$id" name) has no parked login: relay.sh signin $(account_field "$id" name)"; fi
  done
  while IFS= read -r line; do
    case "$line" in "ok "*) ok "${line#ok }" ;; "~~ "*) warn "${line#\~\~ }" ;; *) fail "${line#!! }" ;; esac
  done < <(cli_consumers)
  cmd_usage --quiet
  for id in $(account_ids); do ok "$(account_field "$id" name) usage: $(usage_line "$id") ($(usage_reach "$id"))"; done
  local t; t=$(jq -r '.tickAt // 0' "$STATE")
  if ! systemctl --user is-active --quiet "$UNIT.timer" 2>/dev/null; then fail "the timer isn't running, so nothing is switched or renewed by itself (relay.sh setup)"
  elif [ "$t" -gt 0 ] && [ $(( $(date +%s) - t )) -gt 1200 ]; then fail "the timer is on, but its last round was $(( ($(date +%s) - t) / 60 )) minutes ago (systemctl --user status $UNIT.service)"
  else ok "the timer is running$([ "$t" -gt 0 ] && echo " (last round $(( $(date +%s) - t ))s ago)")"; fi
  [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] && ok "the timer keeps running while you're logged out (linger)" \
    || warn "the timer stops when you log out of this machine: sudo loginctl enable-linger $USER"
  if ! auto_update; then warn "self-update is off (autoUpdate in config.json); this is $(git -C "$repo" rev-parse --short HEAD 2>/dev/null)"
  elif ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then warn "$repo isn't a git checkout, so it doesn't update itself"
  elif [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then warn "$repo has changes of its own, so it doesn't update itself"
  else ok "updates itself from GitHub every hour (now at $(git -C "$repo" rev-parse --short HEAD))"; fi
  [ -x "$DIR/notify" ] && ok "notifications go to $DIR/notify" || warn "nothing notifies you (it's all in relay.log): a program at $DIR/notify is run with each message"
  if lock_held; then ok "a switch, sign-in or timer round is running now ($(lock_owner))"
  else [ -d "$LOCK" ] && warn "a lock is left from a run that was cut off ($(lock_owner)); the next command takes it over" || ok "no switch running"; fi
  echo "auto-switch: $(armed && echo on || echo off)"
  return $bad
}

usage_linux() {
  cat <<EOF
Claude account switcher, on Linux: moves terminal claude's login (~/.claude/.credentials.json)
to your next account when the one in use runs out. A timer does it; these are for you.

Setting up
  setup <name>              first run on this machine, from the cloned repo; <name> is the
                            account terminal claude is signed in to
  add <name> [<email>]      sign in another account and add it as <name>: prints a link to open
                            in a browser signed in to it, and takes the code it gives back
  signin <name>             sign an account already added in again after its login stopped working
  remove <name>             take an account out
  doctor                    check the whole setup

Using it
  status                    accounts, usage, cooldowns, the timer
  usage [--force]           every account's usage from Anthropic (at most every 10 minutes unless --force)
  use <name>                move terminal claude to <name> now; running sessions follow
  bench <name>              leave <name> out of automatic switches (use <name> still works)
  unbench <name>            put <name> back in automatic switches
  history [<n>]             the last switches, sign-ins and updates
  run -- <claude args>      run claude, retrying once on the next account after a usage limit

Upkeep (the timer runs these)
  tick                      one round: read usage, switch if needed, renew parked logins, update
  cli-renew [<name>...] [--force]   renew parked logins whose token ran out
  self-update               pull the newest version of this repo now

Auto-switch is "armed" in $DIR/config.json; "switchAt" (default 95) is the
percent at which the timer moves on, and "autoUpdate": false stops the hourly self-update.
EOF
}

usage() {
  cat <<EOF
Claude Desktop account switcher. Day to day, use /account in a Code tab session.

Setting up
  setup <name>              first run on this Mac, from the cloned repo; <name> is the account Claude is on
  add <name>                sign in another account and add it as <name>, a name not used yet
                            (Claude restarts signed out for you)
  signin <name>             sign an account already added in again after its sign-in ran out
  remove <name>             take an account out
  doctor                    check the whole setup

Using it
  status                    accounts, usage, cooldowns, sessions waiting to reopen
  usage [--force]           every account's usage from Anthropic (at most every 10 minutes unless --force)
  use <name>                switch Claude to <name> now (restarts Claude)
  bench <name>              leave <name> out of automatic switches (use <name> still works)
  unbench <name>            put <name> back in automatic switches
  restart                   restart Claude on the same account, fixing anything that needs it closed
  history [<n>]             the last switches and sign-ins
  plan --from <accountUuid> what an out-of-usage switch would do, changing nothing

Terminal claude
  cli-login <name>          sign terminal claude in as <name> once, so it follows the app there
  cli-save                  park the current terminal login as its account's
  cli-use <name>            move terminal claude to <name>'s parked login
  cli-renew [<name>...] [--force]   renew parked terminal logins whose token ran out
  run -- <claude args>      run claude, retrying once on the next account after a usage limit

Upkeep
  keepalive [<days>] [--force]   renew parked sign-ins with fewer than <days> left
  install-keepalive              install the daily 04:30 keep-alive job
  resume                         reopen sessions still waiting from a switch

Commands that restart Claude (add, signin, use, restart) run as a launchd job, so they
work from inside Claude too, one at a time. add, signin, use and restart take
--resume <sessionId> to reopen a session afterwards.
EOF
}

# Created on first use; setup and help work before there's anything.
case "${1:-help}" in
  setup|help|-h|--help) ;;
  *)
    [ -f "$ACCOUNTS" ] || { echo "Not set up yet: run ./relay.sh setup <name> in the cloned repo." >&2; exit 1; }
    [ -f "$STATE" ] || echo '{"cooldowns":{},"switches":[]}' > "$STATE"
    [ -f "$HANDOFF" ] || echo '{"resume":[]}' > "$HANDOFF"
    [ -f "$USAGE" ] || echo "{}" > "$USAGE"
    mkdir -p "$DIR/backups" ;;
esac

cmd="${1:-help}"; [ $# -gt 0 ] && shift
# Linux: the terminal half only. Each command that moves or renews a login takes the lock, so
# the timer's round, a session's limit and a command by hand never work on a login together.
if [ -n "$LINUX" ]; then
  case "$cmd" in
    setup) cmd_setup_linux "$@" ;;
    add) ADDING=1 cmd_login_linux "$@" ;;
    signin|cli-login) cmd_login_linux "$@" ;;
    use|cli-use) cmd_use_linux "$@" ;;
    remove) cmd_remove "$@" ;;
    bench)  cmd_bench true "$@" ;;
    unbench) cmd_bench false "$@" ;;
    doctor) cmd_doctor_linux ;;
    status) cmd_status_linux ;;
    usage)  cmd_usage "$@" ;;
    history) cmd_history "$@" ;;
    tick) cmd_tick ;;
    self-update) cmd_self_update ;;
    cli-save) cmd_cli_save ;;
    cli-renew) lock_wait cli-renew "$LOCK_WAIT" || die "cli-renew: a switch or sign-in is running; try again when it's done"; cmd_cli_renew "$@" ;;
    cli-switch) lock_wait cli-switch "$LOCK_WAIT" || die "cli-switch: a switch or sign-in is running"; armed || exit 0; cmd_cli_switch "$@" ;;
    run) cmd_run "$@" ;;
    help|-h|--help) usage_linux ;;
    restart|resume|keepalive|install-keepalive|launch|switch|plan)
      echo "$cmd is for the desktop app, and Linux has none. See relay.sh help." >&2; exit 2 ;;
    *) usage_linux >&2; exit 2 ;;
  esac
  exit
fi
case "$cmd" in
  setup)  cmd_setup "$@" ;;
  add) [ -n "${1:-}" ] || die "add: which account? relay.sh add <name>"
    [ -z "$(account_by_name "$1")" ] || die "$1 is already set up; to sign it in again use relay.sh signin $1"
    now_or_job add "$@" ;;
  signin|signin-later) [ -n "${1:-}" ] || die "$cmd: which account? relay.sh $cmd <name>"
    [ -n "$(account_by_name "$1")" ] || die "$cmd: there's no account named $1; to add one use relay.sh add $1"
    now_or_job signin "$@" ;;
  use|swap|swap-later) [ -n "$(account_by_name "${1:-}")" ] || die "$cmd: no account named ${1:-}"; now_or_job swap "$@" ;;
  restart|restart-later) now_or_job restart "$@" ;;
  remove) cmd_remove "$@" ;;
  bench)  cmd_bench true "$@" ;;
  unbench) cmd_bench false "$@" ;;
  doctor) cmd_doctor ;;
  status) cmd_status ;;
  usage)  cmd_usage "$@" ;;
  history) cmd_history "$@" ;;
  plan)   cmd_plan "$@" ;;
  launch) cmd_launch "$@" ;;
  switch) cmd_switch "$@" ;;
  resume) cmd_resume ;;
  keepalive) cmd_keepalive "$@" ;;
  install-keepalive) cmd_install_keepalive ;;
  cli-save) cmd_cli_save ;;
  cli-use) cmd_cli_use "$@" ;;
  cli-renew) cmd_cli_renew "$@" ;;
  cli-login) cmd_cli_login "$@" ;;
  cli-switch) armed || exit 0; cmd_cli_switch "$@" ;;
  run) cmd_run "$@" ;;
  self-update) cmd_self_update ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
