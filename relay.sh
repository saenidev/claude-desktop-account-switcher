#!/bin/bash
# claude-desktop-account-switcher: switch Claude Desktop to another account in place
# when one runs out (or by hand), then reopen the sessions the switch cut off.
#
# The app's account is its claude.ai sign-in, the Cookies file in its one profile
# folder. Accounts not in use have theirs parked in $DIR/park/<accountUuid>/; a switch
# closes Claude, moves the sign-ins, and opens it again. Sign-ins are moved, never read; the
# one token used is a terminal login's, sent to Anthropic for usage (`relay.sh usage`), never
# printed or logged. See README.md, and `relay.sh help` for the commands.

set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

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
notify() { osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Claude account switcher"' -e 'end run' "$1" >/dev/null 2>&1 || true; }
die() { log "ERROR $*"; notify "$*"; echo "$*" >&2; exit 1; }
# Fixed waits (letting a turn finish, letting the app load). ACCOUNT_SWITCHER_FAST shortens them for tests.
pause() { if [ -n "${ACCOUNT_SWITCHER_FAST:-}" ]; then sleep 1; else sleep "$1"; fi; }

# Put the finished temp file $2 in place of $1, with $1's mode. Some of the files rewritten are
# private (claude_desktop_config.json is 0600 and can hold secrets), so temp files are made
# under umask 077 and only then given the original's mode.
replace_file() { local mode; mode=$(stat -f %Lp "$1" 2>/dev/null) && chmod "$mode" "$2"; mv "$2" "$1"; }
# A folder lock (mkdir is atomic) around a read, change and write of one file, for changes that
# can come at the same moment: the relay's own (a switch and the usage check started after
# every turn both write state.json) and the mod's in every session (handoff.json, usage.json).
# The mod takes the same lock (LOCK_SH there). One older than 10 seconds was left by a process
# that was killed. After 10 seconds without it the change goes ahead anyway rather than not at all.
LOCK_SH='i=0; until mkdir "$1" 2>/dev/null; do i=$((i+1)); [ $i -ge 100 ] && exit 1; [ $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || date +%s) )) -gt 10 ] && rmdir "$1" 2>/dev/null; sleep 0.1; done'
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
mtime() { stat -f %m "$1" 2>/dev/null; }
lock_stale() {
  local pid made started; made=$(mtime "$LOCK") || return 1
  pid=$(cat "$LOCK/pid" 2>/dev/null)
  # Made but no pid yet: its owner is between mkdir and writing it, or was killed there.
  if [ -z "$pid" ]; then [ $(( $(date +%s) - made )) -gt 60 ]; return; fi
  kill -0 "$pid" 2>/dev/null || return 0
  started=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ')
  started=$(LC_ALL=C date -j -f '%a %b %d %T %Y' "$started" +%s 2>/dev/null) || return 1
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
    | jq -sc --argjson now "$(date +%s)000" '[.[] | select(.sessionId and .busy != false and ($now - (.at // 0)) < 21600000)]')
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
shipit_running() { pgrep -f 'Squirrel.framework/Resources/ShipIt' >/dev/null; }
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

# The first other account whose cooldown has passed and whose last usage reading has no
# window used up, in accounts.json order after $1. A used-up window that hasn't reset yet is
# still used up however old the reading is: usage only goes down at a reset. Windows counted:
# 5-hour and weekly, and the model's own weekly limit named in $2 (say "Fable weekly") when
# that is what ran out. $3, if given, lists the only accounts to consider (one id a line).
# If usage.json can't be read (a bad file, a time jq can't parse), the switch still happens:
# it's logged, and the pick is made again without the usage figures.
pick_target() {
  local from="$1" label="${2:-}" only="${3:-}" now out err; now=$(date -u +%s)
  local prog='
    def epoch: sub("\\.[0-9]+";"") | sub("[+]00:00$";"Z") | fromdateiso8601;
    def spent($a): [($u[0][$a].windows // [])[]
      | select(.kind == "five_hour" or .kind == "seven_day" or ($label != "" and .label == $label))
      | select(.percentUsed >= 100 and ((.resetsAt // "") != "") and ((.resetsAt | epoch) > $now))] | length > 0;
    ($only | split("\n") | map(select(. != ""))) as $only
    | (.accounts | map(.accountUuid // empty)) as $ids
    | ($ids | index($from) // -1) as $i
    | [range(1; ($ids | length) + 1)] | map($ids[($i + .) % ($ids | length)])
    | map(select(. != $from))
    | map(select(($only | length) == 0 or (. as $a | $only | index($a))))
    | map(select((($st[0].cooldowns[.] // "1970-01-01T00:00:00Z") | epoch) <= $now))
    | map(select(spent(.) | not))
    | .[0] // empty'
  local args=(-r --arg from "$from" --arg label "$label" --arg only "$only" --argjson now "$now" --slurpfile st "$STATE")
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
      log "keepalive: $name renewed, now good until $(date -u -r "$after" '+%F %T') UTC"
    else
      log "keepalive: $name not renewed; expires $(date -u -r "$exp" '+%F %T') UTC"
      [ "$left" -le 3 ] && notify "$name's sign-in expires in $left days and couldn't be renewed. Run relay.sh signin $name."
    fi
  done
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
    b="$DIR/backups/$(date +%Y%m%d-%H%M%S)-keepalive-leftover"; mkdir -p "$b"
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

# A switch writes swap.inflight ("<from> <to>") just before it moves the sign-ins, and removes
# it once the new account is up or the old one is back. Found later, the switch was cut off
# half-way (the Mac shut down, the job was killed): Claude's Cookies may be <to>'s while the
# app still reports <from>, and moving them now would park <to>'s sign-in as <from>'s. If the
# app came up on <to>, the switch had worked; otherwise put <from>'s sign-in back.
SWAPPING="$DIR/swap.inflight"
swap_names() { local f t; read -r f t < "$SWAPPING"; echo "$(account_field "$f" name) to $(account_field "$t" name)"; }
# With "open" (the switch's own undo, as it's killed), Claude is opened again even if the
# switch had closed it.
finish_swap() {
  local from to was="${1:-}"; read -r from to < "$SWAPPING"
  if [ -n "$to" ] && [ "$(folder_account "$DEFAULT_DIR")" = "$to" ]; then
    log "recover: the cut-off switch to $(account_field "$to" name) had worked"
    rm -f "$SWAPPING"; swap_cli "$to"; return 0
  fi
  [ -n "$(default_pids)" ] && { quit_default; was=1; }
  # How far the move got (park the current sign-in, then bring the new one in): Claude holds
  # <to>'s sign-in only once nothing is left parked for <to>; <from>'s is still in Claude
  # until it has been parked.
  [ -n "$to" ] && [ ! -e "$PARK/$to/Cookies" ] && [ -e "$DEFAULT_DIR/Cookies" ] && move_pair "$DEFAULT_DIR" "$PARK/$to"
  [ -n "$from" ] && [ -e "$PARK/$from/Cookies" ] && [ ! -e "$DEFAULT_DIR/Cookies" ] && move_pair "$PARK/$from" "$DEFAULT_DIR"
  rm -f "$SWAPPING"
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
cli_parked() { security find-generic-password -s "$CLI_PARK_SVC" -a "$1" >/dev/null 2>&1; }
keychain_put() {   # keychain_put <service> <account>, the secret on stdin
  local v hex; v=$(cat)   # $(...) drops the newline `security -w` adds after the value
  [ -n "$v" ] || return 1
  hex=$(printf '%s' "$v" | xxd -p | tr -d '\n'); v=""
  printf 'add-generic-password -U -s "%s" -a "%s" -X %s\n' "$1" "$2" "$hex" | security -i >/dev/null 2>&1
}
# A fingerprint of a Keychain item's secret (service $1, account $2), to tell two apart
# without either being printed: the secret goes from security to shasum through a pipe.
keychain_digest() { security find-generic-password -s "$1" -a "$2" -w 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }
cli_park() {       # save the live terminal login as <uuid>'s parked one
  local id="$1" other live
  # The live login byte for byte the same as another account's parked one means the live
  # item holds that account's token while ~/.claude.json says <uuid>: parking it would put
  # the wrong account's login under <uuid>.
  live=$(keychain_digest "$CLI_SVC" "$USER")
  for other in $(account_ids); do
    [ "$other" = "$id" ] && continue
    if cli_parked "$other" && [ "$(keychain_digest "$CLI_PARK_SVC" "$other")" = "$live" ]; then
      log "terminal: the live terminal login is the same as $(account_field "$other" name)'s parked one, not $(account_field "$id" name)'s; not parking it as $(account_field "$id" name)"
      return 1
    fi
  done
  security find-generic-password -s "$CLI_SVC" -a "$USER" -w 2>/dev/null | keychain_put "$CLI_PARK_SVC" "$id" || return 1
  mkdir -p "$PARK/$id"; jq '.oauthAccount' "$HOME/.claude.json" > "$PARK/$id/oauthAccount.json"
}
cli_restore() {    # make <uuid>'s parked login the live terminal login
  local id="$1" tmp
  security find-generic-password -s "$CLI_PARK_SVC" -a "$id" -w 2>/dev/null | keychain_put "$CLI_SVC" "$USER" || return 1
  if [ -f "$CLI_MIRROR" ]; then
    tmp="$CLI_MIRROR.tmp.$$"; ( umask 077; security find-generic-password -s "$CLI_PARK_SVC" -a "$id" -w > "$tmp" 2>/dev/null ) && mv "$tmp" "$CLI_MIRROR"
  fi
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
  # With no live login there's nothing to save first (logged out, or the item was deleted).
  if [ -n "$cur" ] && security find-generic-password -s "$CLI_SVC" -a "$USER" >/dev/null 2>&1 && ! cli_park "$cur"; then
    log "terminal: couldn't save $(account_field "$cur" name)'s terminal login; not swapping"; return 1
  fi
  cli_restore "$target" && log "terminal: $(account_field "$cur" name) -> $(account_field "$target" name)"
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
# A terminal run hit the limit: cool that account down and move only the terminal login.
cmd_cli_switch() {
  local from; from=$(cli_account); [ -n "$from" ] || die "cli-switch: terminal isn't logged in"
  local until="${1:-$(date -u -v+5H +%FT%TZ)}"
  jq_write "$STATE" --arg a "$from" --arg u "$until" '.cooldowns[$a] = $u'
  # Only accounts with a parked terminal login: the terminal can't move to any other.
  local id ready="" target
  for id in $(account_ids); do cli_parked "$id" && ready+="$id"$'\n'; done
  [ -n "$ready" ] && target=$(pick_target "$from" "" "$ready")
  [ -n "${target:-}" ] || { log "terminal: $(account_field "$from" name) is out, and no other account with a parked terminal login has usage"; notify "Terminal: every account with a terminal login is out of usage."; return 1; }
  swap_cli "$target"
}

# Run a scripted claude, and if it fails on a usage limit, move the terminal login to the
# next account and run it once more (after caam's `run`). Output passes through unchanged.
#   relay.sh run -- -p "prompt" [claude args...]
cmd_run() {
  [ "${1:-}" = "--" ] && shift
  local rc; RUN_OUT=$(mktemp -t relay-run)   # on_exit removes it, however this ends
  # stdout and stderr each stay where they were, and both are copied to the file for the check.
  claude "$@" 2> >(tee -a "$RUN_OUT" >&2) | tee -a "$RUN_OUT"; rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ] && grep -qiE "hit your (weekly|5-hour) limit|usage limit reached|out of (extra )?usage" "$RUN_OUT"; then
    log "run: claude hit a limit on $(account_field "$(cli_account)" name)'s terminal login; switching and retrying once"
    if cmd_cli_switch; then claude "$@"; rc=$?; fi
  fi
  return "$rc"
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
  done
  local tcur; tcur=$(cli_account)
  if [ -z "$tcur" ]; then warn "terminal claude isn't logged in; it won't follow the app"
  else
    [ -n "$(account_field "$tcur" name)" ] && ok "terminal claude is on $(account_field "$tcur" name)" || fail "terminal claude is on $tcur, not an account in accounts.json"
    for id in $(account_ids); do
      [ "$id" = "$tcur" ] && continue
      cli_parked "$id" && ok "$(account_field "$id" name) has a parked terminal login" \
        || warn "$(account_field "$id" name) has no parked terminal login, so terminal claude stays put when the app moves to it: relay.sh cli-save, claude /login as $(account_field "$id" name), relay.sh cli-save, then relay.sh cli-use $(account_field "$tcur" name)"
    done
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
  grep -E 'swap: [^ ]+ -> |switch: .* is out|signin: |keepalive: .*(renewed|not renewed)|launched relay away|not switching|removed ' "$LOG" | tail -n "${1:-20}"
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
  if [ "$(cli_account)" = "$1" ]; then security find-generic-password -s "$CLI_SVC" -a "$USER" -w 2>/dev/null
  else security find-generic-password -s "$CLI_PARK_SVC" -a "$1" -w 2>/dev/null; fi
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

# Whether account $1's usage can be read from Anthropic now, and if not, why.
usage_reach() {
  local exp; exp=$(cli_login "$1" | jq -r '(.claudeAiOauth.expiresAt // 0) / 1000 | floor' 2>/dev/null)
  if [ -z "$exp" ]; then echo "not read live: no terminal login (relay.sh cli-save)"
  elif [ "$exp" -le "$(date +%s)" ]; then echo "not read live: its parked terminal login's token expired $(( ($(date +%s) - exp) / 3600 ))h ago"
  else echo "read live from Anthropic"; fi
}

# relay.sh usage [--force]: read every account's usage from Anthropic into usage.json (at most
# every 10 minutes unless --force; after a 429, not before the wait is over), then print it.
cmd_usage() {
  local force="" quiet="" a
  for a in "$@"; do case "$a" in --force) force=1 ;; --quiet) quiet=1 ;; esac; done
  local now last until; now=$(date -u +%s)
  last=$(jq -r '.usageCheckedAt // 0' "$STATE"); until=$(jq -r '.usageWaitUntil // 0' "$STATE")
  # A check takes 30 seconds at most; a lock older than 2 minutes is left from one that was killed.
  [ -n "$(find "$USAGE_LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$USAGE_LOCK"
  if [ "$now" -lt "$until" ]; then :
  elif { [ -n "$force" ] || [ $((now - last)) -ge $USAGE_EVERY ]; } && mkdir "$USAGE_LOCK" 2>/dev/null; then
    local id windows rc
    for id in $(account_ids); do
      windows=$(fetch_usage "$id"); rc=$?
      case $rc in
        0) jq_write "$USAGE" --arg a "$id" --argjson w "$windows" --argjson at "$(date +%s)000" '.[$a] = {at: $at, source: "anthropic", windows: $w}' ;;
        2) jq_write "$STATE" --argjson t $((now + 900)) '.usageWaitUntil = $t'
           log "usage: Anthropic is rate-limiting usage checks; next try in 15 minutes"; break ;;
        3) log "usage: couldn't read $(account_field "$id" name)'s usage from Anthropic" ;;
      esac
    done
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
    local until; until=$(jq -r --arg a "$id" '.cooldowns[$a] // empty' "$STATE")
    echo "  $(account_field "$id" name)  $(account_field "$id" email)  $(signin_state "$id")${until:+  (out of usage until $until)}"
    echo "      usage: $(usage_line "$id")"
  done
  echo "pending resumes:"; jq -r '.resume[] | "  \(.sessionId)  (\(.reason))"' "$HANDOFF"
}

cmd_plan() {
  parse_args "$@"
  local ready target=""; ready=$(switch_ready)
  [ -n "$ready" ] && target=$(pick_target "$FROM" "$LIMIT" "$ready")
  echo "from:   $(account_field "$FROM" name) ($FROM): $(signin_state "$FROM")${LIMIT:+, out of $LIMIT}"
  if [ -z "$target" ]; then echo "to:     nobody: every other account is cooling down, used up or signed out"; return; fi
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
    b="$DIR/backups/$(date +%Y%m%d-%H%M%S)-${3:-replaced-signin}"; mkdir -p "$b"
    for f in Cookies Cookies-journal; do [ -e "$to/$f" ] && mv -f "$to/$f" "$b/$f"; done
    log "signin: ${to#$DIR/} already held a sign-in; it's kept in ${b#$DIR/}"
  fi
  for f in Cookies Cookies-journal; do [ -e "$from/$f" ] && mv -f "$from/$f" "$to/$f"; done
  return 0
}

# Move the sign-in files: park the folder's current ones under $1, bring $2's in.
move_signin() { move_pair "$DEFAULT_DIR" "$PARK/$1"; move_pair "$PARK/$2" "$DEFAULT_DIR"; }

# Everything done while Claude is closed, whatever closed it.
while_closed() {
  apply_prefs_patch
  fix_scratch_paths
  drop_old_link
  fill_orgs
  link_sessions
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
  move_signin "$cur" "$target"
  while_closed
  mirror_prefs "$cur" "$target"
  mirror_rc "$cur" "$target"
  open_app
  # 45 seconds for the new sign-in to come up (ACCOUNT_SWITCHER_FAST: 10, for the tests).
  local n=0 max=45; [ -n "${ACCOUNT_SWITCHER_FAST:-}" ] && max=10
  while [ "$(folder_account "$DEFAULT_DIR")" != "$target" ] && [ $n -lt $max ]; do sleep 1; n=$((n+1)); done
  if [ "$(folder_account "$DEFAULT_DIR")" = "$target" ]; then
    rm -f "$SWAPPING"; UNDO=""
    log "swap: $(account_field "$cur" name) -> $(account_field "$target" name)"
    swap_cli "$target"   # terminal claude follows, when a parked terminal login exists
    return 0
  fi
  log "swap: $(account_field "$target" name)'s sign-in did not come up; going back to $(account_field "$cur" name)"
  quit_default
  move_signin "$target" "$cur"
  rm -f "$SWAPPING"; UNDO=""
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
    2) jq_write "$STATE" --arg a "$FROM" --arg u "${RESETS_AT:-$(date -u -v+5H +%FT%TZ)}" '.cooldowns[$a] = $u'
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

  local until="${RESETS_AT:-$(date -u -v+5H +%FT%TZ)}"
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
    notify "$(account_field "$FROM" name) is out of usage, and every other account is too (or signed out)."
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

# A one-off settings fix ($DIR/prefs-patch.json), merged in the next time Claude is closed.
apply_prefs_patch() {
  [ -f "$DIR/prefs-patch.json" ] || return 0
  cp -p "$PREFS" "$DIR/backups/claude_desktop_config.before-patch.json"
  jq_write "$PREFS" --slurpfile patch "$DIR/prefs-patch.json" '. * $patch[0]' \
    && mv "$DIR/prefs-patch.json" "$DIR/backups/prefs-patch.applied.json" && log "prefs: patch applied"
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
# gets its link even before the app makes the folder. Only while Claude is closed: the
# running app rewrites session files.
link_sessions() {
  local stamp kind root canon d id org f moved first; stamp=$(date +%Y%m%d-%H%M%S)
  first=$(jq -r '[.accounts[] | select(.accountUuid and .orgUuid)] | if length >= 2 then .[0].accountUuid else empty end' "$ACCOUNTS")
  for kind in claude-code-sessions local-agent-mode-sessions; do
    root="$DEFAULT_DIR/$kind"; canon=$(shared_list "$kind")
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
  done
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
    move_signin "$new" "$cur"
    while_closed
  else
    # Whatever the app was left holding (signed out, or another account than the one asked
    # for) goes to backups/; the previous account's sign-in comes back whole.
    move_pair "$PARK/$cur" "$DEFAULT_DIR" unused-signin
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
    else move_pair "$DEFAULT_DIR" "$DIR/backups/$(date +%Y%m%d-%H%M%S)-cut-off-signin"; fi
  fi
  # Anything else left in the profile (a signed-out Cookies) goes to backups/ as it comes back.
  [ -e "$PARK/$cur/Cookies" ] && move_pair "$PARK/$cur" "$DEFAULT_DIR" signed-out-cookies
  log "signin: cut off; put $(account_field "$cur" name)'s sign-in back"
  open_app
}

# relay.sh add <name> [--resume <sessionId>]: sign in a new account and add it as <name>,
# which must not be in accounts.json yet (to sign an account in again: relay.sh signin <name>).
cmd_add() { ADDING=1 cmd_signin "$@"; }

# Take an account out: its parked sign-in moves to backups/ (still signed in there until you
# delete it), its parked terminal login is deleted, and it's dropped from accounts.json.
cmd_remove() {
  local name="${1:-}" id; id=$(account_by_name "$name"); [ -n "$id" ] || die "remove: no account named $name"
  # Not while a switch, sign-in or keep-alive may be moving this account's sign-in.
  lock_or_die remove
  recover_signin
  [ "$id" = "$(folder_account "$DEFAULT_DIR")" ] && die "remove: Claude is on $name now; switch to another account first (relay.sh use <name>)"
  local b; b="$DIR/backups/$(date +%Y%m%d-%H%M%S)-removed-$name"; mkdir -p "$b"
  jq --arg u "$id" '.accounts[] | select(.accountUuid == $u)' "$ACCOUNTS" > "$b/account.json"
  [ -d "$PARK/$id" ] && mv "$PARK/$id" "$b/park"
  cli_parked "$id" && security delete-generic-password -s "$CLI_PARK_SVC" -a "$id" >/dev/null 2>&1
  jq_write "$ACCOUNTS" --arg u "$id" 'del(.accounts[] | select(.accountUuid == $u))'
  jq_write "$STATE" --arg u "$id" 'del(.cooldowns[$u])'
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
  if jq -e --arg p "$PLUGIN" '.enabledPlugins[$p] == true' "$HOME/.claude/settings.json" >/dev/null 2>&1; then echo "ok  mod installed"
  else
    command -v claude >/dev/null || die "setup: needs the claude CLI to install the mod (https://claude.com/claude-code)"
    claude plugin marketplace add "$DIR/mod" >/dev/null && claude plugin install "$PLUGIN" --scope user >/dev/null || die "setup: installing the mod failed"
    echo "ok  mod installed (new Code tab sessions pick it up)"
  fi
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
  restart                   restart Claude on the same account, fixing anything that needs it closed
  history [<n>]             the last switches and sign-ins
  plan --from <accountUuid> what an out-of-usage switch would do, changing nothing

Terminal claude
  cli-save                  park the current terminal login as its account's
  cli-use <name>            move terminal claude to <name>'s parked login
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
  cli-switch) cmd_cli_switch "$@" ;;
  run) cmd_run "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
