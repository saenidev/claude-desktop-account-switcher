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

## A different Dock icon per account

An account can open with its own copy of the app: set `"app"` on it in `accounts.json` (default `/Applications/Claude.app`). The relay opens that account with its app, and counts every listed app as a Claude window.

`dock-icon/build.sh [degrees]` builds `~/Applications/Claude Blue.app`: a copy with the icon's hue rotated (225° turns the orange blue), re-signed ad hoc. The copy doesn't auto-update, so rebuild it after each Claude update. Each rebuild changes its signature, so macOS asks once more for the "Claude Safe Storage" key. Opening the orange app by hand, with no `--user-data-dir`, still opens the default folder.

macOS sends `claude://` links to the orange app, and starts it if it isn't running, even when the window you meant runs the copy. That once opened a second window on the same folder. So the relay sends each link to one app with `open -a <app> <link>`. Sign-in links from the browser still go to the orange app: to sign a folder in, open it with the orange app, with no other Claude window running.

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
