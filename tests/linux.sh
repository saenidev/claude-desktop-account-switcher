#!/bin/bash
# End-to-end tests for Linux, where there's no desktop app: run relay.sh the way a person and
# the systemd timer do, in a throwaway home folder, against stand-ins for the claude CLI's
# sign-in and renewal, Anthropic's usage endpoint (a stand-in curl) and systemctl
# (tests/fakes/linux). The relay under test is a git checkout of this working tree, cloned from
# a throwaway "GitHub" beside it, so self-update pulls for real. Then the real claude, if there
# is one: a running session following a move, and a session hitting a usage limit, both against
# a stand-in API, with no real account. Nothing touches the real login, timer or repo.
#   tests/linux.sh            on a Linux machine (about two minutes)
#   E2E_FAILFAST=1 tests/linux.sh
set -u
[ "$(uname)" = Linux ] || { echo "tests/linux.sh runs on Linux; on a Mac, tests/e2e.sh" >&2; exit 2; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/cdas-linux.XXXXXX")
H="$T/home"; REPO="$H/repo"; D="$H/.claude/desktop-account-switcher"
A=aaaaaaaa-0000-4000-8000-000000000001; OA=aaaaaaaa-0000-4000-8000-0000000000a1
B=bbbbbbbb-0000-4000-8000-000000000002; OB=bbbbbbbb-0000-4000-8000-0000000000b2
C=cccccccc-0000-4000-8000-000000000003; OC=cccccccc-0000-4000-8000-0000000000c3
passed=0; failed=0
REAL_CLAUDE=$(command -v claude || true); REAL_PATH="$PATH"
JS=$(command -v bun || command -v node || true); TMUX_BIN=$(command -v tmux || true)

cleanup() { [ -n "${RUNTMUX:-}" ] && "$TMUX_BIN" -L "$RUNTMUX" kill-server 2>/dev/null; [ -n "${E2E_KEEP:-}" ] && { echo "kept $T"; return; }; rm -rf "$T"; }
trap cleanup EXIT

# ---- The stand-in world ----
mkdir -p "$H/.local/bin" "$H/.claude" "$H/api/usage" "$T/src"
for f in claude curl systemctl loginctl; do cp "$SRC/tests/fakes/linux/$f" "$H/.local/bin/$f"; chmod +x "$H/.local/bin/$f"; done
# This working tree as a commit on a throwaway "GitHub", and the machine's checkout of it.
(cd "$SRC" && tar cf - --exclude=.git --exclude=dock-icon .) | (cd "$T/src" && tar xf -)
git_q() { git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
git_q init --bare "$T/origin.git"
(cd "$T/src" && git_q init && git_q add -A && git_q commit -m "the version under test" && git_q branch -M main && git_q remote add origin "$T/origin.git" && git_q push -u origin main)
git_q clone "$T/origin.git" "$REPO"

export HOME="$H" ACCOUNT_SWITCHER_FAST=1
export PATH="$H/.local/bin:$PATH"
unset CLAUDE_CONFIG_DIR CLAUDECODE CLAUDE_CODE_CHILD_SESSION
relay() { "$REPO/relay.sh" "$@"; }

wait_for() { local n=0; until eval "$1"; do sleep 0.5; n=$((n+1)); [ $n -lt $(( ${2:-30} * 2 )) ] || return 1; done; }
MARK=0
mark() { MARK=$(wc -l < "$D/relay.log" 2>/dev/null || echo 0); }
logged() { tail -n +$((MARK + 1)) "$D/relay.log" 2>/dev/null | grep -q "$1"; }
uuid_of() { jq -r --arg n "$1" '.accounts[] | select(.name == $n) | .accountUuid // empty' "$D/accounts.json"; }
check() {   # check "<what>" <command...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then passed=$((passed+1)); echo "  ok  $what"
  else
    failed=$((failed+1)); echo "  FAIL $what"
    [ -n "${E2E_FAILFAST:-}" ] && { echo "relay.log:"; tail -20 "$D/relay.log"; echo "state:"; cat "$D/state.json"; exit 1; }
  fi
}
section() { echo; echo "$*  (${SECONDS}s)"; }

# A login for <name>, as claude keeps one: its access token good until <epoch ms>.
login_json() { jq -nc --arg n "$1" --argjson e "$2" '{claudeAiOauth: {accessToken: "at-\($n)", refreshToken: "rt-\($n)", expiresAt: $e, scopes: ["user:inference", "user:profile"]}}'; }
in_hours() { echo $(( ($(date +%s) + $1 * 3600) * 1000 )); }
iso_in() { date -u -d "+$1" +%FT%TZ; }
# What Anthropic says <name> has used: set_usage <name> <5-hour %> <weekly %> [<model> <its weekly %>]
set_usage() {
  jq -n --argjson f "$2" --argjson w "$3" --arg m "${4:-}" --argjson mp "${5:-0}" --arg fr "$(iso_in '2 hours')" --arg wr "$(iso_in '3 days')" '
    {five_hour: {utilization: $f, resets_at: $fr}, seven_day: {utilization: $w, resets_at: $wr},
     limits: (if $m == "" then [] else [{kind: "weekly_scoped", scope: {model: {display_name: $m}}, percent: $mp, resets_at: $wr}] end)}' > "$H/api/usage/$1.json"
}
# One round of the timer, with every account's usage read anew (as if ten minutes had passed).
tick() { jq '.usageCheckedAt = 0 | del(.usageWaitUntil)' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"; relay tick; }
state_reset() { jq '.cooldowns = {} | del(.pinned, .watchSaid, .watchMoves, .cliDead, .cliRenewTriedAt)' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"; }
live_is() { [ "$(jq -r .claudeAiOauth.refreshToken "$H/.claude/.credentials.json" | cut -d- -f2 | tr -d '+')" = "$1" ] && [ "$(jq -r .oauthAccount.accountUuid "$H/.claude.json")" = "$(uuid_of "$1")" ]; }
parked_is() { [ "$(jq -r .claudeAiOauth.refreshToken "$D/park/$(uuid_of "$1")/credentials.json" 2>/dev/null)" = "$2" ]; }
cooling() { jq -e --arg a "$(uuid_of "$1")" '.cooldowns[$a] // "" | . != "" and . > (now | todate)' "$D/state.json" >/dev/null; }
# Back to alice in use, both accounts with usage left, and the readings saying so.
settle() { relay use alice >/dev/null 2>&1; set_usage alice 5 30; set_usage bob 5 10; state_reset; relay usage --force >/dev/null; }
notified() { grep -qF "$1" "$H/notified.log" 2>/dev/null; }

# ---- A Linux machine with terminal claude signed in to one account ----
( umask 077; login_json alice "$(in_hours 7)" > "$H/.claude/.credentials.json" )
jq -n --arg u "$A" --arg o "$OA" '{oauthAccount: {accountUuid: $u, organizationUuid: $o, emailAddress: "alice@example.com"}, userID: "kept"}' > "$H/.claude.json"

section "help and commands before setup"
check "help is the Linux one" sh -c "'$REPO/relay.sh' help | grep -q 'Claude account switcher, on Linux'"
check "status before setup says to run setup" sh -c "'$REPO/relay.sh' status 2>&1 | grep -q 'relay.sh setup'"
check "an unknown command fails" sh -c "! '$REPO/relay.sh' frobnicate 2>/dev/null"

section "setup"
check "setup without a name asks for one" sh -c "! '$REPO/relay.sh' setup 2>/dev/null"
check "setup alice succeeds" relay setup alice
check "alice has the id, org and email claude is signed in with" jq -e --arg u "$A" --arg o "$OA" '.accounts == [{name: "alice", accountUuid: $u, orgUuid: $o, email: "alice@example.com"}]' "$D/accounts.json"
check "relay.sh is linked into the data folder" test "$(readlink "$D/relay.sh")" = "$REPO/relay.sh"
check "the mod is linked" test "$(readlink "$D/mod")" = "$REPO/mod"
check "the mod is installed" jq -e '.enabledPlugins["desktop-account-switcher@desktop-account-switcher-local"] == true' "$H/.claude/settings.json"
check "auto-switch is on" jq -e '.armed == true' "$D/config.json"
check "the timer's service runs a round of this relay" grep -qF "ExecStart=/bin/bash \"$D/relay.sh\" tick" "$H/.config/systemd/user/desktop-account-switcher.service"
check "the timer is every two minutes" grep -q "OnUnitInactiveSec=2min" "$H/.config/systemd/user/desktop-account-switcher.timer"
check "the timer is started" grep -qx "desktop-account-switcher.timer" "$H/systemd.active"
check "setup again changes nothing" sh -c "'$REPO/relay.sh' setup >/dev/null && [ \$(jq '.accounts | length' '$D/accounts.json') = 1 ] && [ \$(grep -c daemon-reload '$H/systemd.log') = 1 ]"
check "doctor wants a second account" sh -c "'$REPO/relay.sh' doctor | grep -q '1 account(s)'"
check "a command for the desktop app says Linux has none" sh -c "'$REPO/relay.sh' restart 2>&1 | grep -q 'Linux has none'"
printf '#!/bin/bash\necho "$1" >> "$HOME/notified.log"\n' > "$D/notify"; chmod +x "$D/notify"

section "add a second account (the sign-in never touches the live login)"
cp "$H/.claude/.credentials.json" "$T/alice.live"
echo "cancel" > "$H/cli-login-as"
check "a sign-in that's given up adds nothing" sh -c "! '$REPO/relay.sh' add bob 2>'$T/err' && grep -q \"didn't finish; nothing changed\" '$T/err' && [ -z \"\$(jq -r '.accounts[1].name // empty' '$D/accounts.json')\" ]"
echo "bob $B $OB" > "$H/cli-login-as"
check "add bob succeeds" relay add bob
check "claude signed in with its config folder set to a throwaway one" grep -q "auth login --claudeai CLAUDE_CONFIG_DIR=$D/login" "$H/claude-cli.log"
check "bob is added with the id, org and email he signed in with" jq -e --arg u "$B" --arg o "$OB" '.accounts[1] == {name: "bob", accountUuid: $u, orgUuid: $o, email: "bob@example.com"}' "$D/accounts.json"
check "bob's login is parked" parked_is bob rt-bob-fresh
check "only you can read it" test "$(stat -c %a "$D/park/$B/credentials.json" "$D/park" | tr '\n' ' ')" = "600 700 "
check "the live login is alice's, untouched" cmp -s "$T/alice.live" "$H/.claude/.credentials.json"
check "and claude still says alice" test "$(jq -r '.oauthAccount.accountUuid + " " + .userID' "$H/.claude.json")" = "$A kept"
check "the throwaway folder is gone" test ! -e "$D/login"
check "add with a name already set up is refused" sh -c "! '$REPO/relay.sh' add bob 2>'$T/err' && grep -q 'bob is already set up; to sign it in again use relay.sh signin bob' '$T/err'"
check "signin with a name not set up is refused" sh -c "! '$REPO/relay.sh' signin zed 2>'$T/err' && grep -q 'relay.sh add zed' '$T/err'"
echo "alice $A $OA" > "$H/cli-login-as"
check "adding carol with the browser on alice (in use) is refused" sh -c "! '$REPO/relay.sh' add carol 2>'$T/err' && grep -q 'that sign-in was alice, which terminal claude is on already, not carol; nothing changed' '$T/err'"
check "and the live login is still the one it was" cmp -s "$T/alice.live" "$H/.claude/.credentials.json"
echo "bob $B $OB" > "$H/cli-login-as"; ( umask 077; login_json bob-old 0 > "$D/park/$B/credentials.json" )
check "adding carol with the browser on bob is refused, the login kept as bob's" sh -c "! '$REPO/relay.sh' add carol 2>'$T/err' && grep -q \"that sign-in was bob, not carol; it's kept as bob's\" '$T/err'"
check "bob's parked login is the new one" parked_is bob rt-bob-fresh
check "carol wasn't added" test -z "$(uuid_of carol)"
check "the refusal says how to pick the right account" grep -q "open the link in a browser signed in as carol" "$T/err"
check "doctor is happy" relay doctor
check "status shows both, bob ready" sh -c "'$REPO/relay.sh' status | grep -q 'bob  bob@example.com  parked, ready to switch to'"

section "switching by hand"
mark; check "use bob" relay use bob
check "terminal claude is on bob" live_is bob
check "claude's account record is bob's, the rest of its config kept" test "$(jq -r '.oauthAccount.emailAddress + " " + .userID' "$H/.claude.json")" = "bob@example.com kept"
check "alice's login was parked first" parked_is alice rt-alice
check "it's logged" logged "terminal: alice -> bob"
check "use alice goes back" relay use alice
check "terminal claude is on alice" live_is alice
check "use with no such account is refused" sh -c "! '$REPO/relay.sh' use zed 2>/dev/null"
state_reset

section "the timer: moving on before the account runs out"
set_usage alice 20 30; set_usage bob 5 10
mark; tick; check "a round with usage left moves nothing" live_is alice
check "both accounts' usage was read" sh -c "'$REPO/relay.sh' status | grep -A1 '^  bob' | grep -q 'usage: 5-hour 5% · weekly 10%'"
check "the round is noted" jq -e '.tickAt > 0' "$D/state.json"
set_usage alice 96 30
mark; tick
check "at 96% of the 5-hour window, terminal claude moves to bob" live_is bob
check "it's logged with why" logged "watch: alice is nearly out (5-hour 96%); terminal claude moved to bob"
check "and notified" notified "alice is nearly out (5-hour 96%). Moved to bob."
check "alice isn't cooling down: she has usage left" sh -c "! jq -e --arg a $A '.cooldowns[\$a]' '$D/state.json'"
set_usage bob 97 10
mark; tick; tick
check "bob nearly out too, with nowhere better to go: it stays on bob" live_is bob
check "and says nothing about it" sh -c "! tail -n +$((MARK + 1)) '$D/relay.log' | grep -q 'watch:'"
set_usage bob 100 10
mark; tick
check "bob out: terminal claude moves to alice, who has 4% left" live_is alice
check "it's logged" logged "watch: bob is out of usage (5-hour 100%); terminal claude moved to alice"
check "bob cools down until his reset" cooling bob
set_usage alice 100 30
mark; : > "$H/notified.log"; tick; tick; tick
check "alice out too: nothing to move to, and it stays" live_is alice
check "it says so once, not every round" test "$(tail -n +$((MARK + 1)) "$D/relay.log" | grep -c 'watch: alice is out of usage (5-hour 100%), and no other account has usage left')" = 1
check "and notifies once" test "$(grep -c 'no other account has usage left' "$H/notified.log")" = 1
set_usage alice 3 30; set_usage bob 2 10; state_reset
mark; tick
check "after the resets, a round is quiet again" sh -c "! tail -n +$((MARK + 1)) '$D/relay.log' | grep -q 'watch:'"

section "the timer: an account you chose, a model's own limit, a benched account"
set_usage alice 20 30; set_usage bob 96 10
relay use bob >/dev/null; mark; tick
check "bob, chosen by hand at 96%, is left alone" live_is bob
set_usage bob 100 10; tick
check "until he's out" live_is alice
state_reset; set_usage bob 5 10
set_usage alice 20 30 Fable 100
mark; tick
check "alice's Fable weekly limit used up: terminal claude moves to bob" live_is bob
check "it's logged" logged "watch: alice's Fable weekly limit is used up; terminal claude moved to bob"
set_usage alice 20 30 Fable 100; set_usage bob 5 10 Opus 100
mark; tick
check "bob's Opus limit used up, alice's Fable too: no shuffling between them" live_is bob
set_usage bob 5 10; set_usage alice 100 30; relay use alice >/dev/null; state_reset
relay bench bob >/dev/null; mark; tick
check "alice out with bob benched: it stays on alice" live_is alice
check "and says there's nowhere to go" logged "watch: alice is out of usage (5-hour 100%), and no other account has usage left"
relay unbench bob >/dev/null; state_reset; tick
check "bob back in: terminal claude moves to him" live_is bob
settle

section "the timer: auto-switch off, and too many switches"
jq '.armed = false' "$D/config.json" > "$T/c" && mv "$T/c" "$D/config.json"
set_usage alice 100 30; mark; tick
check "with auto-switch off, alice out moves nothing" live_is alice
jq '.armed = true' "$D/config.json" > "$T/c" && mv "$T/c" "$D/config.json"
jq --argjson n "$(date +%s)" '.watchMoves = [range(0; 6) | $n - (. * 60)]' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"
mark; : > "$H/notified.log"; tick; tick
check "six switches in the hour: it stops switching" live_is alice
check "and says so once" test "$(tail -n +$((MARK + 1)) "$D/relay.log" | grep -c 'watch: 6 switches in the last hour, so the timer has stopped switching')" = 1
jq --argjson n "$(date +%s)" '.watchMoves = [range(0; 6) | $n - 4000]' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"
tick
check "an hour later it switches again" live_is bob
settle

section "close to a limit, the account in use is read every round"
set_usage alice 88 30; tick
: > "$H/api/calls.log"; relay tick
check "a round right after a reading asks nothing" test "$(wc -l < "$H/api/calls.log")" = 0
jq --arg a "$A" '.[$a].at -= 200000' "$D/usage.json" > "$T/u" && mv "$T/u" "$D/usage.json"
relay tick
check "two minutes on, alice (at 88%) is read again, and only alice" test "$(cat "$H/api/calls.log")" = alice
set_usage alice 5 30; tick
jq --arg a "$A" '.[$a].at -= 200000' "$D/usage.json" > "$T/u" && mv "$T/u" "$D/usage.json"
: > "$H/api/calls.log"; relay tick
check "with plenty left, the ten minutes hold" test "$(wc -l < "$H/api/calls.log")" = 0
touch "$H/api/limited"; mark; tick
check "when Anthropic rate-limits the checks, they stop for 15 minutes" sh -c "tail -n +$((MARK + 1)) '$D/relay.log' | grep -q 'rate-limiting usage checks' && jq -e '.usageWaitUntil > now' '$D/state.json'"
rm "$H/api/limited"; state_reset; tick

section "parked logins are renewed, and one that stopped working is caught"
( umask 077; login_json bob "$(in_hours -1)" > "$D/park/$B/credentials.json" )
mark; tick
check "bob's parked login, run out, is renewed by claude in a throwaway home" parked_is bob "rt-bob+"
check "it's good again" jq -e '.claudeAiOauth.expiresAt > (now * 1000)' "$D/park/$B/credentials.json"
check "still only yours to read" test "$(stat -c %a "$D/park/$B/credentials.json")" = 600
check "the live login is untouched" live_is alice
check "the throwaway home is gone" test ! -e "$D/cli-renew"
check "and bob's usage is read with it" sh -c "'$REPO/relay.sh' usage | grep -q '^bob: .*read live from Anthropic'"
( umask 077; login_json bob-revoked "$(in_hours -1)" > "$D/park/$B/credentials.json" )
state_reset; mark; : > "$H/notified.log"; tick
check "a parked login revoked elsewhere is marked" jq -e --arg b "$B" '.cliDead[$b] > 0' "$D/state.json"
check "you're told to sign it in again" notified "bob's terminal login no longer works. Run relay.sh cli-login bob"
check "doctor flags it, with the command" sh -c "'$REPO/relay.sh' doctor | grep -q \"^!!  bob's parked login no longer works.*relay.sh signin bob\""
set_usage alice 100 30; mark; tick
check "alice out, bob's login dead: it stays on alice" live_is alice
check "use bob is refused" sh -c "! '$REPO/relay.sh' use bob 2>/dev/null"
echo "alice $A $OA" > "$H/cli-login-as"
check "signing bob in with the browser on alice is refused" sh -c "! '$REPO/relay.sh' signin bob 2>'$T/err' && grep -q 'that sign-in was alice, which terminal claude is on already, not bob' '$T/err'"
echo "carol $C $OC" > "$H/cli-login-as"
check "and with it on an account that isn't set up" sh -c "! '$REPO/relay.sh' signin bob 2>'$T/err' && grep -q 'that sign-in was carol@example.com, not bob; nothing kept' '$T/err'"
echo "bob $B $OB" > "$H/cli-login-as"
check "signin bob (cli-login works too) parks a new login" relay cli-login bob
check "claude was given bob's email for the sign-in page" grep -q "auth login --claudeai --email bob@example.com" "$H/claude-cli.log"
check "bob isn't marked dead any more" sh -c "! jq -e --arg b $B '.cliDead[\$b]' '$D/state.json'"
tick
check "and the next round moves to him" live_is bob
settle

section "a session hits a limit (what the mod runs: cli-switch)"
set_usage alice 40 30; mark
check "with usage left on the terminal's account, nothing moves" sh -c "'$REPO/relay.sh' cli-switch && [ \"\$(jq -r .oauthAccount.accountUuid '$H/.claude.json')\" = $A ]"
check "and alice isn't cooled down for it" sh -c "! jq -e --arg a $A '.cooldowns[\$a]' '$D/state.json'"
check "it's logged" logged "a session hit a limit, but alice, which terminal claude is on now, has usage left; not switching"
set_usage alice 100 30; mark
check "with alice used up, it moves" relay cli-switch "$(iso_in '2 hours')"
check "to bob" live_is bob
check "alice cools down" cooling alice
check "a second session's limit, arriving after the move, changes nothing" sh -c "'$REPO/relay.sh' cli-switch && [ \"\$(jq -r .oauthAccount.accountUuid '$H/.claude.json')\" = $B ]"
check "bob isn't cooled down for alice's limit" sh -c "! jq -e --arg b $B '.cooldowns[\$b]' '$D/state.json'"
relay use alice >/dev/null; state_reset
jq '.armed = false' "$D/config.json" > "$T/c" && mv "$T/c" "$D/config.json"
check "with auto-switch off, a session's limit moves nothing" sh -c "'$REPO/relay.sh' cli-switch && [ \"\$(jq -r .oauthAccount.accountUuid '$H/.claude.json')\" = $A ]"
jq '.armed = true' "$D/config.json" > "$T/c" && mv "$T/c" "$D/config.json"
settle

section "one thing at a time"
mkdir "$D/switch.lock"; echo $$ > "$D/switch.lock/pid"; echo signin > "$D/switch.lock/what"
set_usage alice 100 30; mark
check "a round while a sign-in holds the lock does nothing, quietly" sh -c "'$REPO/relay.sh' tick && [ \"\$(jq -r .oauthAccount.accountUuid '$H/.claude.json')\" = $A ] && ! tail -n +$((MARK + 1)) '$D/relay.log' | grep -q ."
check "use is turned away" sh -c "! '$REPO/relay.sh' use bob 2>'$T/err' && grep -q 'a switch or sign-in is running' '$T/err'"
check "doctor says who holds it" sh -c "'$REPO/relay.sh' doctor | grep -q 'is running now (signin, pid $$)'"
sleep 30 & young=$!; echo "$young" > "$D/switch.lock/pid"; touch -d '1 hour ago' "$D/switch.lock"
tick; check "a lock whose pid was reused is taken over" grep -q 'lock: taking over a lock' "$D/relay.log"
check "and that round did its work" live_is bob
kill "$young" 2>/dev/null
check "no lock is left" test ! -e "$D/switch.lock"
settle

section "it updates itself"
check "self-update with nothing new says so" sh -c "'$REPO/relay.sh' self-update | grep -q '^up to date'"
publish() { (cd "$T/src" && echo "$1" > NEWS && git_q add -A && git_q commit -m "$1" && git_q push origin main); }
publish "a new version"
mark; check "self-update pulls a new version" sh -c "'$REPO/relay.sh' self-update | grep -q '^updated '"
check "the checkout has it" test "$(cat "$REPO/NEWS")" = "a new version"
check "it's logged with what changed" logged "update: [0-9a-f]* -> [0-9a-f]* (a new version)"
publish "another"; jq '.updateCheckedAt = 0' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"
relay tick
check "the timer's round pulls the next one by itself" test "$(cat "$REPO/NEWS")" = "another"
publish "a third"; relay tick
check "but only once an hour" test "$(cat "$REPO/NEWS")" = "another"
jq '.autoUpdate = false' "$D/config.json" > "$T/c" && mv "$T/c" "$D/config.json"; jq '.updateCheckedAt = 0' "$D/state.json" > "$T/s" && mv "$T/s" "$D/state.json"
relay tick
check "and not at all with autoUpdate off" test "$(cat "$REPO/NEWS")" = "another"
check "doctor says self-update is off" sh -c "'$REPO/relay.sh' doctor | grep -q 'self-update is off'"
jq 'del(.autoUpdate)' "$D/config.json" > "$T/c" && mv "$T/c" "$D/config.json"
echo "# mine" >> "$REPO/README.md"
mark; check "a checkout with changes of its own isn't updated" sh -c "! '$REPO/relay.sh' self-update 2>'$T/err' && grep -q 'has changes of its own' '$T/err' && [ \"\$(cat '$REPO/NEWS')\" = another ]"
check "doctor says so" sh -c "'$REPO/relay.sh' doctor | grep -q 'has changes of its own'"
(cd "$REPO" && git checkout -q README.md)
check "once they're gone it updates" sh -c "'$REPO/relay.sh' self-update | grep -q '^updated ' && [ \"\$(cat '$REPO/NEWS')\" = 'a third' ]"
check "history shows the switches and the updates" sh -c "'$REPO/relay.sh' history 200 | grep -q 'terminal: alice -> bob' && '$REPO/relay.sh' history 200 | grep -q 'update: '"

section "doctor, and removing an account"
check "doctor is happy" relay doctor
: > "$H/systemd.active"
check "doctor says when the timer isn't running" sh -c "! '$REPO/relay.sh' doctor > '$T/doc' && grep -q \"^!!  the timer isn't running\" '$T/doc'"
check "setup starts it again" sh -c "'$REPO/relay.sh' setup >/dev/null && '$REPO/relay.sh' doctor >/dev/null"
echo no > "$H/linger"
check "doctor warns when the timer would stop at logout" sh -c "'$REPO/relay.sh' doctor | grep -q 'enable-linger'"
rm "$H/linger"
check "remove alice, in use, is refused" sh -c "! '$REPO/relay.sh' remove alice 2>'$T/err' && grep -q 'terminal claude is on alice now' '$T/err'"
check "remove bob" relay remove bob
check "bob is gone from accounts.json" test -z "$(uuid_of bob)"
check "his parked login is deleted, not kept anywhere" sh -c "! grep -rqs 'rt-bob' '$D/park' '$D/backups'"
echo "bob $B $OB" > "$H/cli-login-as"; relay add bob >/dev/null

if [ -z "$REAL_CLAUDE" ] || [ -z "$JS" ] || [ -z "$TMUX_BIN" ]; then
  echo; echo "skipped: the sections with the real claude (need claude, tmux, and bun or node)"
else
# The real claude, in the same throwaway home, signed in with stand-in logins.
real_login() { jq -nc --arg n "$1" --argjson e "$(in_hours 7)" '{claudeAiOauth: {accessToken: "stand-in-\($n)", refreshToken: "rt-\($n)", expiresAt: $e, scopes: ["user:inference", "user:profile"], subscriptionType: "max"}}'; }
( umask 077; real_login alice > "$H/.claude/.credentials.json"; real_login bob > "$D/park/$B/credentials.json" )
mkdir -p "$T/running"; RUNDIR=$(cd "$T/running" && pwd -P)
jq --arg w "$RUNDIR" '.hasCompletedOnboarding = true | .projects[$w].hasTrustDialogAccepted = true' "$H/.claude.json" > "$T/cj" && mv "$T/cj" "$H/.claude.json"

check "Claude Code's engine accepts the mod (claude plugin validate)" sh -c "cd '$T' && env -i HOME='$H' PATH='$REAL_PATH' '$REAL_CLAUDE' plugin validate '$REPO/mod' | grep -q 'Validation passed'"

section "a claude already running follows a move (real claude, stand-in API)"
# What T3 Code, a proxy and the like rely on: they run the real claude on this login and do
# nothing at a switch. If a Claude Code update stops a running claude reading the login again,
# this fails.
"$JS" "$SRC/tests/fakes/api-answers.ts" "$T/answers.log" > "$T/answers.port" 2>/dev/null & ANSWERS=$!
wait_for "[ -s '$T/answers.port' ]" 10
RUNTMUX="cdas-linux-$$"
"$TMUX_BIN" -L "$RUNTMUX" new-session -d -x 110 -y 30 -c "$RUNDIR" "env -i HOME='$H' USER='$USER' PATH='$REAL_PATH' TERM=xterm-256color LANG=en_US.UTF-8 ANTHROPIC_BASE_URL=http://127.0.0.1:$(cat "$T/answers.port") CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 '$REAL_CLAUDE' --model haiku"
say_running() { "$TMUX_BIN" -L "$RUNTMUX" send-keys -t 0 -l "$1"; sleep 1; "$TMUX_BIN" -L "$RUNTMUX" send-keys -t 0 Enter; }
sleep 8; say_running one
check "the running claude is on alice" wait_for "[ \"\$(tail -1 '$T/answers.log' 2>/dev/null)\" = stand-in-alice ]" 40
sleep 3
check "the relay moves terminal claude to bob" relay use bob
say_running two
check "its next message goes out as bob, with no restart" wait_for "[ \"\$(wc -l < '$T/answers.log' | tr -d ' ')\" -ge 2 ] && [ \"\$(tail -1 '$T/answers.log')\" = stand-in-bob ]" 40
"$TMUX_BIN" -L "$RUNTMUX" kill-server 2>/dev/null; RUNTMUX=""; kill "$ANSWERS" 2>/dev/null; wait "$ANSWERS" 2>/dev/null
relay use alice >/dev/null; state_reset

section "a real Claude Code session hits a usage limit (against a stand-in API)"
# The real claude with the mod, on alice's stand-in login. tests/fakes/api.ts refuses every
# request as a used-up 5-hour window, so its turn ends on the limit; the mod and the relay take
# it from there, and move terminal claude to bob.
"$JS" "$SRC/tests/fakes/api.ts" "$T/api.log" > "$T/api.port" 2>/dev/null & API=$!
wait_for "[ -s '$T/api.port' ]" 10
set_usage alice 100 40; mark
(cd "$RUNDIR" && env -i HOME="$H" USER="$USER" PATH="$REAL_PATH" LANG=en_US.UTF-8 ACCOUNT_SWITCHER_FAST=1 \
  ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$T/api.port")" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  "$REAL_CLAUDE" -p "hi" --model haiku --plugin-dir "$REPO/mod" --settings '{"enabledPlugins":{"desktop-account-switcher@desktop-account-switcher-local":false}}' --output-format json > "$T/live.json" 2>&1)
kill "$API" 2>/dev/null; wait "$API" 2>/dev/null
check "the session's request was refused as a usage limit" grep -q "POST /v1/messages" "$T/api.log"
check "the mod moved terminal claude to bob" wait_for "[ \"\$(jq -r .oauthAccount.accountUuid '$H/.claude.json')\" = $B ] && [ \"\$(jq -r .claudeAiOauth.accessToken '$H/.claude/.credentials.json')\" = stand-in-bob ]" 30
check "it's logged" logged "terminal: alice -> bob"
# A `claude -p` exits as its turn ends, often before the mod can read the session's windows;
# the cooldown then runs to the reset in Anthropic's reading (2 hours out here), else to the
# one the session reported (3 hours out, from the stand-in API).
check "alice cools down until her 5-hour reset" jq -e --arg a "$A" --argjson now "$(date -u +%s)" '((.cooldowns[$a] | fromdateiso8601) - $now) as $s | ($s - 2*3600 | fabs < 300) or ($s - 3*3600 | fabs < 300)' "$D/state.json"

section "a long-lived session carries on after the limit (as T3 Code or another SDK host runs claude)"
# One session, two messages 25 seconds apart, on alice, who is out; bob isn't
# (tests/fakes/api-by-login.ts). The first message fails on the limit, the mod moves the login,
# and the second goes out as bob in the same session.
relay use alice >/dev/null; state_reset; set_usage alice 100 40; set_usage bob 5 10
( umask 077; real_login alice > "$H/.claude/.credentials.json"; real_login bob > "$D/park/$B/credentials.json" )
echo "stand-in-alice" > "$T/out-token"
"$JS" "$SRC/tests/fakes/api-by-login.ts" "$T/held.log" "$T/out-token" > "$T/held.port" 2>/dev/null & API=$!
wait_for "[ -s '$T/held.port' ]" 10
msg() { jq -cn --arg t "$1" '{type: "user", message: {role: "user", content: $t}}'; }
{ msg "first"; sleep 25; msg "second"; sleep 15; } | (cd "$RUNDIR" && env -i HOME="$H" USER="$USER" PATH="$REAL_PATH" LANG=en_US.UTF-8 ACCOUNT_SWITCHER_FAST=1 \
  ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$T/held.port")" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  "$REAL_CLAUDE" -p --model haiku --plugin-dir "$REPO/mod" --input-format stream-json --output-format stream-json --verbose \
  --settings '{"enabledPlugins":{"desktop-account-switcher@desktop-account-switcher-local":false}}' > "$T/held.jsonl" 2> "$T/held.err")
kill "$API" 2>/dev/null; wait "$API" 2>/dev/null
check "the first message was refused on alice" test "$(sed -n 1p "$T/held.log")" = "stand-in-alice refused"
check "the session reported the limit" sh -c "jq -s -e '[.[] | select(.type == \"result\")][0].is_error == true' '$T/held.jsonl'"
check "the mod moved terminal claude to bob" test "$(jq -r .claudeAiOauth.accessToken "$H/.claude/.credentials.json")" = stand-in-bob
check "the second message went out as bob, and was answered" test "$(tail -1 "$T/held.log")" = "stand-in-bob answered"
check "in the same session, with no restart" sh -c "jq -s -e '[.[] | select(.type == \"result\")] | length == 2 and .[1].is_error == false and (map(.session_id) | unique | length == 1)' '$T/held.jsonl'"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || { echo "relay.log:"; tail -30 "$D/relay.log"; }
[ "$failed" -eq 0 ]
