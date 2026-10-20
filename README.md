# claude-desktop-account-switcher

Use two Claude subscriptions in Claude Desktop as if they were one. When the account you're on runs out of usage, the app switches to the other account by itself and reopens the conversation you were in. Your sessions, projects, settings and config stay exactly the same; only the subscription changes. You can also switch by hand.

macOS only. Built against Claude Desktop 3.1623 / Claude Code 2.1.30x.

## Using it

- **Automatic.** With auto-switch on, when a turn fails because a 5-hour or weekly limit is used up, Claude closes, comes back on the other account (about 15 to 30 seconds), and reopens the conversation that was cut off. That conversation gets one message telling it to carry on, so the work continues on its own. It only switches to an account that still has usage; if both are out, you get a notification and nothing changes.
- **`/account`** in any Code tab session shows or hides a row above the prompt:

  > **saenidev** · 5-hour 2% · weekly 2% · [Switch to second] out until Oct 23, 1am · [Auto-switch: on] · [Hide]

  - **Switch to …** asks first, then does the same switch as the automatic one.
  - **Auto-switch** turns automatic switching on or off.
  - The row also shows by itself when usage is above 95%, or when the parked account's sign-in has 3 days or less left.
- **The other account's usage.** The row and `relay.sh status` show the parked account's last-known usage with its age ("weekly 100% · as of 3h ago"); a window past its reset time shows as reset. The mod saves each account's figures while it's the one in use, so the parked account's are as old as its last session (after caam's `limits --cached`).
- **Keeping the parked sign-in alive.** A claude.ai sign-in was seen to last 28 days from signing in. Every day at 04:30 a launchd job (`relay.sh keepalive`, installed with `relay.sh install-keepalive`) opens Claude in the background on a throwaway profile folder holding only the parked sign-in, lets claude.ai load, quits it and parks the sign-in again; your own window is never touched. It counts as renewed only if the expiry date moved (after caam's `keepalive`). Whether claude.ai extends a sign-in this way isn't known yet: on a sign-in a few hours old it didn't. If it can't be renewed, you get a notification 3 days before it expires, and the row warns from 7 days out and shows itself from 3; sign it in again with `relay.sh signin-later <name>`. Only cookie expiry dates are read, never values.
- **Terminal `claude` follows the app.** Its login is the Keychain item `Claude Code-credentials`. Each account not in use has its terminal login parked in its own Keychain item (`account-relay-cli`, one per account), never in a file. When the app switches, the terminal switches too, if a parked terminal login exists for the new account; the outgoing login is saved first, so the parked copy is always the newest (refresh tokens rotate, and putting back an old copy can revoke the login). Values go Keychain to Keychain on stdin; they're never printed, logged or put on a command line.
- **A limit in a terminal session moves only the terminal.** A terminal `claude`, or a nested one run from a Code tab session, signs in with the terminal login. The mod tells a nested one apart by `CLAUDECODE`/`CLAUDE_CODE_CHILD_SESSION`, which Claude Code sets for the processes it starts and the app doesn't set on its sessions, so a `claude -p` from a session's shell is never counted as a Code tab session. When it hits a limit (and auto-switch is on), the mod cools that account down and moves only the terminal login (`relay.sh cli-switch`); the app is left alone.
- **Scripted runs retry:** `relay.sh run -- -p "…" [claude args]` runs `claude`, and on a usage limit moves the terminal login and runs it once more (after caam's `run`).
- **Not tested yet:** whether a terminal `claude` that's already open picks up a swapped login without restarting. New `claude` processes do.
- **Setting up the terminal logins once:** `relay.sh cli-save` (saves the current terminal login), `claude /login` as the other account, `relay.sh cli-save` again, then `relay.sh cli-use <name>` to go back. `relay.sh doctor` shows what's missing.
- **Don't use `caam activate claude …` alongside this.** caam also writes the desktop app's token cache in `~/Library/Application Support/Claude/config.json`, which fights the relay.

### What carries over in a switch

- **Everything on your Mac:** the session list, every conversation's full history, project folders, worktrees, app preferences, `~/.claude` settings, hooks, mods and MCP servers. Both accounts use one shared session list.
- **Conversations continue across accounts.** Checked on 2026-10-20: a session written on one account on Oct 18 (11 replies with thinking, 17 tool calls) was continued on the other account and answered normally.

### What doesn't

- **Usage and billing** move to the new account. The first message after a switch re-reads the whole conversation without the prompt cache (caches aren't shared between accounts), so it costs more than usual.
- **Things tied to a claude.ai account follow the account:** claude.ai connectors, Remote Control, cloud sessions, artifacts and shared links.
- **Claude restarts.** Any window or pane state that isn't saved is reset; open sessions are reopened.

## How it works

- **The app's account is its claude.ai sign-in**, the `Cookies` file in its one profile folder (`~/Library/Application Support/Claude`). The account not in use has its sign-in parked in `~/.claude/account-relay/park/<accountUuid>/`. A switch closes Claude, moves the two sign-ins, and opens Claude again; the app then makes its own Code tab token for that account. No token is ever read, copied or printed. The research behind this is in [docs/how-the-desktop-app-signs-in.md](docs/how-the-desktop-app-signs-in.md).
- **One session list.** The app keeps sessions under `claude-code-sessions/<account>/<org>/` (and `local-agent-mode-sessions/…` for Cowork). Every account/org pair is a link to one shared folder, so both accounts see the same sessions. Session files hold no account fields.
- **Per-account settings follow you.** A few app preferences are stored per account (keys holding the account or org id in `claude_desktop_config.json`). While Claude is closed for a switch, the relay copies the outgoing account's onto the incoming one.
- **Scratch paths are kept inside the app's folder.** The app files a session under Scratch only if its folder is inside its own `scratch-workspaces`, and on launch it deletes scratch folders no session names by exact path. While Claude is closed, the relay points any session still using an old profile folder's path back inside it.
- **The mod** (`mod/`, installed as `desktop-account-switcher@desktop-account-switcher-local`) runs in every Code tab session in the desktop app:
  - It records which sessions are mid-turn.
  - When a turn fails with `rate_limit` while a usage window is at 95% or more (or the error says a limit was reached) and auto-switch is on, it writes a hand-off listing the sessions to reopen and starts the relay. If the relay doesn't switch after all (it can't start, no other account has usage, or the new sign-in doesn't come up), those entries are dropped.
  - In a session the relay reopened, it sends one message saying why (a usage limit, a switch by hand, a restart, a sign-in) and to carry on. It acts only when the session starts by being reopened (not on a compact or clear), only if the relay closed Claude after the entry was written (`closedAt`, stamped as it quits Claude), and only within 15 minutes; older entries are dropped.
  - It draws the `/account` row.
- **The relay** (`relay.sh`) runs as a one-shot launchd job, so it survives Claude quitting:
  1. Takes a lock, so only one switch runs at a time; a second trigger within 5 minutes is ignored.
  2. Puts the spent account on cooldown until its reset time (from the usage window).
  3. Picks the next account that isn't cooling down and has a parked sign-in.
  4. Quits Claude, moves the sign-ins, copies per-account settings across, fixes scratch paths, and opens Claude.
  5. Waits up to 45 seconds for the new account to come up; if it doesn't, puts the previous sign-in back.
  6. Reopens each handed-off session with `claude://resume?session=<id>`.

## Files

| In this repo | What it is |
| --- | --- |
| `relay.sh` | The switcher. Linked from `~/.claude/account-relay/relay.sh`. |
| `mod/` | The Claude Code mod (hooks + the `/account` row). Linked from `~/.claude/account-relay/mod`, which is the `desktop-account-switcher-local` plugin marketplace. |
| `accounts.example.json` | Template for `~/.claude/account-relay/accounts.json`. |
| `tools/migrate-to-inplace.sh` | The one-time move from the old design (shared session list, parked sign-in, blue copy retired). |
| `docs/` | Research notes on the app's sign-in, and the history of the earlier design. |
| `dock-icon/`, `tests/matrix.sh` | From the earlier one-app-per-account design; unused now. |

Live state, never in git, in `~/.claude/account-relay/`:

| File | What it holds |
| --- | --- |
| `accounts.json` | Each account's `name`, `email`, `accountUuid`, `orgUuid`. |
| `config.json` | `{ "armed": true }` turns automatic switching on (the row's toggle writes it). |
| `state.json` | Cooldowns (`accountUuid` → reset time) and the last switches. |
| `park/<accountUuid>/` | The parked sign-in (`Cookies`, `Cookies-journal`) of each account not in use. |
| `handoff.json` | Sessions waiting to be reopened, and when the relay last closed Claude (`closedAt`). |
| `busy/` | Which sessions are mid-turn. |
| `relay.log` | Everything the relay and the mod did, in local time. |
| `backups/` | Copies taken before each change: session lists, preferences, session files whose paths were rewritten. |

## Commands

Everything day to day is in the `/account` row. The relay commands, for when you need them:

| Command | What it does |
| --- | --- |
| `relay.sh status` | Accounts, cooldowns, running windows, sessions waiting to be reopened. |
| `relay.sh plan --from <accountUuid>` | What an out-of-usage switch would do, changing nothing. |
| `relay.sh swap-later <name> [--resume <sessionId>]` | Switch to `<name>` by hand (what the row's button runs). |
| `relay.sh signin-later <name> [--resume <sessionId>]` | Sign `<name>` in again (after a sign-out): parks the current sign-in, opens Claude signed out for you to sign in, then parks the new sign-in and brings the current account back. Gives up after 10 minutes. |
| `relay.sh restart-later [--resume <sessionId>]` | Restart Claude on the same account, applying `prefs-patch.json` if present and fixing scratch paths. |
| `relay.sh resume` | Reopen sessions still waiting in the hand-off. |
| `relay.sh doctor` | Check the whole setup: links, mod installed, accounts, parked sign-ins and days left, one Claude window, shared session list, keep-alive job, no stuck lock. |
| `relay.sh history [<n>]` | The last switches, sign-ins and keep-alive results. |
| `relay.sh keepalive [<days>] [--force]` | Renew parked sign-ins with fewer than `<days>` left now (what the daily job runs). |
| `relay.sh install-keepalive` | Install the daily 04:30 keep-alive job. |
| `relay.sh cli-save` | Park the current terminal login as its account's saved copy. |
| `relay.sh cli-use <name>` | Move terminal `claude` to `<name>`'s parked login. |
| `relay.sh cli-switch [<resets-at>]` | Terminal hit a limit: cool its account down and move the terminal to the next one (what the mod runs). |
| `relay.sh run -- <claude args>` | Run `claude`, retrying once on the other account after a usage limit. |

The `-later` forms run under launchd and wait 10 seconds first, so they can be started from inside the Claude window they close.

## Setup on a new machine

1. Sign in to the first account in Claude Desktop the normal way.
2. Copy `accounts.example.json` to `~/.claude/account-relay/accounts.json` and fill in both accounts. The ids of the signed-in account are in `~/Library/Application Support/Claude/config.json` (`lastKnownAccountUuid`); the org id is the folder name under `claude-code-sessions/<accountUuid>/`.
3. Link the relay and the mod, and install the mod:
   ```bash
   ln -s "$PWD/relay.sh" ~/.claude/account-relay/relay.sh
   ln -s "$PWD/mod" ~/.claude/account-relay/mod
   claude plugin marketplace add ~/.claude/account-relay/mod
   claude plugin install desktop-account-switcher@desktop-account-switcher-local --scope user
   ```
4. Sign the second account in: `~/.claude/account-relay/relay.sh signin-later <second-name>`. Claude closes and opens signed out; sign in to the second account; the relay parks it and brings the first back.
5. Share one session list: with Claude closed, move each account/org folder's contents under `claude-code-sessions/` and `local-agent-mode-sessions/` into one folder and link the others to it (`tools/migrate-to-inplace.sh` shows how; back up first).
6. Turn on auto-switch with the row's toggle, or `echo '{ "armed": true }' > ~/.claude/account-relay/config.json`.

## Rules that keep it safe

- **One Claude window at a time.** The app has no single-instance lock; two windows on one folder share a sign-in (signing out in one signs out both) and fight over files. Open Claude from the Dock as usual; don't start a second copy.
- **Change app files only while Claude is closed.** The running app rewrites session files and preferences. That's why every change goes through a relay command that quits Claude first.
- **Signing out in the app ends that account's sign-in**, parked copy included. Use `signin-later` to sign it back in.
- **Don't run test switches** onto an account without meaning to: it restarts Claude on that account.

## Troubleshooting

- **A switch didn't happen.** Check auto-switch is on (row or `config.json`), the other account isn't on cooldown (`relay.sh status`), and has a parked sign-in (`park/<accountUuid>/Cookies`). Then read `relay.log`.
- **A session says its folder is missing.** For a scratch session, recreate the folder at the exact path in the session's `cwd`; the conversation is in `~/.claude/projects/` and is unaffected. For a worktree, `git worktree add <path> -b claude/<name> main` brings the folder back (unpushed branch tips can't be recovered).
- **Scratch sessions show up as projects.** Their paths point outside the app's folder; `relay.sh restart-later` fixes them.
- **Signed out of an account.** `relay.sh signin-later <name>`.
- **Undo a change.** Look in `~/.claude/account-relay/backups/`; each change backs up what it touched first.

## Uninstall

1. Turn auto-switch off.
2. `claude plugin uninstall desktop-account-switcher@desktop-account-switcher-local` and `claude plugin marketplace remove desktop-account-switcher-local`.
3. The parked sign-in stays in `~/.claude/account-relay/park/`; delete it to sign that account out for good.
4. The shared session list keeps working with one account. To split it again, restore `backups/20261020-before-shared-list/` with Claude closed.
