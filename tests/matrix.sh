#!/bin/bash
# End-to-end matrix: every way a Claude window gets opened, in every starting state, checked
# from outside (process table, open files, LaunchServices) against one rule: no profile folder
# ever has more than one window, and each account opens in its own app.
#
#   tests/matrix.sh start   run it under launchd (it closes every Claude window, including the
#                           one you started it from, and reopens saenidev and --resume <id> at the end)
#   tests/matrix.sh run [--resume <sessionId>]   what launchd runs
#
# Results: tests/results/<time>/results.md plus the raw evidence next to it.

set -u
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY="$HOME/.claude/account-relay/relay.sh"
REAL=/Applications/Claude.app
COPY="$HOME/.claude/account-relay/apps/Claude second.app"
OLD_BLUE="$HOME/Applications/Claude Blue.app"
SAEN="$HOME/Library/Application Support/Claude"
JEY="$HOME/Library/Application Support/Claude-second"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
LABEL=com.jun.account-relay.matrix

if [ "${1:-}" = "start" ]; then
  shift
  plist="$HOME/.claude/account-relay/$LABEL.plist"; args=""
  for a in "$HERE/matrix.sh" run "$@"; do args+="    <string>$a</string>"$'\n'; done
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
$args  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$HOME/.claude/account-relay/matrix.out</string>
  <key>StandardErrorPath</key><string>$HOME/.claude/account-relay/matrix.out</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$plist" && echo "matrix queued under launchd"
  exit 0
fi
[ "${1:-}" = "run" ] || { echo "usage: matrix.sh start|run [--resume <sessionId>]" >&2; exit 2; }
shift
SESSION=""; [ "${1:-}" = "--resume" ] && SESSION="${2:-}"

OUT="$HERE/results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
RES="$OUT/results.md"
note() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$OUT/run.log"; }
sleep 10   # let the session that started this finish its turn

# Every Claude main process (any copy of the app) as "pid|app|folder".
mains() {
  local pid args
  while read -r pid args; do
    [[ "$args" == *"--type="* ]] && continue
    [[ "$args" == */Contents/MacOS/Claude || "$args" == */Contents/MacOS/Claude\ * ]] || continue
    local app="${args%%/Contents/MacOS/Claude*}" folder="$SAEN"
    [[ "$args" == *"--user-data-dir="* ]] && folder="${args#*--user-data-dir=}"
    echo "$pid|$app|$folder"
  done < <(ps -axo pid=,args=)
}
short() { # app@folder as R/C/B/? @ S/J/?
  local app="$1" folder="$2" a="?" f="?"
  case "$app" in "$REAL") a=R ;; "$COPY") a=C ;; "$OLD_BLUE") a=B ;; esac
  case "$folder" in "$SAEN") f=S ;; "$JEY") f=J ;; esac
  printf '%s@%s' "$a" "$f"
}
summary() { mains | while IFS='|' read -r p a f; do short "$a" "$f"; echo; done | sort | tr '\n' ' ' | sed 's/ $//'; }
# Main processes whose helpers hold the folder's Cookies file open (Chromium's network
# service opens it; its parent is the window's main process).
cookie_owners() {
  local f="$1" pid owners=""
  for pid in $(lsof -t "$f/Cookies" 2>/dev/null); do
    local p="$pid"; while [ "$p" -gt 1 ]; do
      local args; args=$(ps -o args= -p "$p")
      if [[ "$args" == */Contents/MacOS/Claude || "$args" == */Contents/MacOS/Claude\ * ]]; then owners+="$p "; break; fi
      p=$(ps -o ppid= -p "$p" | tr -d ' ')
    done
  done
  echo "$owners" | tr ' ' '\n' | grep -c . | tr -d ' '
}
quit_all() {
  local pids; pids=$(mains | cut -d'|' -f1)
  [ -n "$pids" ] || return 0
  kill -TERM $pids 2>/dev/null
  local n=0; while [ -n "$(mains)" ] && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done
  pids=$(mains | cut -d'|' -f1); [ -n "$pids" ] && { note "SIGKILL $pids"; kill -KILL $pids 2>/dev/null; sleep 2; }
}
setup() {
  quit_all
  case "$1" in saen|both) open -n -a "$REAL" ;; esac
  case "$1" in jey|both) open -n -a "$COPY" --args "--user-data-dir=$JEY" ;; esac
  [ "$1" = none ] || sleep 12
}
act() {
  case "$1" in
    hand-real) open -a "$REAL" ;;                      # Dock, Spotlight and Finder go through this same LaunchServices call
    hand-copy) open -a "$COPY" ;;                      # the hidden copy, if it were ever pinned to the Dock
    # A bare link (browser sign-in callbacks route the same way). The session id is made up, so
    # the link only tests where macOS delivers it and imports nothing.
    link)      open "claude://resume?session=00000000-0000-4000-8000-000000000000" ;;
    relay-jey) bash "$RELAY" relaunch second ;;       # the relay opening second (switch uses the same launch)
  esac
}
want() { # desired windows after <state> + <entry>
  case "$1:$2" in
    none:hand-real|saen:hand-real|none:link|saen:link) echo "R@S" ;;
    jey:hand-real|both:hand-real|jey:link|both:link) echo "C@J R@S" ;;
    none:hand-copy) echo "C@S" ;;
    saen:hand-copy) echo "R@S" ;;
    jey:hand-copy|jey:relay-jey|none:relay-jey) echo "C@J" ;;
    both:hand-copy|saen:relay-jey|both:relay-jey) echo "C@J R@S" ;;
  esac
}

note "start; windows: $(summary)"
{ echo "# Window matrix, $(date '+%Y-%m-%d %H:%M')"; echo
  echo "Real app $(plutil -extract CFBundleShortVersionString raw "$REAL/Contents/Info.plist"), second copy $(plutil -extract CFBundleShortVersionString raw "$COPY/Contents/Info.plist")."
  echo "R = /Applications/Claude.app, C = hidden second copy; S = saenidev folder, J = second folder. Checked 20 s after each action (the guard runs every 15 s)."; echo
  echo "| start | entry | want | got | most windows on one folder | Cookies holders S/J | Keychain prompt | result |"
  echo "|---|---|---|---|---|---|---|---|"; } > "$RES"

log stream --style compact --predicate 'process == "lsd" OR subsystem == "com.apple.launchservices"' > "$OUT/launchservices.log" 2>&1 &
LOGPID=$!

quit_all
# Retire the re-signed blue copy: the real app now carries the blue icon.
if [ -d "$OLD_BLUE" ]; then "$LSR" -u "$OLD_BLUE"; mv "$OLD_BLUE" "$HOME/.Trash/" && note "retired $OLD_BLUE"; fi
"$LSR" -dump 2>/dev/null | awk '/^-{20,}/{if(b ~ /identifier: +com\.anthropic\.claudefordesktop\n/) print b; b=""; next}{b=b $0 "\n"}' | grep -E '^(path|version|reg date|claimed schemes):' > "$OUT/lsregister.txt"

pass=0; fail=0
for entry in hand-real hand-copy link relay-jey; do
  for state in none saen jey both; do
    setup "$state"; note "cell $state x $entry; before: $(summary)"
    act "$entry"; sleep 20
    got=$(summary); w=$(want "$state" "$entry")
    most=$(mains | cut -d'|' -f3 | sort | uniq -c | awk 'BEGIN{m=0}{if($1>m)m=$1}END{print m}')
    cs=$(cookie_owners "$SAEN"); cj=$(cookie_owners "$JEY")
    kc=no; pgrep -x SecurityAgent >/dev/null && kc=YES
    ok=pass; { [ "$got" = "$w" ] && [ "$most" -le 1 ] && [ "$cs" -le 1 ] && [ "$cj" -le 1 ] && [ $kc = no ]; } || ok=FAIL
    [ $ok = pass ] && pass=$((pass+1)) || fail=$((fail+1))
    echo "| $state | $entry | $w | ${got:-none} | $most | $cs/$cj | $kc | $ok |" >> "$RES"
    note "  got: $got (want $w) $ok"
  done
done

# Fault: an app update. The second copy falls behind, and the real app loses its custom icon.
quit_all
plutil -replace CFBundleShortVersionString -string 0.0.1 "$COPY/Contents/Info.plist"
bash "$RELAY" relaunch second; sleep 5
cv=$(plutil -extract CFBundleShortVersionString raw "$COPY/Contents/Info.plist"); rv=$(plutil -extract CFBundleShortVersionString raw "$REAL/Contents/Info.plist")
codesign --verify "$COPY" 2>/dev/null && csig=valid || csig=INVALID
[ "$cv" = "$rv" ] && [ $csig = valid ] && [ "$(summary)" = "C@J" ] && u1=pass || u1=FAIL
rm -f "$REAL/Icon"$'\r'; touch "$REAL/Contents/Info.plist"; sleep 15
[ -e "$REAL/Icon"$'\r' ] && codesign --verify "$REAL" 2>/dev/null && u2=pass || u2=FAIL
pgrep -x SecurityAgent >/dev/null && kc=YES || kc=no
{ echo; echo "## App update"; echo
  echo "- second copy behind (version set to 0.0.1), then the relay opens second: copy now $cv (real $rv), signature $csig, windows $(summary): **$u1**"
  echo "- real app loses its icon and its Info.plist changes: icon back and signature valid: **$u2**"
  echo "- Keychain prompt during the matrix: $kc"; } >> "$RES"
[ $u1 = pass ] && pass=$((pass+1)) || fail=$((fail+1)); [ $u2 = pass ] && pass=$((pass+1)) || fail=$((fail+1))

kill $LOGPID 2>/dev/null
grep -iE 'claude' "$OUT/launchservices.log" > "$OUT/launchservices-claude.log"
echo >> "$RES"; echo "**$pass passed, $fail failed.**" >> "$RES"
grep -E 'guard:|refresh:|reicon:' "$HOME/.claude/account-relay/relay.log" | tail -20 > "$OUT/relay-log-excerpt.txt"

# Back to normal: saenidev in the real app, and the session that started this reopened.
quit_all
open -a "$REAL"; sleep 15
[ -n "$SESSION" ] && open -a "$REAL" "claude://resume?session=$SESSION"
osascript -e "display notification \"$pass passed, $fail failed\" with title \"Claude window matrix\"" >/dev/null 2>&1
note "done: $pass passed, $fail failed"
