#!/bin/bash
# The mod in a real Claude Code session: `claude -p` with this repo's mod (--plugin-dir), as
# the app would start a session (CLAUDE_CODE_ENTRYPOINT=claude-desktop and the account's id),
# in a throwaway home folder so neither the installed mod nor the real data folder is touched.
# Only the Keychain (where Claude Code's own login is) and ~/.claude.json are borrowed. The
# model is real, so each run costs a few cents of the signed-in account's usage; it isn't part
# of tests/e2e.sh. What the real host shows:
#   a turn marks its session busy (seen from inside the turn), and the turn's end clears it
#   before the session ends (seen between two turns of one session);
#   a session reopened after a switch gets the carry-on message, once.
#   tests/host/live.sh        (about a minute)
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d -t cdas-live); H="$T/home"; D="$H/.claude/desktop-account-switcher"
ACCT=11111111-0000-4000-8000-000000000001
passed=0; failed=0
check() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then passed=$((passed+1)); echo "  ok  $what"; else failed=$((failed+1)); echo "  FAIL $what"; fi
}
mkdir -p "$H/Library" "$D" "$T/work"
ln -s "$HOME/Library/Keychains" "$H/Library/Keychains"; ln -s "$HOME/Library/Preferences" "$H/Library/Preferences"
cp "$HOME/.claude.json" "$H/.claude.json"
cp -R "${LIVE_MOD:-$REPO/mod}" "$T/mod"   # LIVE_MOD: another copy of the mod to run instead
echo '{"armed":true}' > "$D/config.json"; ln -s "$REPO/relay.sh" "$D/relay.sh"
# A session as the app starts one (and not as a child of this one, if run from Claude Code).
session() { (cd "$T/work" && env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION HOME="$H" CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_ACCOUNT_UUID="$ACCT" claude -p --plugin-dir "$T/mod" --allowedTools Bash "$@"); }
msg() { jq -cn --arg t "$1" '{type: "user", message: {role: "user", content: $t}}'; }

echo "one session, two turns"
# Turn 1 looks at busy/ from inside the turn, and leaves a look for 6 seconds later, after the
# turn has ended; turn 2 comes 20 seconds later.
{ msg "Run this with the Bash tool, exactly, then reply with its output and nothing else: cat $D/busy/*.json; (sleep 6; ls $D/busy > $T/between.txt) > /dev/null 2>&1 &"
  sleep 20; msg "Reply with the single word: done"; } |
  session --input-format stream-json --output-format stream-json --verbose > "$T/s1.jsonl" 2>"$T/s1.err"
SID=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$T/s1.jsonl" | head -1)
INSIDE=$(jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") | .content | if type == "array" then .[0].text else . end' "$T/s1.jsonl" | head -1)
check "the session started" test -n "$SID"
check "mid-turn, its busy marker is there, v2, on the app's account" sh -c "echo '$INSIDE' | jq -e --arg s '$SID' --arg a '$ACCT' '.sessionId == \$s and .busy == true and .v == 2 and .account == \$a'"
check "between the turns, it's gone (the turn's end cleared it)" sh -c "echo '$INSIDE' | grep -q sessionId && [ -f '$T/between.txt' ] && [ ! -s '$T/between.txt' ]"
check "the second turn ran" sh -c "jq -r 'select(.type == \"result\") | .result' '$T/s1.jsonl' | grep -qi done"
check "after the session, no marker is left" sh -c "[ -z \"\$(ls '$D/busy' 2>/dev/null)\" ]"

echo "the session reopened after a switch"
now=$(date -u +%FT%TZ)
jq -n --arg s "$SID" --arg a "$ACCT" --arg t "$now" '{closedAt: $t, resume: [{sessionId: $s, cwd: "", reason: "swap", account: $a, at: $t}]}' > "$D/handoff.json"
{ msg "Reply with the single word: back"; sleep 15; } |
  session --resume "$SID" --input-format stream-json --output-format stream-json --verbose > "$T/s2.jsonl" 2>"$T/s2.err"
check "its hand-off entry is used up" jq -e '.resume == []' "$D/handoff.json"
check "the mod logged the reopen" grep -q "reopened $SID (resume, swap)" "$D/relay.log"
# A prompt the mod submits isn't echoed on stdout; the session's transcript has it.
carried() { cat "$H"/.claude/projects/*/"$SID".jsonl | jq -r 'select(.type == "user") | .message.content | if type == "string" then . else (.[]? | .text? // empty) end' | grep -c 'switched to another account by hand'; }
check "the carry-on message reached the session, once" test "$(carried)" = 1
check "and the session answered it (a turn after the prompt's)" test "$(jq -s '[.[] | select(.type == "result")] | length' "$T/s2.jsonl")" = 2

echo
echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then echo "kept $T"; tail -5 "$T/s1.err" "$T/s2.err" "$D/relay.log" 2>/dev/null; else rm -rf "$T"; fi
[ "$failed" -eq 0 ]
