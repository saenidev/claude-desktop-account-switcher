#!/bin/bash
# claude-desktop-account-switcher: switch Claude Desktop to another account in place
# when one runs out (or by hand), then reopen the sessions the switch cut off.
#
# The app's account is its claude.ai sign-in, the Cookies file in its one profile
# folder. Accounts not in use have theirs parked in $DIR/park/<accountUuid>/; a switch
# closes Claude, moves the sign-ins, and opens it again. Never reads, copies or prints
# a token. See README.md, and `relay.sh help` for the commands.

set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DIR="$HOME/.claude/desktop-account-switcher"
ACCOUNTS="$DIR/accounts.json"
STATE="$DIR/state.json"
HANDOFF="$DIR/handoff.json"
LOG="$DIR/relay.log"
LOCK="$DIR/switch.lock"
PARK="$DIR/park"
# The app to switch. Tests point this at a stand-in app; nobody else needs to.
APP="${ACCOUNT_SWITCHER_APP:-/Applications/Claude.app}"
BIN="$APP/Contents/MacOS/Claude"
DEFAULT_DIR="$HOME/Library/Application Support/Claude"
PREFS="$DEFAULT_DIR/claude_desktop_config.json"
LABEL="local.desktop-account-switcher"
OLD_LABEL="com.jun.desktop-account-switcher"
PLUGIN="desktop-account-switcher@desktop-account-switcher-local"
# Claude Desktop versions this was checked against by hand (version prefixes). Others still
# switch, after check_app, but doctor says they're untested.
TESTED_VERSIONS="3.1623"

# This script's own folder, through the link in $DIR.
REPO() { local s="${BASH_SOURCE[0]}"; while [ -L "$s" ]; do s=$(readlink "$s"); done; cd "$(dirname "$s")" && pwd; }

log() { [ -d "$DIR" ] && printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; return 0; }
notify() { osascript -e "display notification \"$1\" with title \"Claude account switcher\"" >/dev/null 2>&1 || true; }
die() { log "ERROR $*"; notify "$*"; echo "$*" >&2; exit 1; }
# Fixed waits (letting a turn finish, letting the app load). ACCOUNT_SWITCHER_FAST shortens them for tests.
pause() { if [ -n "${ACCOUNT_SWITCHER_FAST:-}" ]; then sleep 1; else sleep "$1"; fi; }

# Write JSON atomically so a reader never sees half a file.
jq_write() { local file="$1"; shift; local tmp="$file.tmp.$$"; jq "$@" "$file" > "$tmp" && mv "$tmp" "$file"; }

account_field() { jq -r --arg u "$1" --arg f "$2" '.accounts[] | select(.accountUuid == $u) | .[$f] // empty' "$ACCOUNTS"; }
account_by_name() { jq -r --arg n "$1" '.accounts[] | select(.name == $n) | .accountUuid // empty' "$ACCOUNTS"; }
account_ids() { jq -r '.accounts[].accountUuid // empty' "$ACCOUNTS"; }

# The account the app in $1 last signed in as, from its own config.json (an id, not a secret).
folder_account() { jq -r '.lastKnownAccountUuid // empty' "$1/config.json" 2>/dev/null; }

app_version() { plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null; }
version_tested() { local v; v=$(app_version); for t in $TESTED_VERSIONS; do [[ "$v" == "$t" || "$v" == "$t".* ]] && return 0; done; return 1; }

# Claude Desktop keeps its sign-in and session list in files it never promised to keep the
# same. Before closing Claude to move anything, check they're where this expects; an app
# update that moved them stops the switch instead of losing a sign-in. Prints what's wrong.
check_app() {
  [ -n "$(folder_account "$DEFAULT_DIR")" ] || { echo "config.json has no lastKnownAccountUuid"; return 1; }
  [ "$(sqlite3 "file:$DEFAULT_DIR/Cookies?mode=ro&immutable=1" "select count(*) from cookies where name='sessionKey'" 2>/dev/null)" = 1 ] \
    || { echo "Cookies holds no claude.ai sign-in"; return 1; }
  [ -d "$DEFAULT_DIR/claude-code-sessions" ] || { echo "there's no claude-code-sessions folder"; return 1; }
}

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
  # The mod honours a hand-off entry only if Claude was closed after it was written.
  jq_write "$HANDOFF" --arg at "$(date -u +%FT%TZ)" '.closedAt = $at'
  kill -TERM $pids 2>/dev/null
  for pid in $pids; do wait_gone "$pid" 30 || { kill -KILL "$pid"; wait_gone "$pid" 5; }; done
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
  <key>EnvironmentVariables</key><dict><key>ACCOUNT_SWITCHER_JOB</key><string>1</string>$( [ -n "${ACCOUNT_SWITCHER_APP:-}" ] && printf '<key>ACCOUNT_SWITCHER_APP</key><string>%s</string>' "$ACCOUNT_SWITCHER_APP" )$( [ -n "${ACCOUNT_SWITCHER_FAST:-}" ] && printf '<key>ACCOUNT_SWITCHER_FAST</key><string>1</string>' )</dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.out</string>
</dict></plist>
EOF
  launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$uid" "$plist"
}

# Run "$@" now if this is already the launchd job, else queue it as one.
now_or_job() {
  if in_job; then "cmd_$1" "${@:2}"; return; fi
  run_job "$@" || die "couldn't start $1 under launchd"
  log "$1 ${2:-}: queued under launchd"
  echo "Started. Claude closes in about 10 seconds; progress is in $LOG."
}

# ---- Choosing an account ---------------------------------------------------------------------

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

# The first other account whose cooldown has passed, in accounts.json order after $1.
pick_target() {
  local from="$1" now; now=$(date -u +%s)
  jq -r --arg from "$from" --argjson now "$now" --slurpfile st "$STATE" '
    (.accounts | map(.accountUuid // empty)) as $ids
    | ($ids | index($from) // -1) as $i
    | [range(1; ($ids | length) + 1)] | map($ids[($i + .) % ($ids | length)])
    | map(select(. != $from))
    | map(select((($st[0].cooldowns[.] // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+";"") | fromdateiso8601) <= $now))
    | .[0] // empty' "$ACCOUNTS"
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
    if [ -z "$force" ] && [ "$left" -gt "$days" ]; then log "keepalive: $name good for $left more days"; continue; fi
    refresh_parked "$id"
    local after; after=$(signin_expires_epoch "$id")
    if [ "$after" -gt "$exp" ]; then
      log "keepalive: $name renewed, now good until $(date -u -r "$after" '+%F %T') UTC"
    else
      log "keepalive: $name not renewed; expires $(date -u -r "$exp" '+%F %T') UTC"
      [ "$left" -le 3 ] && notify "$name's sign-in expires in $left days and couldn't be renewed. Run relay.sh signin $name."
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
  if [ "$(folder_account "$KEEP")" = "$id" ]; then pause 20; else log "keepalive: $(account_field "$id" name)'s sign-in did not load in the background instance"; fi
  pid=$(instance_pid "$KEEP"); [ -n "$pid" ] && quit_pid "$pid"
  for f in Cookies Cookies-journal; do [ -e "$KEEP/$f" ] && mv -f "$KEEP/$f" "$PARK/$id/$f"; done
  rmdir "$LOCK" 2>/dev/null
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
cli_park() {       # save the live terminal login as <uuid>'s parked one
  local id="$1"
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
# Move terminal claude to <uuid> if a parked login exists for it; otherwise leave it alone.
swap_cli() {
  local target="$1" cur; cur=$(cli_account)
  [ "$cur" = "$target" ] && return 0
  if ! cli_parked "$target"; then log "terminal: no parked terminal login for $(account_field "$target" name); terminal stays on $(account_field "$cur" name)"; return 0; fi
  if [ -n "$cur" ] && ! cli_park "$cur"; then log "terminal: couldn't save $(account_field "$cur" name)'s terminal login; not swapping"; return 1; fi
  cli_restore "$target" && log "terminal: $(account_field "$cur" name) -> $(account_field "$target" name)"
}
# Save the live terminal login as its account's parked copy (run once per account after `claude /login`).
cmd_cli_save() {
  local cur; cur=$(cli_account); [ -n "$(account_field "$cur" name)" ] || die "terminal is logged in as ${cur:-nobody}, not an account in accounts.json"
  cli_park "$cur" && log "terminal: saved $(account_field "$cur" name)'s terminal login" && echo "saved $(account_field "$cur" name)'s terminal login"
}
cmd_cli_use() {
  local id; id=$(account_by_name "${1:-}"); [ -n "$id" ] || die "cli-use: no account named ${1:-}"
  swap_cli "$id" && echo "terminal claude is on $(account_field "$(cli_account)" name)"
}
# A terminal run hit the limit: cool that account down and move only the terminal login.
cmd_cli_switch() {
  local from; from=$(cli_account); [ -n "$from" ] || die "cli-switch: terminal isn't logged in"
  local until="${1:-$(date -u -v+5H +%FT%TZ)}"
  jq_write "$STATE" --arg a "$from" --arg u "$until" '.cooldowns[$a] = $u'
  local target; target=$(pick_target "$from")
  [ -n "$target" ] || { log "terminal: $(account_field "$from" name) is out and so is every other account"; notify "Terminal: every account is out of usage."; return 1; }
  swap_cli "$target"
}

# Run a scripted claude, and if it fails on a usage limit, move the terminal login to the
# next account and run it once more (after caam's `run`). Output passes through unchanged.
#   relay.sh run -- -p "prompt" [claude args...]
cmd_run() {
  [ "${1:-}" = "--" ] && shift
  local out rc; out=$(mktemp -t relay-run)
  claude "$@" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ] && grep -qiE "hit your (weekly|5-hour) limit|usage limit reached|out of (extra )?usage" "$out"; then
    log "run: claude hit a limit on $(account_field "$(cli_account)" name)'s terminal login; switching and retrying once"
    if cmd_cli_switch; then claude "$@"; rc=$?; fi
  fi
  rm -f "$out"; return "$rc"
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
  why=$(check_app) && ok "Claude's sign-in and session files are where the switcher expects" || fail "Claude's files aren't where the switcher expects ($why): switching is off until this is fixed"
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
  launchctl print "gui/$(id -u)/$LABEL.keepalive" >/dev/null 2>&1 && ok "daily keep-alive installed" || fail "daily keep-alive not installed (relay.sh install-keepalive)"
  [ -d "$LOCK" ] && fail "a switch lock is held ($LOCK); remove it if no switch is running" || ok "no switch running"
  echo "auto-switch: $(jq -r 'if .armed then "on" else "off" end' "$DIR/config.json" 2>/dev/null || echo off)"
  return $bad
}

# Recent switches and sign-in events, newest last (after caam's history).
cmd_history() {
  grep -E 'swap: [^ ]+ -> |switch: .* is out|signin: |keepalive: .*(renewed|not renewed)|launched relay away|not switching|removed ' "$LOG" | tail -n "${1:-20}"
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
  else echo "not signed in (relay.sh signin $(account_field "$1" name))"; fi
}

cmd_status() {
  local pid; pid=$(default_pids | head -1)
  if [ -n "$pid" ]; then echo "Claude: running (pid $pid)"; else echo "Claude: not running"; fi
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
  local target; target=$(pick_target "$FROM")
  echo "from:   $(account_field "$FROM" name) ($FROM): $(signin_state "$FROM")"
  if [ -z "$target" ]; then echo "to:     nobody: every other account is cooling down"; return; fi
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

# Move the sign-in files: park the folder's current ones under $1, bring $2's in.
move_signin() {
  local out="$1" in="$2" f
  mkdir -p "$PARK/$out"
  for f in Cookies Cookies-journal; do [ -e "$DEFAULT_DIR/$f" ] && mv "$DEFAULT_DIR/$f" "$PARK/$out/$f"; done
  for f in Cookies Cookies-journal; do [ -e "$PARK/$in/$f" ] && mv "$PARK/$in/$f" "$DEFAULT_DIR/$f"; done
  return 0
}

# Everything done while Claude is closed, whatever closed it.
while_closed() {
  apply_prefs_patch
  fix_scratch_paths
  drop_old_link
  fill_orgs
  link_sessions
}

# Switch the one Claude window to account $1 (a uuid). Returns non-zero, with the
# previous account restored, if the new sign-in doesn't come up.
swap_to() {
  local target="$1" cur why; cur=$(folder_account "$DEFAULT_DIR")
  [ "$cur" = "$target" ] && { log "swap: already on $(account_field "$target" name)"; return 0; }
  [ -f "$PARK/$target/Cookies" ] || { log "swap: no parked sign-in for $(account_field "$target" name)"; return 1; }
  why=$(check_app) || { log "swap: not switching: $why (Claude Desktop $(app_version) may keep it elsewhere now)"; notify "Not switching: Claude's files changed ($why). Run relay.sh doctor."; return 1; }
  quit_default
  move_signin "$cur" "$target"
  while_closed
  mirror_prefs "$cur" "$target"
  mirror_rc "$cur" "$target"
  open_app
  local n=0; while [ "$(folder_account "$DEFAULT_DIR")" != "$target" ] && [ $n -lt 45 ]; do sleep 1; n=$((n+1)); done
  if [ "$(folder_account "$DEFAULT_DIR")" = "$target" ]; then
    log "swap: $(account_field "$cur" name) -> $(account_field "$target" name)"
    swap_cli "$target"   # terminal claude follows, when a parked terminal login exists
    return 0
  fi
  log "swap: $(account_field "$target" name)'s sign-in did not come up; going back to $(account_field "$cur" name)"
  quit_default
  move_signin "$target" "$cur"
  open_app
  return 1
}

# List a session to reopen, with why, before Claude closes: the app may bring the session
# back by itself before any link is sent, and the mod only sees entries already written.
hand_off() {
  jq_write "$HANDOFF" --arg s "$1" --arg r "$2" --arg at "$(date -u +%FT%TZ)" \
    '.resume = ([.resume[] | select(.sessionId != $s)] + [{sessionId: $s, cwd: "", reason: $r, at: $at}])'
}
drop_hand_off() { jq_write "$HANDOFF" --arg s "$1" '.resume |= map(select(.sessionId != $s))'; }
# The entries the mod wrote for a usage limit, when no switch happened after all.
drop_limit_hand_offs() {
  jq_write "$HANDOFF" '.resume |= map(select(.reason | test("^(limit hit|mid-turn)") | not))'
  log "switch: dropped the hand-off entries for this limit"
}

# Reopen the handed-off sessions in the Claude window.
reopen_handoff() {
  local ids id; ids=$(jq -r '.resume[].sessionId' "$HANDOFF")
  for id in $ids; do send_link "claude://resume?session=$id" && log "switch: reopened session $id"; sleep 3; done
  echo "$ids" | grep -c .
}

cmd_resume() {
  [ -n "$(default_pids)" ] || die "resume: Claude isn't running"
  reopen_handoff >/dev/null
}

# Out of usage: what the mod starts (launch), and what the launchd job runs (switch).
cmd_launch() {
  parse_args "$@"
  [ -n "$FROM" ] || die "launch needs --from"
  run_job switch --from "$FROM" --resets-at "${RESETS_AT:-}" && log "launch: switch away from $FROM queued under launchd"
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
    drop_limit_hand_offs
    die "switch: no account to switch to"
  fi
  swap_to "$target" || { drop_limit_hand_offs; die "could not switch to $(account_field "$target" name); stayed on $(account_field "$FROM" name)"; }
  jq_write "$STATE" --arg f "$FROM" --arg t "$target" --argjson at "$(date -u +%s)" '.switches += [{from: $f, to: $t, at: $at}] | .switches |= .[-20:]'
  pause 12   # let the app load before handing it links
  local n; n=$(reopen_handoff)
  notify "Switched to $(account_field "$target" name). Reopened $n session(s)."
  log "switch: done"
}

# By hand: relay.sh use <name> [--resume <sessionId>].
cmd_swap() {
  local id; id=$(account_by_name "${1:-}"); [ -n "$id" ] || die "use: no account named ${1:-}"
  local session=""; [ "${2:-}" = "--resume" ] && session="${3:-}"
  pause 10   # let the caller's turn finish before its window quits
  [ -n "$session" ] && hand_off "$session" swap
  if ! swap_to "$id"; then
    [ -n "$session" ] && drop_hand_off "$session"
    die "switch to ${1} failed; stayed put"
  fi
  if [ -n "$session" ]; then
    pause 12
    reopen_handoff >/dev/null
  fi
}

# Some app preferences are stored per account (keys holding the account id, or
# "<account>/<org>"). Copy the outgoing account's onto the incoming one, so settings follow
# you across a switch. Only while Claude is closed: the running app rewrites this file.
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

# Remote Control's on/off is kept per account (identities["org:account"].serve in
# remote-control-state.json); an account with none starts with it off. Carry the on/off over,
# never the environments, which belong to each account.
mirror_rc() {
  local f="$DEFAULT_DIR/remote-control-state.json" fk tk serve
  [ -f "$f" ] || return 0
  fk="$(account_field "$1" orgUuid):$1"; tk="$(account_field "$2" orgUuid):$2"
  serve=$(jq -r --arg k "$fk" '.identities[$k].serve // empty' "$f")
  [ -n "$serve" ] || return 0
  [ "$(jq -r --arg k "$tk" '.identities[$k].serve // empty' "$f")" = "$serve" ] && return 0
  cp -p "$f" "$DIR/backups/remote-control-state.before-mirror.json"
  jq --arg k "$tk" --arg s "$serve" '.identities[$k] = ((.identities[$k] // {folders: {}, pendingDelete: [], pendingUnarchive: []}) + {serve: $s})' "$f" > "$f.tmp.$$" && jq empty "$f.tmp.$$" && mv "$f.tmp.$$" "$f" && log "remote control: $serve on $(account_field "$2" name), as on $(account_field "$1" name)"
}

# A one-off settings fix ($DIR/prefs-patch.json), merged in the next time Claude is closed.
apply_prefs_patch() {
  [ -f "$DIR/prefs-patch.json" ] || return 0
  cp -p "$PREFS" "$DIR/backups/claude_desktop_config.before-patch.json"
  jq -s '.[0] * .[1]' "$PREFS" "$DIR/prefs-patch.json" > "$PREFS.tmp.$$" && mv "$PREFS.tmp.$$" "$PREFS" && mv "$DIR/prefs-patch.json" "$DIR/backups/prefs-patch.applied.json" && log "prefs: patch applied"
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
  pause 10
  [ -n "$session" ] && hand_off "$session" restart
  quit_default
  while_closed
  open_app
  if [ -n "$session" ]; then
    pause 15
    reopen_handoff >/dev/null
  fi
}

# ---- Accounts ------------------------------------------------------------------------------

# Add account $2 (an accountUuid the app reported) as $1. Fills an entry with only a name, or
# adds one. An id already in accounts.json is left under its own name.
add_account() {
  local name="$1" id="$2" other; other=$(account_field "$id" name)
  if [ -n "$other" ]; then log "accounts: that sign-in is $other, already in accounts.json; kept as $other"; notify "That was $other, not a new account. Kept it as $other."; return 0; fi
  jq_write "$ACCOUNTS" --arg n "$name" --arg u "$id" '
    if any(.accounts[]; .name == $n) then .accounts |= map(if .name == $n then . + {accountUuid: $u} else . end)
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
# A <name> not in accounts.json (or there without an accountUuid) is a new account: whatever
# account other than the current one you sign in to is added under that name, with the ids
# the app reports, and its session folders are linked to the shared list.
cmd_signin() {
  local name="${1:-}"; [ -n "$name" ] || die "signin: which account? relay.sh signin <name>"
  local id; id=$(account_by_name "$name")
  local session=""; [ "${2:-}" = "--resume" ] && session="${3:-}"
  local cur why; cur=$(folder_account "$DEFAULT_DIR")
  [ -n "$id" ] && [ "$id" = "$cur" ] && die "signin: Claude is on $name already; if it's signed out, sign in in Claude itself."
  why=$(check_app) || die "signin: not closing Claude: $why. Run relay.sh doctor."
  pause 10
  [ -n "$session" ] && hand_off "$session" signin
  quit_default
  move_signin "$cur" "${id:-new}"   # nothing parked for it, so Claude opens signed out
  open_app
  notify "Sign in to ${name} in Claude. Your other account comes back afterwards."
  log "signin: waiting for ${name} to be signed in$([ -z "$id" ] && echo " (a new account)")"
  # While signed out the app still reports the last account, so a new one shows as a change.
  local now n=0
  signed_in() { now=$(folder_account "$DEFAULT_DIR"); if [ -n "$id" ]; then [ "$now" = "$id" ]; else [ -n "$now" ] && [ "$now" != "$cur" ]; fi; }
  while ! signed_in && [ $n -lt 600 ]; do sleep 2; n=$((n+2)); done
  local new=""
  if signed_in; then
    new="$now"; log "signin: ${name} signed in"
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
    local f; for f in Cookies Cookies-journal; do [ -e "$PARK/$cur/$f" ] && mv -f "$PARK/$cur/$f" "$DEFAULT_DIR/$f"; done
  fi
  open_app
  log "signin: back on $(account_field "$cur" name)"
  if [ -n "$session" ]; then
    pause 15
    reopen_handoff >/dev/null
  fi
}

# Take an account out: its parked sign-in moves to backups/ (still signed in there until you
# delete it), its parked terminal login is deleted, and it's dropped from accounts.json.
cmd_remove() {
  local name="${1:-}" id; id=$(account_by_name "$name"); [ -n "$id" ] || die "remove: no account named $name"
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
  version_tested || echo "~~  Claude Desktop $v hasn't been tested with this switcher (tested: $TESTED_VERSIONS). Switches check the app's files first, but watch the first one."
  mkdir -p "$DIR/backups" "$PARK"
  [ -f "$ACCOUNTS" ] || echo '{"accounts":[]}' > "$ACCOUNTS"
  [ -f "$STATE" ] || echo '{"cooldowns":{},"switches":[]}' > "$STATE"
  [ -f "$HANDOFF" ] || echo '{"resume":[]}' > "$HANDOFF"
  link_to "$repo/relay.sh" "$DIR/relay.sh"
  link_to "$repo/mod" "$DIR/mod"
  local cur; cur=$(folder_account "$DEFAULT_DIR")
  if [ -z "$(account_field "$cur" name)" ]; then
    [ -n "$name" ] || die "setup: give the account Claude is signed in to a short name: relay.sh setup <name>"
    add_account "$name" "$cur"; fill_orgs
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
  add <name>                sign in another account and add it (Claude restarts signed out for you)
  signin <name>             sign an account in again after its sign-in ran out
  remove <name>             take an account out
  doctor                    check the whole setup

Using it
  status                    accounts, usage, cooldowns, sessions waiting to reopen
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
work from inside Claude too. use/signin/restart take --resume <sessionId> to reopen a session.
EOF
}

# Created on first use; setup and help work before there's anything.
case "${1:-help}" in
  setup|help|-h|--help) ;;
  *)
    [ -f "$ACCOUNTS" ] || { echo "Not set up yet: run ./relay.sh setup <name> in the cloned repo." >&2; exit 1; }
    [ -f "$STATE" ] || echo '{"cooldowns":{},"switches":[]}' > "$STATE"
    [ -f "$HANDOFF" ] || echo '{"resume":[]}' > "$HANDOFF"
    mkdir -p "$DIR/backups" ;;
esac

cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in
  setup)  cmd_setup "$@" ;;
  add|signin|signin-later) [ -n "${1:-}" ] || die "$cmd: which account? relay.sh $cmd <name>"; now_or_job signin "$@" ;;
  use|swap|swap-later) [ -n "$(account_by_name "${1:-}")" ] || die "$cmd: no account named ${1:-}"; now_or_job swap "$@" ;;
  restart|restart-later) now_or_job restart "$@" ;;
  remove) cmd_remove "$@" ;;
  doctor) cmd_doctor ;;
  status) cmd_status ;;
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
