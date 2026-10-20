#!/bin/bash
# One-time move from "one profile folder per account" to switching in place (2026-10-20):
# one shared session list, second's sign-in parked for the relay, the blue copy retired.
# Ends with a live test: swap to second (out of usage) and reopen <session>; its first
# turn hits the limit and the relay should switch back to saenidev on its own.
#   tools/migrate-to-inplace.sh <sessionId>     (run under launchd: it closes every Claude window)
set -u
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SESSION="${1:-}"
DIR="$HOME/.claude/account-relay"
RELAY="$DIR/relay.sh"
D="$HOME/Library/Application Support/Claude"
J="$HOME/Library/Application Support/Claude-second"
BLUE="$HOME/Applications/Claude Blue.app"
SAEN=11111111-1111-4111-8111-111111111111 JEY=22222222-2222-4222-8222-222222222222
ORG_S=1111aaaa-1111-4111-8111-11111111aaaa ORG_J=2222bbbb-2222-4222-8222-22222222bbbb
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
STAMP=20261020
log() { printf '%s migrate: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DIR/relay.log"; }
sleep 10

# 1. Close every Claude window, whatever app or folder.
pids=$(ps -axo pid=,args= | awk '/\/Contents\/MacOS\/Claude( |$)/ && !/--type=/ {print $1}')
[ -n "$pids" ] && kill -TERM $pids
for p in $pids; do n=0; while kill -0 "$p" 2>/dev/null && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done; kill -0 "$p" 2>/dev/null && kill -KILL "$p"; done
log "closed windows: $pids"

# 2. One shared session list: everything into $JEY/$ORG_J, the other account/org folders link to it.
mkdir -p "$DIR/backups/$STAMP-before-shared-list"
for kind in claude-code-sessions local-agent-mode-sessions; do
  ditto "$D/$kind" "$DIR/backups/$STAMP-before-shared-list/$kind"
  C="$D/$kind/$JEY/$ORG_J"; mkdir -p "$C"
  for pair in "$JEY/$ORG_S" "$SAEN/$ORG_S" "$SAEN/$ORG_J"; do
    P="$D/$kind/$pair"
    if [ -d "$P" ] && [ ! -L "$P" ]; then
      for f in "$P"/* "$P"/.[!.]*; do [ -e "$f" ] && mv -n "$f" "$C/"; done
      mv "$P" "$P.merged-$STAMP"
    fi
    mkdir -p "$(dirname "$P")"; [ -L "$P" ] || ln -s "$C" "$P"
  done
  log "$kind: shared list has $(ls "$C" | wc -l | tr -d ' ') entries"
done

# 3. Park second's sign-in for the relay (moved, so its old folder holds no live copy).
mkdir -p "$DIR/park/$JEY"
for f in Cookies Cookies-journal; do [ -e "$J/$f" ] && mv "$J/$f" "$DIR/park/$JEY/$f"; done
log "parked second's sign-in"

# 4. Retire the blue copy.
"$LSR" -u "$BLUE" 2>/dev/null
mv "$BLUE" "$HOME/.Trash/Claude Blue retired $STAMP.app" 2>/dev/null && log "blue copy in the Trash" || log "blue copy could not be moved; unregistered only"

# 5. Live test: Claude on second, this session reopened there.
bash "$RELAY" swap second --resume "$SESSION"
log "test swap to second done; waiting for the limit to switch back"
