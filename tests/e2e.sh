#!/bin/bash
# End-to-end tests: run relay.sh the way a person does, in a throwaway home folder, against a
# stand-in Claude app and stand-ins for open, launchctl, the Keychain, notifications and the
# claude CLI (tests/fakes). Nothing touches the real Claude, Keychain or launchd.
#   tests/e2e.sh                      (about a minute and a half)
#   E2E_FAILFAST=1 tests/e2e.sh       stop at the first failure, with the log
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d -t cdas-e2e)
H="$T/home"; APPDIR="$T/Claude.app"; P="$H/Library/Application Support/Claude"; D="$H/.claude/desktop-account-switcher"
A=aaaaaaaa-0000-4000-8000-000000000001; OA=aaaaaaaa-0000-4000-8000-0000000000a1
B=bbbbbbbb-0000-4000-8000-000000000002; OB=bbbbbbbb-0000-4000-8000-0000000000b2
C=cccccccc-0000-4000-8000-000000000003; OC=cccccccc-0000-4000-8000-0000000000c3
passed=0; failed=0

cleanup() { pkill -f "$APPDIR/Contents/MacOS/Claude" 2>/dev/null; [ -n "${E2E_KEEP:-}" ] && { echo "kept $T"; return; }; rm -rf "$T"; }
trap cleanup EXIT

# ---- The stand-in world ----
mkdir -p "$H/.local/bin" "$H/orgs" "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$P"
for f in open launchctl security claude osascript; do cp "$REPO/tests/fakes/$f" "$H/.local/bin/$f"; chmod +x "$H/.local/bin/$f"; done
cp "$REPO/tests/fakes/app-start" "$APPDIR/Contents/Resources/start"; chmod +x "$APPDIR/Contents/Resources/start"
plutil -create xml1 "$APPDIR/Contents/Info.plist"; plutil -insert CFBundleShortVersionString -string 3.1623.0 "$APPDIR/Contents/Info.plist"
echo "$OA" > "$H/orgs/$A"; echo "$OB" > "$H/orgs/$B"; echo "$OC" > "$H/orgs/$C"

export HOME="$H" ACCOUNT_SWITCHER_APP="$APPDIR" ACCOUNT_SWITCHER_FAST=1
export PATH="$H/.local/bin:$PATH"
relay() { "$REPO/relay.sh" "$@"; }

# A claude.ai sign-in for account $2 in Cookies file $1 (good for 20 days).
cookies() {
  rm -f "$1"
  sqlite3 "$1" "create table cookies(host_key text, name text, value text, expires_utc integer);
    insert into cookies values('.claude.ai', 'sessionKey', '$2', ($(date -u +%s) + 20*86400 + 11644473600) * 1000000);"
}
# A sign-in that looks good (a sessionKey that hasn't expired) but that claude.ai no longer
# takes: the stand-in app, like the real one, then reports no account.
dud_signin() { cookies "$1" ""; }
# A sign-in whose cookie expired yesterday.
expire_signin() { sqlite3 "$1" "update cookies set expires_utc = ($(date -u +%s) - 86400 + 11644473600) * 1000000"; }
signed_in_as() { sqlite3 "file:$1?mode=ro&immutable=1" "select value from cookies where name='sessionKey'" 2>/dev/null; }
app_pids() { pgrep -f "^$APPDIR/Contents/MacOS/Claude" ; }
running() { [ -n "$(app_pids)" ]; }
# The person signs in to $1 in the open (signed-out) app: the app writes Cookies and reports it.
sign_in() { cookies "$P/Cookies" "$1"; "$APPDIR/Contents/Resources/start" "$P"; }
wait_for() { local n=0; until eval "$1"; do sleep 0.5; n=$((n+1)); [ $n -lt $(( ${2:-30} * 2 )) ] || return 1; done; }
# Wait for a relay.log line written since the last mark (each action marks before it starts).
MARK=0
mark() { MARK=$(wc -l < "$D/relay.log" 2>/dev/null || echo 0); }
wait_log() { wait_for "tail -n +$((MARK + 1)) \"$D/relay.log\" 2>/dev/null | grep -q \"$1\"" "${2:-40}"; }
uuid_of() { jq -r --arg n "$1" '.accounts[] | select(.name == $n) | .accountUuid // empty' "$D/accounts.json"; }
org_of() { jq -r --arg n "$1" '.accounts[] | select(.name == $n) | .orgUuid // empty' "$D/accounts.json"; }

check() {   # check "<what>" <command...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then passed=$((passed+1)); echo "  ok  $what"
  else
    failed=$((failed+1)); echo "  FAIL $what"
    [ -n "${E2E_FAILFAST:-}" ] && {
      echo "relay.log:"; tail -15 "$D/relay.log"; echo "jobs.out:"; tail -5 "$H/jobs.out" 2>/dev/null
      echo "app processes:"; ps -axo pid=,args= | grep -F "$APPDIR" | grep -v grep; echo "profile:"; ls "$P"; exit 1; }
  fi
}
# The pid of the relay's launchd job while it runs (the stand-in launchctl keeps it).
job_pid() { cat "$H/launchd.pids/local.desktop-account-switcher" 2>/dev/null; }
# Each section starts once the last one's job has finished: a job still running would turn
# the next command away (as it should).
section() { wait_for "[ -z \"\$(job_pid)\" ]" 30; echo; echo "$*  (${SECONDS}s)"; }

# ---- A Mac with Claude signed in to one account ----
cookies "$P/Cookies" "$A"; open -a "$APPDIR"
wait_for running 5

section "help and commands before setup"
check "help lists add" sh -c "'$REPO/relay.sh' help | grep -q 'add <name>'"
check "status before setup says to run setup" sh -c "'$REPO/relay.sh' status 2>&1 | grep -q 'relay.sh setup'"
check "an unknown command fails" sh -c "! '$REPO/relay.sh' frobnicate 2>/dev/null"

section "setup"
check "setup without a name asks for one" sh -c "! '$REPO/relay.sh' setup 2>/dev/null"
check "setup alice succeeds" relay setup alice
check "alice has the signed-in account's id" test "$(uuid_of alice)" = "$A"
check "alice's org comes from her session folder" test "$(org_of alice)" = "$OA"
check "relay.sh is linked into the data folder" test "$(readlink "$D/relay.sh")" = "$REPO/relay.sh"
check "the mod is linked" test "$(readlink "$D/mod")" = "$REPO/mod"
check "the mod is installed" jq -e '.enabledPlugins["desktop-account-switcher@desktop-account-switcher-local"] == true' "$H/.claude/settings.json"
check "auto-switch is on" jq -e '.armed == true' "$D/config.json"
check "the keep-alive job is loaded" grep -qx local.desktop-account-switcher.keepalive "$H/launchd.loaded"
check "setup again changes nothing" sh -c "'$REPO/relay.sh' setup >/dev/null && [ \$(jq '.accounts | length' '$D/accounts.json') = 1 ]"
check "doctor wants a second account" sh -c "'$REPO/relay.sh' doctor | grep -q '1 account(s)'"

section "add a second account"
echo '{"note":"alice'"'"'s session"}' > "$P/claude-code-sessions/$A/$OA/local_alice.json"
mark; check "add bob is queued" relay add bob
check "Claude closes and opens signed out" wait_for "running && [ ! -f '$P/Cookies' ]" 20
sign_in "$B"
mkdir -p "$P/claude-code-sessions/$B/$OB"; echo '{"note":"made while signing in"}' > "$P/claude-code-sessions/$B/$OB/local_bob.json"
check "the relay notices the sign-in and brings alice back" wait_log "signin: back on alice" 60
check "bob is added with the id the app reported" test "$(uuid_of bob)" = "$B"
check "bob's org is learnt from his session folder" test "$(org_of bob)" = "$OB"
check "bob's sign-in is parked" test "$(signed_in_as "$D/park/$B/Cookies")" = "$B"
check "Claude is back on alice" test "$(signed_in_as "$P/Cookies")" = "$A"
check "Claude is running" running
check "alice's list became the shared one" test -d "$P/claude-code-sessions/$A/$OA" -a ! -L "$P/claude-code-sessions/$A/$OA"
check "bob's list links to it" test "$(readlink "$P/claude-code-sessions/$B/$OB")" = "$P/claude-code-sessions/$A/$OA"
check "bob's session moved into the shared list" test -f "$P/claude-code-sessions/$A/$OA/local_bob.json"
check "alice's session is still there" test -f "$P/claude-code-sessions/$A/$OA/local_alice.json"
check "Cowork's list is linked too" test -L "$P/local-agent-mode-sessions/$B/$OB"
check "bob's folder was backed up first" sh -c "ls '$D'/backups/*-shared-list/claude-code-sessions/$B/$OB/local_bob.json"
check "doctor is happy" relay doctor
check "add with a name already set up is refused" sh -c "! '$REPO/relay.sh' add bob 2>'$T/err' && grep -q 'bob is already set up; to sign it in again use relay.sh signin bob' '$T/err'"
check "signin with a name not set up is refused" sh -c "! '$REPO/relay.sh' signin zed 2>'$T/err' && grep -q 'relay.sh add zed' '$T/err'"

section "terminal claude follows the app"
mkdir -p "$H/keychain/Claude Code-credentials"
printf 'token-for-alice' > "$H/keychain/Claude Code-credentials/$USER"; jq -n --arg u "$A" '{oauthAccount: {accountUuid: $u}}' > "$H/.claude.json"
check "cli-save parks alice's terminal login" relay cli-save
printf 'token-for-bob' > "$H/keychain/Claude Code-credentials/$USER"; jq -n --arg u "$B" '{oauthAccount: {accountUuid: $u}}' > "$H/.claude.json"
check "cli-save parks bob's terminal login" relay cli-save
check "cli-use alice moves the terminal back" relay cli-use alice
check "the terminal login is alice's" test "$(cat "$H/keychain/Claude Code-credentials/$USER")" = token-for-alice
jq --arg u "$B" '.oauthAccount.accountUuid = $u' "$H/.claude.json" > "$T/j" && mv "$T/j" "$H/.claude.json"
check "a live login that is alice's parked one isn't saved as bob's" sh -c "! '$REPO/relay.sh' cli-save 2>/dev/null"
check "bob's parked terminal login is untouched" test "$(cat "$H/keychain/desktop-account-switcher-cli/$B")" = token-for-bob
check "it's logged" grep -q "same as alice's parked one" "$D/relay.log"
jq --arg u "$A" '.oauthAccount.accountUuid = $u' "$H/.claude.json" > "$T/j" && mv "$T/j" "$H/.claude.json"

section "switch by hand, reopening the session"
# A private per-account setting: it's copied to the new account, and the file stays private.
jq -n --arg a "$A" '{("sidebar-" + $a): {width: 300}}' > "$P/claude_desktop_config.json"; chmod 600 "$P/claude_desktop_config.json"
mark; check "use bob is queued" relay use bob --resume session-1
check "the hand-off says which account the session comes back on" wait_for "jq -e --arg b '$B' '.resume[] | select(.sessionId == \"session-1\") | .account == \$b' '$D/handoff.json' >/dev/null" 10
check "the switch finishes" wait_log "swap: alice -> bob" 40
check "alice's per-account setting is copied to bob" jq -e --arg b "$B" '.["sidebar-" + $b].width == 300' "$P/claude_desktop_config.json"
check "claude_desktop_config.json is still 0600" test "$(stat -f %Lp "$P/claude_desktop_config.json")" = 600
check "Claude is signed in as bob" test "$(signed_in_as "$P/Cookies")" = "$B"
check "the app reports bob" test "$(jq -r .lastKnownAccountUuid "$P/config.json")" = "$B"
check "alice is parked" test "$(signed_in_as "$D/park/$A/Cookies")" = "$A"
check "the session is reopened" wait_for "grep -q 'claude://resume?session=session-1' '$H/links.log'" 20
check "the terminal moved to bob" test "$(cat "$H/keychain/Claude Code-credentials/$USER")" = token-for-bob
check "alice's terminal login is parked" test "$(cat "$H/keychain/desktop-account-switcher-cli/$A")" = token-for-alice
check "one Claude window" test "$(app_pids | wc -l | tr -d ' ')" = 1

section "out of usage"
jq '.resume = [] | del(.closedAt)' "$D/handoff.json" > "$T/h" && mv "$T/h" "$D/handoff.json"
jq --arg at "$(date -u +%FT%TZ)" '.resume += [{sessionId: "session-2", cwd: "", reason: "limit hit", at: $at}]' "$D/handoff.json" > "$T/h" && mv "$T/h" "$D/handoff.json"
mark; check "the mod's launch is queued" relay launch --from "$B" --resets-at "$(date -u -v+3H +%FT%TZ)"
check "it switches to the next account" wait_log "swap: bob -> alice" 40
check "Claude is signed in as alice" test "$(signed_in_as "$P/Cookies")" = "$A"
check "bob cools down until his reset" jq -e --arg b "$B" '.cooldowns[$b] > (now | todate)' "$D/state.json"
check "the cut-off session is reopened" wait_for "grep -q 'session=session-2' '$H/links.log'" 20
check "the mod's entry is stamped with the account switched to" jq -e --arg a "$A" '.resume[] | select(.sessionId == "session-2") | .account == $a' "$D/handoff.json"
wait_log "switch: done" 20

section "every account out"
jq --arg at "$(date -u +%FT%TZ)" '.resume += [{sessionId: "session-3", cwd: "", reason: "limit hit", at: $at}]' "$D/handoff.json" > "$T/h" && mv "$T/h" "$D/handoff.json"
check "a switch with nowhere to go fails" sh -c "'$REPO/relay.sh' switch --from $A 2>/dev/null; [ \$? -ne 0 ]"
check "Claude stays on alice" test "$(signed_in_as "$P/Cookies")" = "$A"
check "you're told" grep -q "every other account is too" "$H/notifications.log"
check "the limit's hand-off is dropped" sh -c "! jq -e '.resume[] | select(.sessionId == \"session-3\")' '$D/handoff.json'"
jq '.cooldowns = {}' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"

section "an account whose last reading shows a used-up window"
jq --arg b "$B" --arg r "$(date -u -v+2d +%FT%TZ)" --argjson at "$(date +%s)000" \
  '.[$b] = {at: $at, source: "session", windows: [{kind: "seven_day", percentUsed: 100, resetsAt: $r}]}' "$D/usage.json" > "$T/u" && mv "$T/u" "$D/usage.json"
check "plan finds nobody to switch to" sh -c "'$REPO/relay.sh' plan --from $A | grep -q 'nobody'"
jq --arg b "$B" '.[$b].windows[0].resetsAt = "2020-01-01T00:00:00Z"' "$D/usage.json" > "$T/u" && mv "$T/u" "$D/usage.json"
check "once that window has reset, bob is picked" sh -c "'$REPO/relay.sh' plan --from $A | grep -q '^to: *bob'"
jq --arg b "$B" --arg r "$(date -u -v+2d +%FT%T)+00:00" '.[$b].windows[0].resetsAt = $r' "$D/usage.json" > "$T/u" && mv "$T/u" "$D/usage.json"
check "a reset time written with +00:00 counts too" sh -c "'$REPO/relay.sh' plan --from $A | grep -q 'nobody'"
cp "$D/usage.json" "$T/u.saved"; echo '{"broken' > "$D/usage.json"
mark; check "with usage.json unreadable, bob is still picked" sh -c "'$REPO/relay.sh' plan --from $A | grep -q '^to: *bob'"
check "and that's logged" wait_log "couldn't read the usage figures" 5
mv "$T/u.saved" "$D/usage.json"
jq --arg b "$B" 'del(.[$b])' "$D/usage.json" > "$T/u" && mv "$T/u" "$D/usage.json"
check "an option given last with no value doesn't crash" sh -c "! '$REPO/relay.sh' plan --from 2>&1 | grep -q 'unbound variable'"
jq '.cooldowns = {}' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"

section "the app's files moved (an app update)"
jq 'del(.lastKnownAccountUuid) | .lastKnownAccount = "moved"' "$P/config.json" > "$T/c" && cp "$P/config.json" "$T/c.saved" && mv "$T/c" "$P/config.json"
mark; check "use bob is queued" relay use bob
check "the switch refuses" wait_log "swap: not switching" 30
check "Claude keeps alice's sign-in" test "$(signed_in_as "$P/Cookies")" = "$A"
check "bob stays parked" test "$(signed_in_as "$D/park/$B/Cookies")" = "$B"
check "doctor says what's wrong" sh -c "'$REPO/relay.sh' doctor | grep -q 'lastKnownAccountUuid'"
mv "$T/c.saved" "$P/config.json"

section "an update that moves the app's files installs while Claude is closed for a switch"
# A stand-in ShipIt: like the real one, it waits for Claude to quit, takes a while to install,
# and then the app is a new version that keeps no lastKnownAccountUuid in config.json.
mkdir -p "$T/Squirrel.framework/Resources"
printf '%s\n' "while pgrep -f '^$APPDIR/Contents/MacOS/Claude' >/dev/null; do sleep 0.2; done" "sleep 3" \
  "plutil -replace CFBundleShortVersionString -string 3.9999.0 '$APPDIR/Contents/Info.plist'" \
  "jq 'del(.lastKnownAccountUuid)' '$P/config.json' > '$T/c' && mv '$T/c' '$P/config.json'" > "$T/Squirrel.framework/Resources/ShipIt"
/bin/bash "$T/Squirrel.framework/Resources/ShipIt" &
mark; check "use bob is queued" relay use bob
check "the relay waits for the update" wait_log "update: Claude 3.1623.0 -> 3.9999.0 installed while closed" 30
check "and then doesn't switch" wait_log "doesn't keep its files where this expects" 10
check "the switch fails" wait_log "ERROR switch to bob failed" 20
check "Claude keeps alice's sign-in" test "$(signed_in_as "$P/Cookies")" = "$A"
check "bob stays parked" test "$(signed_in_as "$D/park/$B/Cookies")" = "$B"
check "Claude is open again" wait_for running 10
plutil -replace CFBundleShortVersionString -string 3.1623.0 "$APPDIR/Contents/Info.plist"

section "a third account, with the shared list already there"
mark; check "add carol is queued" relay add carol
check "Claude opens signed out" wait_for "running && [ ! -f '$P/Cookies' ]" 20
sign_in "$C"
check "carol is added" wait_log "signin: back on alice" 60
check "carol has her ids" test "$(uuid_of carol):$(org_of carol)" = "$C:$OC"
check "carol's list links to the same shared one" test "$(readlink "$P/claude-code-sessions/$C/$OC")" = "$P/claude-code-sessions/$A/$OA"
check "doctor is happy with three" relay doctor
# Terminal claude is on alice; bob is cooling down and carol has no parked terminal login.
jq --arg b "$B" --arg u "$(date -u -v+3H +%FT%TZ)" '.cooldowns[$b] = $u' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"
check "a terminal limit doesn't move to an account with no parked terminal login" sh -c "! '$REPO/relay.sh' cli-switch 2>/dev/null"
check "terminal claude stays on alice" test "$(cat "$H/keychain/Claude Code-credentials/$USER")" = token-for-alice
jq '.cooldowns = {}' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"

# Back to alice after a section that switched away, for the sections after it.
back_to_alice() {
  wait_for "[ -z \"\$(job_pid)\" ]" 40; mark; relay use alice >/dev/null; wait_log "swap: .* -> alice" 40
  wait_for "[ -z \"\$(job_pid)\" ]" 40; jq '.cooldowns = {}' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"
}

section "a limit switch skips an account whose parked sign-in has run out"
cp "$D/park/$B/Cookies" "$T/bob.cookies"; expire_signin "$D/park/$B/Cookies"
check "status says bob's sign-in ran out" sh -c "'$REPO/relay.sh' status | grep -q 'bob .*ran out'"
check "plan goes past bob to carol" sh -c "'$REPO/relay.sh' plan --from $A | grep -q '^to: *carol'"
mark; check "the mod's launch is queued" relay launch --from "$A"
check "it switches to carol" wait_log "swap: alice -> carol" 40
check "bob's sign-in was never tried" sh -c "! tail -n +$((MARK + 1)) '$D/relay.log' | grep -q 'bob.*did not come up'"
wait_log "switch: done" 20
check "use bob by hand is refused before Claude closes" sh -c "'$REPO/relay.sh' use bob >/dev/null; sleep 4; grep -q \"bob's parked sign-in has run out\" '$D/relay.log'"
check "Claude stays on carol" test "$(signed_in_as "$P/Cookies")" = "$C"
mv "$T/bob.cookies" "$D/park/$B/Cookies"
back_to_alice

section "a limit switch whose first pick doesn't come up tries the next account"
cp "$D/park/$B/Cookies" "$T/bob.cookies"; dud_signin "$D/park/$B/Cookies"
mark; check "the mod's launch is queued" relay launch --from "$A"
check "bob is tried and doesn't come up" wait_log "bob's sign-in did not come up; going back to alice" 40
check "then carol is tried" wait_log "swap: alice -> carol" 40
check "bob's sign-in is parked as bob's again" test -f "$D/park/$B/Cookies"
check "Claude is on carol" test "$(signed_in_as "$P/Cookies")" = "$C"
wait_log "switch: done" 20
mv "$T/bob.cookies" "$D/park/$B/Cookies"
back_to_alice

section "a limit switch waits for the keep-alive instead of being dropped"
sleep 60 & holder=$!
mkdir "$D/switch.lock"; echo "$holder" > "$D/switch.lock/pid"; echo keepalive > "$D/switch.lock/what"
mark; check "the mod's launch is queued while the keep-alive holds the lock" relay launch --from "$A"
check "it isn't turned away" sh -c "! tail -n +$((MARK + 1)) '$D/relay.log' | grep -q 'already under way'"
sleep 3
check "it hasn't switched while the lock is held" test "$(signed_in_as "$P/Cookies")" = "$A"
rm -rf "$D/switch.lock"; kill "$holder" 2>/dev/null
check "once the keep-alive lets go, it switches" wait_log "swap: alice -> bob" 40
wait_log "switch: done" 20
back_to_alice

section "a limit trigger from an account Claude has already left"
mark; check "switch --from bob while Claude is on alice" relay switch --from "$B"
check "does nothing" wait_log "Claude is on alice now, not bob; nothing to do" 5
check "Claude stays on alice" test "$(signed_in_as "$P/Cookies")" = "$A"
jq '.cooldowns = {}' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"

section "sessions mid-turn when Claude closes are reopened, on any switch"
mkdir -p "$D/busy"
jq -n --arg a "$A" --argjson at "$(date +%s)000" '{sessionId: "busy-1", cwd: "/tmp", account: $a, busy: true, at: $at}' > "$D/busy/busy-1.json"
jq --arg c "$C" --arg at "$(date -u +%FT%TZ)" '.resume += [{sessionId: "for-carol", cwd: "", reason: "swap", account: $c, at: $at}]' "$D/handoff.json" > "$T/h" && mv "$T/h" "$D/handoff.json"
mark; check "use bob, with no --resume" relay use bob
check "the switch finishes" wait_log "swap: alice -> bob" 40
check "the mid-turn session is listed as cut off on alice" jq -e --arg a "$A" '.resume[] | select(.sessionId == "busy-1") | .reason == "closed" and .from == $a and .account == ""' "$D/handoff.json"
check "and reopened" wait_for "grep -q 'session=busy-1' '$H/links.log'" 20
check "an entry meant for another account isn't reopened" sh -c "! grep -q 'session=for-carol' '$H/links.log'"
check "busy/ is cleared once Claude has quit" test -z "$(ls "$D/busy")"
back_to_alice

section "a switch cut off while it moves the sign-ins"
cp "$D/park/$B/Cookies" "$T/bob.cookies"; dud_signin "$D/park/$B/Cookies"
mark; check "use bob is queued" relay use bob
check "Claude opens on bob's sign-in, which doesn't come up" wait_for "[ -f '$D/swap.inflight' ] && running && [ -f '$P/Cookies' ] && [ -z \"\$(signed_in_as '$P/Cookies')\" ]" 20
check "stopping the job (launchd's SIGTERM)" kill -TERM "$(job_pid)"
check "puts alice's sign-in back at once" wait_log "recover: a switch from alice to bob was cut off" 30
check "Claude is on alice" test "$(signed_in_as "$P/Cookies")" = "$A"
check "Claude is running" wait_for running 10
check "bob's sign-in is parked as bob's" test -f "$D/park/$B/Cookies" -a ! -e "$D/swap.inflight"
mv "$T/bob.cookies" "$D/park/$B/Cookies"
wait_for "[ -z \"\$(job_pid)\" ]" 10
# Killed outright, between parking alice's sign-in and the app loading bob's: Claude is closed
# with bob's Cookies while the app still reports alice.
pkill -f "^$APPDIR/Contents/MacOS/Claude"; wait_for "! running" 10
mv "$P/Cookies" "$D/park/$A/Cookies"; mv "$D/park/$B/Cookies" "$P/Cookies"; echo "$A $B" > "$D/swap.inflight"
check "doctor says a switch was cut off" sh -c "'$REPO/relay.sh' doctor | grep -q 'a switch was cut off'"
mark; check "a restart is queued" relay restart
check "it puts alice's sign-in back first" wait_log "recover: a switch from alice to bob was cut off" 30
check "Claude is on alice" test "$(signed_in_as "$P/Cookies")" = "$A"
check "bob's sign-in is parked as bob's, not alice's" test "$(signed_in_as "$D/park/$B/Cookies")" = "$B"
check "Claude is running after the restart" wait_for "running && [ -z \"\$(job_pid)\" ]" 30
check "doctor is happy" relay doctor

section "signin <name>, signing in to another account already set up instead"
# bob's parked sign-in no longer works, so Claude opens signed out; you sign in to carol.
cp "$D/park/$B/Cookies" "$T/bob.cookies"; cp "$D/park/$C/Cookies" "$T/carol.cookies"; dud_signin "$D/park/$B/Cookies"
mark; check "signin bob is queued" relay signin bob
check "Claude opens signed out" wait_for "running && [ -f '$P/Cookies' ] && [ -z \"\$(signed_in_as '$P/Cookies')\" ]" 20
sign_in "$C"
check "it's kept as carol" wait_log "that sign-in is carol, not bob; kept as carol" 30
check "and alice comes back" wait_log "signin: back on alice" 30
check "carol's new sign-in is parked as carol's" test "$(signed_in_as "$D/park/$C/Cookies")" = "$C"
check "her previous one is kept in backups" sh -c "ls '$D'/backups/*-replaced-signin/Cookies"
check "Claude is on alice" test "$(signed_in_as "$P/Cookies")" = "$A"
mv "$T/bob.cookies" "$D/park/$B/Cookies"

section "signing in to a known account under a new name (one with quotes, & and <>)"
DAVE="d'ave & <co> \"x\""
mark; check "add $DAVE is queued" relay add "$DAVE"
check "Claude opens signed out" wait_for "running && [ ! -f '$P/Cookies' ]" 20
check "the job got the name whole" grep -qF "signin: waiting for $DAVE to be signed in" "$D/relay.log"
check "the notification shows the name as it is" grep -qxF "Sign in to $DAVE in Claude. Your other account comes back afterwards." "$H/notifications.log"
sign_in "$B"
check "it's kept as bob" wait_log "that sign-in is bob" 60
check "nobody named dave is added" wait_for "[ -z \"\$(uuid_of \"\$DAVE\")\" ] && tail -n +$((MARK + 1)) '$D/relay.log' | grep -q 'signin: back on alice'" 30
check "bob's new sign-in is parked" test "$(signed_in_as "$D/park/$B/Cookies")" = "$B"

section "remove an account"
check "removing the account Claude is on is refused" sh -c "! '$REPO/relay.sh' remove alice 2>/dev/null"
check "remove carol" relay remove carol
check "carol is gone from accounts.json" test -z "$(uuid_of carol)"
check "her sign-in is kept in backups" sh -c "ls '$D'/backups/*-removed-carol/park/Cookies"
check "no parked sign-in is left for her" test ! -e "$D/park/$C"

section "a switch whose new sign-in doesn't come up goes back"
cp "$D/park/$B/Cookies" "$T/bob.cookies"
dud_signin "$D/park/$B/Cookies"
mark; check "use bob is queued" relay use bob
check "bob's sign-in doesn't come up, so it goes back" wait_log "did not come up; going back to alice" 40
check "the switch fails" wait_log "ERROR switch to bob failed" 20
check "Claude is on alice again" test "$(signed_in_as "$P/Cookies")" = "$A"
check "Claude is running" running
mv "$T/bob.cookies" "$D/park/$B/Cookies"

section "a second command never kills one that's running"
mark; check "use bob is queued" relay use bob
check "a restart while it runs is refused" sh -c "! '$REPO/relay.sh' restart 2>'$T/err' && grep -q 'a switch or sign-in is running' '$T/err'"
check "the mod's launch while it runs is fine" relay launch --from "$B"
check "and only logs that a switch is under way" wait_log "launch: a switch is already under way" 5
check "bob's cooldown is kept all the same" jq -e --arg b "$B" '.cooldowns[$b] > (now | todate)' "$D/state.json"
check "the first switch finishes" wait_log "swap: alice -> bob" 40
check "Claude is on bob" test "$(signed_in_as "$P/Cookies")" = "$B"
check "nothing else ran" sh -c "! tail -n +$((MARK + 1)) '$D/relay.log' | grep -qE 'restart : queued|switch: .* is out'"
jq '.cooldowns = {}' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"

section "a sign-in cut off while it waits for you"
mark; check "add erin is queued" relay add erin
check "Claude opens signed out" wait_for "running && [ ! -f '$P/Cookies' ]" 20
check "stopping the job (launchd's SIGTERM)" kill -TERM "$(job_pid)"
check "puts bob's sign-in back at once" wait_log "signin: cut off; put bob's sign-in back" 30
check "Claude is on bob" test "$(signed_in_as "$P/Cookies")" = "$B"
check "Claude is running" wait_for running 10
wait_for "[ -z \"\$(job_pid)\" ]" 10
mark; check "add erin is queued again" relay add erin
check "Claude opens signed out" wait_for "running && [ ! -f '$P/Cookies' ]" 20
check "killing the job outright (nothing can run)" kill -KILL "$(job_pid)"
wait_for "[ -z \"\$(job_pid)\" ]" 10
check "doctor says the sign-in is still parked" sh -c "'$REPO/relay.sh' doctor | grep -q 'still parked'"
mark; check "a restart is queued" relay restart
check "it puts bob's sign-in back first" wait_log "recover: put bob's sign-in back into Claude" 30
check "and takes over the lock the killed job left" grep -q "lock: taking over a lock" "$D/relay.log"
check "Claude is on bob" test "$(signed_in_as "$P/Cookies")" = "$B"
check "Claude is running after the restart" wait_for "running && [ -z \"\$(job_pid)\" ]" 30
check "erin wasn't added" test -z "$(uuid_of erin)"
check "doctor is happy" relay doctor

section "the keep-alive skips while something holds the lock"
mkdir "$D/switch.lock"; echo $$ > "$D/switch.lock/pid"; echo use > "$D/switch.lock/what"
notes=$(wc -l < "$H/notifications.log")
mark; check "keepalive runs" relay keepalive --force
check "it skips alice" wait_log "keepalive: a switch or sign-in is running; skipped alice" 5
check "without calling it not renewed" sh -c "! tail -n +$((MARK + 1)) '$D/relay.log' | grep -q 'not renewed'"
check "or notifying" test "$(wc -l < "$H/notifications.log")" = "$notes"
check "use is refused while the lock is held" sh -c "! '$REPO/relay.sh' use alice 2>/dev/null"
check "remove is refused while the lock is held" sh -c "! '$REPO/relay.sh' remove alice 2>'$T/err' && grep -q 'a switch or sign-in is running' '$T/err'"
check "alice is still set up" test "$(uuid_of alice)" = "$A"
check "doctor counts a live owner's lock as held" sh -c "'$REPO/relay.sh' doctor | grep -q 'is running now (use, pid $$)'"
# The lock's pid now belongs to a process started after the lock was made: a reused pid.
sleep 30 & young=$!; echo "$young" > "$D/switch.lock/pid"; touch -t "$(date -v-1H +%Y%m%d%H%M)" "$D/switch.lock"
check "doctor counts a lock whose pid was reused as left over" sh -c "'$REPO/relay.sh' doctor | grep -q 'a lock is left from a run that was cut off'"
kill "$young" 2>/dev/null
rm -rf "$D/switch.lock"

# One hook event in a Code tab session (account $1, session $2), through the mod's real hooks
# in the stand-in Claude Code host. What the session would show goes to mod-host.log.
mod_event() { local a="$1" s="$2"; shift 2; CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_ACCOUNT_UUID="$a" MOD_SESSION="$s" bun "$REPO/tests/fakes/mod-host.ts" "$@"; }
shown() { grep -F "\"session\":\"$1\"" "$H/mod-host.log" 2>/dev/null | grep -F "\"kind\":\"$2\"" | grep -qF "$3"; }
in_handoff() { jq -e --arg s "$1" 'any(.resume[]; .sessionId == $s)' "$D/handoff.json" >/dev/null; }
FULL='[{"kind":"five_hour","percentUsed":100,"resetsAt":"'"$(date -u -v+3H +%FT%TZ)"'"}]'

section "the mod: two sessions hit the limit at the same moment"
mod_event "$B" m-busy classic.UserPromptSubmit '{"session_id":"m-busy","cwd":"/tmp"}'
check "a session mid-turn is marked busy" test -f "$D/busy/m-busy.json"
mark
MOD_USAGE="$FULL" mod_event "$B" m-one classic.StopFailure '{"session_id":"m-one","cwd":"/tmp","error":"rate_limit"}' &
MOD_USAGE="$FULL" mod_event "$B" m-two classic.StopFailure '{"session_id":"m-two","cwd":"/tmp","error":"rate_limit"}' &
wait
check "both sessions and the busy one are listed, once each" jq -e '[.resume[].sessionId | select(startswith("m-"))] | sort == ["m-busy","m-one","m-two"]' "$D/handoff.json"
check "the session is told a switch is coming" shown m-one toast "Switching to another account"
check "it switches away from bob" wait_log "swap: bob -> alice" 40
check "bob cools down" jq -e --arg b "$B" '.cooldowns[$b] > (now | todate)' "$D/state.json"
for s in m-one m-two m-busy; do check "$s is reopened" wait_for "grep -q 'session=$s' '$H/links.log'" 30; done
wait_log "switch: done" 20
for s in m-one m-two m-busy; do mod_event "$A" "$s" classic.SessionStart '{"session_id":"'"$s"'","source":"resume","transcript_path":"/dev/null"}' & done
wait
for s in m-one m-two m-busy; do check "$s gets the carry-on message" shown "$s" prompt "ran out of usage"; done
check "and every entry is used up, none put back by another session" sh -c "! jq -e 'any(.resume[]; .sessionId | startswith(\"m-\"))' '$D/handoff.json'"
mod_event "$A" m-one classic.SessionStart '{"session_id":"m-one","source":"resume","transcript_path":"/dev/null"}'
check "starting again doesn't send it twice" test "$(grep -c '"session":"m-one","kind":"prompt"' "$H/mod-host.log")" = 1
jq '.cooldowns = {}' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"

section "the mod: sessions cut off mid-turn by a switch by hand, or a restart"
mod_event "$A" m-cut classic.UserPromptSubmit '{"session_id":"m-cut","cwd":"/tmp"}'
mark; check "use bob" relay use bob
check "the switch finishes" wait_log "swap: alice -> bob" 40
check "the cut-off session is reopened" wait_for "grep -q 'session=m-cut' '$H/links.log'" 30
wait_for "[ -z \"\$(job_pid)\" ]" 30
mod_event "$B" m-cut classic.SessionStart '{"session_id":"m-cut","source":"resume","transcript_path":"/dev/null"}'
check "it's told it was moved to another account mid-turn" shown m-cut prompt "moved to another Claude account while this session was mid-turn"
mod_event "$B" m-cut2 classic.UserPromptSubmit '{"session_id":"m-cut2","cwd":"/tmp"}'
mark; check "a restart" relay restart
check "the session cut off by it is reopened" wait_for "grep -q 'session=m-cut2' '$H/links.log'" 40
wait_for "[ -z \"\$(job_pid)\" ]" 30
mod_event "$B" m-cut2 classic.SessionStart '{"session_id":"m-cut2","source":"resume","transcript_path":"/dev/null"}'
check "it's told Claude was closed and reopened mid-turn" shown m-cut2 prompt "closed and reopened while this session was mid-turn"
hand_entry() { jq --arg s "$1" --arg at "$(date -u -v-1S +%FT%TZ)" '.resume += [{sessionId: $s, cwd: "", reason: "restart", account: "", at: $at}]' "$D/handoff.json" > "$T/h" && mv "$T/h" "$D/handoff.json"; }
hand_entry m-cut3
mod_event "$B" m-cut3 classic.SessionStart '{"session_id":"m-cut3","source":"compact","transcript_path":"/dev/null"}'
check "a compact doesn't count as a reopen" sh -c "! grep -q '\"session\":\"m-cut3\"' '$H/mod-host.log' && jq -e 'any(.resume[]; .sessionId == \"m-cut3\")' '$D/handoff.json'"

section "the mod: a limit with auto-switch off, and a switch that can't start"
jq '.armed = false' "$D/config.json" > "$T/c" && mv "$T/c" "$D/config.json"
MOD_USAGE="$FULL" mod_event "$B" m-off classic.StopFailure '{"session_id":"m-off","cwd":"/tmp","error":"rate_limit"}'
check "auto-switch off: it says so" shown m-off toast "Auto-switch is off"
check "and lists nothing to reopen" sh -c "! jq -e 'any(.resume[]; .sessionId == \"m-off\")' '$D/handoff.json'"
jq '.armed = true' "$D/config.json" > "$T/c" && mv "$T/c" "$D/config.json"
mv "$D/relay.sh" "$D/relay.sh.off"
MOD_USAGE="$FULL" mod_event "$B" m-fail classic.StopFailure '{"session_id":"m-fail","cwd":"/tmp","error":"rate_limit"}'
mv "$D/relay.sh.off" "$D/relay.sh"
check "a switch that can't start: it says so" shown m-fail toast "the switch couldn't start"
check "and takes its entry back" sh -c "! jq -e 'any(.resume[]; .sessionId == \"m-fail\")' '$D/handoff.json'"
check "Claude stays on bob" test "$(signed_in_as "$P/Cookies")" = "$B"
MOD_USAGE='[{"kind":"five_hour","percentUsed":40}]' mod_event "$B" m-rate classic.StopFailure '{"session_id":"m-rate","cwd":"/tmp","error":"rate_limit"}'
check "a rate limit with usage left doesn't switch" sh -c "! jq -e 'any(.resume[]; .sessionId == \"m-rate\")' '$D/handoff.json' && grep -q 'rate_limit in m-rate but no window near full' '$D/relay.log'"
CLAUDE_CODE_ENTRYPOINT=cli MOD_SESSION=m-term MOD_IDENTITY=api-key MOD_USAGE="$FULL" bun "$REPO/tests/fakes/mod-host.ts" classic.StopFailure '{"session_id":"m-term","cwd":"/tmp","error":"rate_limit"}'
check "a terminal claude's limit on an API key lists nothing" sh -c "! jq -e 'any(.resume[]; .sessionId == \"m-term\")' '$D/handoff.json'"
check "and moves nothing" test "$(signed_in_as "$P/Cookies")" = "$B"

section "switching while Claude is signed out"
cp "$P/Cookies" "$T/bob.live"
pkill -f "^$APPDIR/Contents/MacOS/Claude"; wait_for "! running" 10
sqlite3 "$T/out" "create table cookies(host_key text, name text, value text, expires_utc integer);" && mv "$T/out" "$P/Cookies"
open -a "$APPDIR"; wait_for running 5
check "doctor says Claude is signed out of bob" sh -c "'$REPO/relay.sh' doctor | grep -q 'Claude is signed out of bob'"
mark; check "use alice is queued" relay use alice
check "it switches" wait_log "swap: bob -> alice" 40
check "Claude is on alice" test "$(signed_in_as "$P/Cookies")" = "$A"
check "status says bob isn't signed in" sh -c "'$REPO/relay.sh' status | grep -q 'bob .*not signed in'"
check "a limit switch wouldn't pick bob" sh -c "'$REPO/relay.sh' plan --from $A | grep -q nobody"
mv "$T/bob.live" "$D/park/$B/Cookies"

section "moving from the old launchd label"
cp "$H/Library/LaunchAgents/local.desktop-account-switcher.keepalive.plist" "$H/Library/LaunchAgents/com.jun.desktop-account-switcher.keepalive.plist"
echo com.jun.desktop-account-switcher.keepalive >> "$H/launchd.loaded"
check "install-keepalive" relay install-keepalive
check "the old job is gone" sh -c "! grep -q com.jun '$H/launchd.loaded' && [ ! -f '$H/Library/LaunchAgents/com.jun.desktop-account-switcher.keepalive.plist' ]"
check "the new one is loaded" grep -qx local.desktop-account-switcher.keepalive "$H/launchd.loaded"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || { echo "relay.log:"; tail -30 "$D/relay.log"; echo "jobs.out:"; tail -10 "$H/jobs.out" 2>/dev/null; }
[ "$failed" -eq 0 ]
