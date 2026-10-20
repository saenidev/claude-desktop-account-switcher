#!/bin/bash
# End-to-end tests: run relay.sh the way a person does, in a throwaway home folder, against a
# stand-in Claude app and stand-ins for open, launchctl, the Keychain, notifications and the
# claude CLI (tests/fakes). Nothing touches the real Claude, Keychain or launchd.
#   tests/e2e.sh                      (about a minute)
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
  sqlite3 "$1" "create table cookies(name text, value text, expires_utc integer);
    insert into cookies values('sessionKey', '$2', ($(date -u +%s) + 20*86400 + 11644473600) * 1000000);"
}
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
section() { echo; echo "$*"; }

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

section "terminal claude follows the app"
mkdir -p "$H/keychain/Claude Code-credentials"
printf 'token-for-alice' > "$H/keychain/Claude Code-credentials/$USER"; jq -n --arg u "$A" '{oauthAccount: {accountUuid: $u}}' > "$H/.claude.json"
check "cli-save parks alice's terminal login" relay cli-save
printf 'token-for-bob' > "$H/keychain/Claude Code-credentials/$USER"; jq -n --arg u "$B" '{oauthAccount: {accountUuid: $u}}' > "$H/.claude.json"
check "cli-save parks bob's terminal login" relay cli-save
check "cli-use alice moves the terminal back" relay cli-use alice
check "the terminal login is alice's" test "$(cat "$H/keychain/Claude Code-credentials/$USER")" = token-for-alice

section "switch by hand, reopening the session"
mark; check "use bob is queued" relay use bob --resume session-1
check "the switch finishes" wait_log "swap: alice -> bob" 40
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
wait_log "switch: done" 20

section "every account out"
jq --arg at "$(date -u +%FT%TZ)" '.resume += [{sessionId: "session-3", cwd: "", reason: "limit hit", at: $at}]' "$D/handoff.json" > "$T/h" && mv "$T/h" "$D/handoff.json"
check "a switch with nowhere to go fails" sh -c "XPC_SERVICE_NAME=local.desktop-account-switcher '$REPO/relay.sh' switch --from $A 2>/dev/null; [ \$? -ne 0 ]"
check "Claude stays on alice" test "$(signed_in_as "$P/Cookies")" = "$A"
check "you're told" grep -q "every other account is too" "$H/notifications.log"
check "the limit's hand-off is dropped" sh -c "! jq -e '.resume[] | select(.sessionId == \"session-3\")' '$D/handoff.json'"
jq '.cooldowns = {}' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"

section "the app's files moved (an app update)"
jq 'del(.lastKnownAccountUuid) | .lastKnownAccount = "moved"' "$P/config.json" > "$T/c" && cp "$P/config.json" "$T/c.saved" && mv "$T/c" "$P/config.json"
mark; check "use bob is queued" relay use bob
check "the switch refuses" wait_log "swap: not switching" 30
check "Claude keeps alice's sign-in" test "$(signed_in_as "$P/Cookies")" = "$A"
check "bob stays parked" test "$(signed_in_as "$D/park/$B/Cookies")" = "$B"
check "doctor says what's wrong" sh -c "'$REPO/relay.sh' doctor | grep -q 'lastKnownAccountUuid'"
mv "$T/c.saved" "$P/config.json"

section "a third account, with the shared list already there"
mark; check "add carol is queued" relay add carol
check "Claude opens signed out" wait_for "running && [ ! -f '$P/Cookies' ]" 20
sign_in "$C"
check "carol is added" wait_log "signin: back on alice" 60
check "carol has her ids" test "$(uuid_of carol):$(org_of carol)" = "$C:$OC"
check "carol's list links to the same shared one" test "$(readlink "$P/claude-code-sessions/$C/$OC")" = "$P/claude-code-sessions/$A/$OA"
check "doctor is happy with three" relay doctor

section "signing in to a known account under a new name"
mark; check "add dave is queued" relay add dave
check "Claude opens signed out" wait_for "running && [ ! -f '$P/Cookies' ]" 20
sign_in "$B"
check "it's kept as bob" wait_log "that sign-in is bob" 60
check "nobody named dave is added" wait_for "[ -z \"\$(uuid_of dave)\" ] && tail -n +$((MARK + 1)) '$D/relay.log' | grep -q 'signin: back on alice'" 30
check "bob's new sign-in is parked" test "$(signed_in_as "$D/park/$B/Cookies")" = "$B"

section "remove an account"
check "removing the account Claude is on is refused" sh -c "! '$REPO/relay.sh' remove alice 2>/dev/null"
check "remove carol" relay remove carol
check "carol is gone from accounts.json" test -z "$(uuid_of carol)"
check "her sign-in is kept in backups" sh -c "ls '$D'/backups/*-removed-carol/park/Cookies"
check "no parked sign-in is left for her" test ! -e "$D/park/$C"

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
