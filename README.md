# account-relay

When the Claude account the desktop app is running on runs out of usage, move the app to another signed-in account and reopen the Code tab sessions the switch cut off.

How the desktop app handles sign-in, and why it's built this way, is in [desktop-signin-map.md](desktop-signin-map.md).

## How it works

- **One profile folder per account.** Each account is signed in once, the normal way, in its own `--user-data-dir` folder (`~/Library/Application Support/Claude`, `…/Claude-<name>`). No token is ever read, copied or stored: each folder's app keeps and refreshes its own login.
- **The mod** (`mod/`, installed as `account-relay@account-relay-local`) runs in every Code tab session in the desktop app:
  - It records which sessions are mid-turn.
  - When a turn fails with `rate_limit` while a 5-hour or 7-day window is at 95% or more, it writes a hand-off and starts the relay.
  - In a session the relay reopened, it sends one "carry on" message.
- **The relay** (`relay.sh`, started as a one-shot launchd job, so it survives the app quitting):
  1. Takes a lock, so only one switch runs at a time.
  2. Puts the spent account on cooldown until its reset time.
  3. Picks the next account that isn't cooling down, and checks that its folder is signed in as that account.
  4. Quits the app and opens the target folder, unless the target is already open.
  5. Reopens each handed-off session with `claude://resume?session=<id>`.
  6. If the target won't start, goes back to the previous folder.

## Layout

| In this repo | Live location |
| --- | --- |
| `relay.sh` | `~/.claude/account-relay/relay.sh` (a link to this file) |
| `mod/` | `~/.claude/account-relay/mod` (a link to this folder), the source of the `account-relay-local` marketplace |
| `accounts.example.json` | `~/.claude/account-relay/accounts.json` (real account ids, not in git) |

These stay in `~/.claude/account-relay` and out of git: `config.json` (`{"armed": true|false}`), `state.json` (cooldowns, last switches), `handoff.json`, `busy/`, `relay.log`, `backups/`.

## Setup on a new machine

1. For each extra account, open a profile folder and sign in. Only one Claude app may be running while you sign in, or the login is handed to the wrong one:
   ```bash
   open -n -a /Applications/Claude.app --args "--user-data-dir=$HOME/Library/Application Support/Claude-second"
   ```
2. Copy `accounts.example.json` to `~/.claude/account-relay/accounts.json` and fill in each account's id. Each folder's `config.json` has it under `lastKnownAccountUuid`.
3. Link the relay and the mod, then install the mod:
   ```bash
   ln -s "$PWD/relay.sh" ~/.claude/account-relay/relay.sh
   ln -s "$PWD/mod" ~/.claude/account-relay/mod
   claude plugin marketplace add ~/.claude/account-relay/mod
   claude plugin install account-relay@account-relay-local --scope user
   ```
4. Each new profile folder starts with default app preferences, extensions and session lists. What to copy or link is in the audit section of `desktop-signin-map.md`.
5. Arm it: `echo '{ "armed": true }' > ~/.claude/account-relay/config.json`

## Each account in its own app, one window per folder

Here: **orange** (`/Applications/Claude.app`, the original) is second. **Blue** (`~/Applications/Claude Blue.app`) is saenidev.

What the app does, from its own code and from tests:

- It has no single-instance lock. Two windows can open the same profile folder and share its sign-in, so signing out in one signs out both.
- Only the `--user-data-dir` switch picks a folder (release builds delete `CLAUDE_USER_DATA_DIR`). Dock, Spotlight, Finder and `claude://` links never pass it, so any app opened by hand opens the default folder.
- Every window claims `claude://` at startup. Copies keep the same bundle id, so they don't fight over it. macOS sends links to the orange app and starts it if it isn't running.
- The "Claude Safe Storage" Keychain key trusts Anthropic's team ID, plus one fingerprint per re-signed copy.

How it's handled:

- **Blue is an untouched copy** of the orange app with a Finder custom icon (`dock-icon/seticon.swift`). It's never re-signed, so there are no Keychain prompts and it updates itself. `"app"` and `"icon"` in `accounts.json` name it.
- **`relay.sh sync`** puts a copy on the orange app's version, when it isn't running, and puts its icon back. macOS lets only Anthropic-signed processes change a launched Anthropic-signed bundle. So the mod runs sync at every session start; the launchd `sync` agent can only refresh a copy that isn't protected yet.
- **`relay.sh guard`** runs every 5 seconds from a launchd agent:
  - A window running the wrong app for its folder is closed, and the folder is reopened in its own app. Opening orange by hand ends up in blue.
  - Of two windows on one folder, the newer one is closed.
- **The relay sends links to one app** with `open -a <app> <link>`.
- **Old copies are unregistered** from LaunchServices before they go to the Trash. A trashed copy otherwise still claims `claude://`.
- **Sign-in links from the browser go to the orange app.** If you sign saenidev in, the guard then moves the window to blue; the sign-in is stored in the folder either way.

Install the agents with `relay.sh install-agents`. `tests/matrix.sh start --resume <sessionId>` runs every entry point (blue or orange opened by hand, a bare link, the relay) in every starting state (nothing open, saenidev only, second only, both). It closes all windows while it runs. The last run's results are in [tests/matrix-results-2026-10-20.md](tests/matrix-results-2026-10-20.md).

## Use

- `relay.sh status`: accounts, cooldowns, running windows, pending reopens.
- `relay.sh plan --from <accountUuid>`: what a switch would do, changing nothing.
- `relay.sh resume`: reopen held sessions, with exactly one Claude window open.
- `relay.sh relaunch-later <name> [--resume <sessionId>]`: restart that account's window in its own app (under launchd, so it can close the window it was run from), then reopen the session.
- `/account-relay` in a Code tab session: status. `/account-relay switch-now` runs the switch on demand.
- Log: `~/.claude/account-relay/relay.log`

## Undo

1. `claude plugin uninstall account-relay@account-relay-local`
2. `claude plugin marketplace remove account-relay-local`
3. Remove each extra profile folder's links back to `Claude/` (`claude-code-sessions/<id>`, `local-agent-mode-sessions/<id>`).
