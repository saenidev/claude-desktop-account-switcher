#!/bin/bash
# Two parts of the switcher with too many states to list, each run in all of them and checked
# against a rule stated once.
#
# Every point at which a switch can be cut off while it moves the sign-ins.
# A real `relay.sh use bob` runs (as its launchd job, against the stand-ins of tests/e2e.sh)
# and is cut off at its n-th move of a sign-in file, for every n the switch makes: before or
# after the move, by SIGKILL (the Mac shutting down) or SIGTERM (launchd stopping the job);
# after a SIGKILL, with Claude left closed or opened from the Dock in the meantime; on a
# switch that works, on one whose new sign-in doesn't come up (so it goes back, and the moves
# back are cut too), and on one whose app reports bob late, just as the switch has given up and
# starts going back ("late"); with each Cookies' journal there, and with none. Then the next
# command (a restart) runs, or for SIGTERM the job's own undo has, and each case must end with:
#   Claude running on alice, or on bob if the app had come up on bob before it was cut off;
#   the other account's sign-in parked under its own name, and nothing parked for the one in Claude;
#   no journal beside another account's Cookies; nothing left to recover (doctor is happy).
#
# The account a limit switch picks, with bob and carol each in every state that counts (see
# pick_sweep below): 2592 cases.
#
#   tests/sweep.sh            (about 45 minutes)
#   SWEEP=cut tests/sweep.sh  only the cut-off switch (about 40); SWEEP=pick, only the pick (5)
#   SWEEP_KINDS="late" SWEEP=cut tests/sweep.sh   only the late kind of switch
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d -t cdas-sweep)
H="$T/home"; APPDIR="$T/Claude.app"; P="$H/Library/Application Support/Claude"; D="$H/.claude/desktop-account-switcher"
A=aaaaaaaa-0000-4000-8000-000000000001; B=bbbbbbbb-0000-4000-8000-000000000002; C=cccccccc-0000-4000-8000-000000000003
passed=0; failed=0; SWEEP="${SWEEP:-cut pick}"

cleanup() { pkill -f "$APPDIR/Contents/MacOS/Claude" 2>/dev/null; [ -n "${E2E_KEEP:-}" ] && { echo "kept $T"; return; }; rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$H/.local/bin" "$H/orgs" "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$P"
for f in open launchctl security claude osascript mv; do cp "$REPO/tests/fakes/$f" "$H/.local/bin/$f"; chmod +x "$H/.local/bin/$f"; done
cp "$REPO/tests/fakes/app-start" "$APPDIR/Contents/Resources/start"; chmod +x "$APPDIR/Contents/Resources/start"
plutil -create xml1 "$APPDIR/Contents/Info.plist"; plutil -insert CFBundleShortVersionString -string 3.1623.0 "$APPDIR/Contents/Info.plist"
echo aaaaaaaa-0000-4000-8000-0000000000a1 > "$H/orgs/$A"; echo bbbbbbbb-0000-4000-8000-0000000000b2 > "$H/orgs/$B"
export HOME="$H" ACCOUNT_SWITCHER_APP="$APPDIR" ACCOUNT_SWITCHER_FAST=1
export PATH="$H/.local/bin:$PATH"
relay() { "$REPO/relay.sh" "$@"; }

# A Cookies file $1 for account $2: signed in with sessionKey $3 (the account's id, or "" for
# a sign-in claude.ai no longer takes), and marked as $2's so it can be found wherever it ends up.
signin_file() {
  /bin/rm -f "$1"
  sqlite3 "$1" "create table cookies(host_key text, name text, value text, expires_utc integer);
    insert into cookies values('.claude.ai', 'sessionKey', '$3', ($(date -u +%s) + 20*86400 + 11644473600) * 1000000);
    insert into cookies values('sweep.test', 'who', '$2', 0);"
}
who() { sqlite3 "file:$1?mode=ro&immutable=1" "select value from cookies where name='who'" 2>/dev/null; }
app_pids() { pgrep -f "^$APPDIR/Contents/MacOS/Claude"; }
running() { [ -n "$(app_pids)" ]; }
wait_for() { local n=0; until eval "$1"; do sleep 0.5; n=$((n+1)); [ $n -lt $(( ${2:-30} * 2 )) ] || return 1; done; }
job_pid() { cat "$H/launchd.pids/local.desktop-account-switcher" 2>/dev/null; }
job_done() { wait_for "[ ! -e \"$H/launchd.pids/local.desktop-account-switcher\" ]" "${1:-60}"; }
check() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then passed=$((passed+1))
  else failed=$((failed+1)); echo "  FAIL $case: $what"; fi
}

# ---- alice set up, bob added (as in tests/e2e.sh) ----
signin_file "$P/Cookies" A "$A"; open -a "$APPDIR"; wait_for running 5
relay setup alice >/dev/null || { echo "setup failed"; exit 1; }
relay add bob >/dev/null
wait_for "running && [ -z \"\$(sqlite3 \"file:$P/Cookies?mode=ro&immutable=1\" \"select value from cookies where name='sessionKey'\" 2>/dev/null)\" ]" 20
signin_file "$P/Cookies" B "$B"; "$APPDIR/Contents/Resources/start" "$P"
wait_for "grep -q 'signin: back on alice' '$D/relay.log'" 60 || { echo "add bob failed"; tail -5 "$D/relay.log"; exit 1; }
job_done

# Claude running on alice, bob parked (with a sign-in that comes up, or one that doesn't),
# each Cookies with its journal ($2 = journals) or without.
reset() {
  pkill -f "^$APPDIR/Contents/MacOS/Claude"; wait_for "! running" 10
  /bin/rm -rf "$D/backups" "$D/park/$A" "$D/park/$B" "$D/swap.inflight" "$H/cut" "$H/cut.count" "$H/report"
  /bin/rm -f "$P/Cookies" "$P/Cookies-journal"; mkdir -p "$D/park/$B"
  signin_file "$P/Cookies" A "$A"
  if [ "$1" = works ]; then signin_file "$D/park/$B/Cookies" B "$B"; else signin_file "$D/park/$B/Cookies" B ""; fi
  [ "$2" = journals ] && { echo "journal of A" > "$P/Cookies-journal"; echo "journal of B" > "$D/park/$B/Cookies-journal"; }
  open -a "$APPDIR"; wait_for running 5
}

# Each journal beside a Cookies is that account's, or empty.
journals_match() {
  local d j
  for d in "$P" "$D/park/$A" "$D/park/$B"; do
    j="$d/Cookies-journal"; [ -s "$j" ] || continue
    [ -e "$d/Cookies" ] || continue
    [ "$(cat "$j")" = "journal of $(who "$d/Cookies")" ] || return 1
  done
}

one() {   # one works|dud|late journals|none <n> <how> [dock]
  local kind="$1" j="$2" n="$3" how="$4" dock="${5:-}" on other
  case="$kind, $j, move $n, $how${dock:+, opened from the Dock}"
  reset "$kind" "$j"
  # Late: the app reports bob just before the first move back (the 5th move, or the 3rd with
  # no journals), though bob's sign-in hadn't come up in time.
  if [ "$kind" = late ]; then if [ "$j" = journals ]; then echo "5 $B" > "$H/report"; else echo "3 $B" > "$H/report"; fi; fi
  echo "$n $how" > "$H/cut"
  relay use bob >/dev/null 2>&1
  job_done 60
  [ -f "$H/cut" ] && return 1   # the switch made fewer moves than n
  if [[ "$how" == kill-* ]]; then
    check "the job left a cut-off switch" test -f "$D/swap.inflight"
    if [ -n "$dock" ]; then open -a "$APPDIR"; wait_for running 5; fi
    check "doctor says a switch was cut off" sh -c "'$REPO/relay.sh' doctor | grep -q 'a switch was cut off'"
  fi
  # Where Claude should end: on bob only if the app had come up on bob (and it wasn't going back).
  on=A; other=B
  [ "$(jq -r '.lastKnownAccountUuid // empty' "$P/config.json" 2>/dev/null)" = "$B" ] && [ "$kind" = works ] && { on=B; other=A; }
  [[ "$how" == kill-* ]] && relay restart >/dev/null 2>&1 && job_done 60
  check "Claude is running" wait_for running 10
  check "Claude holds $on's sign-in" test "$(who "$P/Cookies")" = "$on"
  check "the app reports $on" test "$(jq -r '.lastKnownAccountUuid' "$P/config.json")" = "$(eval echo \$$on)"
  check "$other's sign-in is parked as $other's" test "$(who "$D/park/$(eval echo \$$other)/Cookies")" = "$other"
  check "nothing is parked for $on" test ! -e "$D/park/$(eval echo \$$on)/Cookies"
  check "no journal is beside another account's Cookies" journals_match
  check "nothing is left to recover" test ! -e "$D/swap.inflight"
  check "doctor is happy" relay doctor
  return 0
}

# Claude on alice, out of usage; bob and carol each in every state that counts: parked sign-in
# live, run out or none; cooling down or not (none, or one that has passed); last usage reading
# fine (99%), a 5-hour window used up until later, a weekly one used up but since reset, or the
# model's own weekly limit used up until later; the limit hit a 5-hour one or that model's.
# `relay.sh plan` must name the first of bob, carol (accounts.json order after alice) that has
# a live sign-in, isn't cooling down and has none of the windows that count used up; or nobody.
pick_sweep() {
  local soon past bp bc bu cp cc cu limit want got
  soon=$(date -u -v+2H +%FT%TZ); past=$(date -u -v-2H +%FT%TZ)
  parked() {   # parked <uuid> <letter> live|expired|none
    /bin/rm -f "$D/park/$1/Cookies" "$D/park/$1/Cookies-journal"
    [ "$3" = none ] && return
    mkdir -p "$D/park/$1"; signin_file "$D/park/$1/Cookies" "$2" "$1"
    [ "$3" = expired ] && sqlite3 "$D/park/$1/Cookies" "update cookies set expires_utc = ($(date -u +%s) - 86400 + 11644473600) * 1000000"
  }
  cooldown() { case "$1" in none) ;; soon) printf '"%s":"%s",' "$2" "$soon" ;; past) printf '"%s":"%s",' "$2" "$past" ;; esac; }
  usage() {
    local w
    case "$1" in
      fine) w='{"kind":"five_hour","percentUsed":99,"resetsAt":"'"$soon"'"}' ;;
      five) w='{"kind":"five_hour","percentUsed":100,"resetsAt":"'"$soon"'"}' ;;
      reset) w='{"kind":"seven_day","percentUsed":100,"resetsAt":"'"$past"'"}' ;;
      model) w='{"kind":"seven_day_model","label":"Fable weekly","percentUsed":100,"resetsAt":"'"$soon"'"}' ;;
    esac
    printf '"%s":{"at":%s000,"source":"session","windows":[%s]},' "$2" "$(date +%s)" "$w"
  }
  # The oracle: the rules as the comments on switch_ready and pick_target in relay.sh state them.
  can_pick() { [ "$1" = live ] && [ "$2" != soon ] && [ "$3" != five ] && ! { [ "$3" = model ] && [ -n "$4" ]; }; }
  local n=0
  for bp in live expired none; do parked "$B" B "$bp"
  for cp in live expired none; do parked "$C" C "$cp"
  for bc in none soon past; do for cc in none soon past; do
    printf '{"cooldowns":{%s},"switches":[]}\n' "$(cooldown "$bc" "$B")$(cooldown "$cc" "$C")" | sed 's/,}/}/' > "$D/state.json"
    for bu in fine five reset model; do for cu in fine five reset model; do
      printf '{%s}\n' "$(usage "$bu" "$B")$(usage "$cu" "$C")" | sed 's/,}$/}/' > "$D/usage.json"
      for limit in "" "Fable weekly"; do
        want=nobody
        if can_pick "$bp" "$bc" "$bu" "$limit"; then want=bob
        elif can_pick "$cp" "$cc" "$cu" "$limit"; then want=carol; fi
        got=$(relay plan --from "$A" ${limit:+--limit "$limit"} | sed -n 's/^to: *\([a-z]*\).*/\1/p')
        case="bob $bp/cooldown $bc/usage $bu, carol $cp/cooldown $cc/usage $cu${limit:+, out of $limit}"
        check "picks $want (got $got)" test "$got" = "$want"
        n=$((n+1))
      done
    done; done
  done; done
  echo "parked bob $bp: done  (${SECONDS}s, $failed failed so far)"
  done; done
  echo "the pick: $n cases"
}

[[ "$SWEEP" == *cut* ]] && for kind in ${SWEEP_KINDS:-works dud late}; do
  for j in journals none; do
    n=1
    while :; do
      hows="kill-before kill-after"; [ "$j" = journals ] && hows="$hows term-before term-after"
      one "$kind" "$j" "$n" kill-before || break
      for how in $hows; do [ "$how" = kill-before ] || one "$kind" "$j" "$n" "$how"; done
      one "$kind" "$j" "$n" kill-before dock; one "$kind" "$j" "$n" kill-after dock
      echo "$kind, $j: move $n cut every way  (${SECONDS}s, $failed failed so far)"
      n=$((n+1))
    done
    echo "$kind, $j: the switch makes $((n-1)) moves of sign-in files"
  done
done

if [[ "$SWEEP" == *pick* ]]; then
  reset works journals
  echo cccccccc-0000-4000-8000-0000000000c3 > "$H/orgs/$C"
  relay add carol >/dev/null
  wait_for "running && [ -z \"\$(sqlite3 \"file:$P/Cookies?mode=ro&immutable=1\" \"select value from cookies where name='sessionKey'\" 2>/dev/null)\" ]" 20
  signin_file "$P/Cookies" C "$C"; "$APPDIR/Contents/Resources/start" "$P"
  wait_for "[ \$(grep -c 'signin: back on alice' '$D/relay.log') -ge 2 ]" 60 || { echo "add carol failed"; tail -5 "$D/relay.log"; exit 1; }
  job_done
  pick_sweep
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || tail -20 "$D/relay.log"
[ "$failed" -eq 0 ]
