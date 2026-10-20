# claude-desktop-account-switcher

Use two or more Claude subscriptions in Claude Desktop as if they were one. When the account you're on runs out of usage, the app switches to the next account with usage left by itself and reopens the conversation you were in. Your sessions, projects, settings and config stay exactly the same; only the subscription changes. You can also switch by hand.

macOS only. Built against Claude Desktop 3.1623 / Claude Code 2.1.30x.

## Before you install

- **It works on the app's private files.** Claude Desktop doesn't offer account switching. This moves the app's sign-in file between folders while the app is closed and links its session folders together. None of that is a public interface, so an app update can break it. Before every switch it checks the files are still where it expects and refuses to switch if not (`relay.sh doctor` says why). Expect to wait for a fix after some updates.
- **Read Anthropic's terms for your accounts.** The [consumer terms](https://www.anthropic.com/legal/consumer-terms) forbid sharing your login with other people, getting around Anthropic's systems or protections, and accessing the services by automated means without permission. Holding several accounts of your own isn't addressed. Using this to stretch usage limits, and the daily keep-alive opening Claude in the background, could be read against those terms. Use it only with accounts that are yours, and decide for yourself whether the risk to them is acceptable.
- **It never shows or stores a token.** Sign-ins are moved, never read. Terminal logins go Keychain to Keychain without being printed or logged. The one token it uses is a terminal login's access token, to ask Anthropic for that account's usage; it goes to `curl` on stdin, never on a command line, in a log or on screen.

## Install

You need Claude Desktop in `/Applications`, signed in; the `claude` CLI; and `jq` (`brew install jq`).

```bash
git clone https://github.com/saenidev/claude-desktop-account-switcher.git
cd claude-desktop-account-switcher
./relay.sh setup <name>
```

`<name>` is a short name for the account Claude is signed in to now (say `work`). Setup links the switcher into `~/.claude/desktop-account-switcher/`, records that account, installs the Claude Code mod, turns automatic switching on, and installs a daily job that keeps parked sign-ins alive. Run it again any time; it only adds what's missing.

Then add your other account, from a Code tab session:

```
/account add <name>
```

or from a terminal, `~/.claude/desktop-account-switcher/relay.sh add <name>`. Claude closes and opens signed out. Sign in to the other account and wait for the Code tab to load. Within half a minute Claude closes again and comes back on your first account. The new account is recorded with the ids the app reports, its sign-in is parked, and both accounts now share one session list (backed up first). Repeat for more accounts. The order they were added is the order they're tried.

Finally, if you use `claude` in a terminal, give each account a parked terminal login so it follows the app (below), and check everything with `relay.sh doctor`.

## Using it

- **Automatic.** With auto-switch on, when a turn fails because a 5-hour, weekly or model limit (such as Fable weekly) is used up, Claude closes, comes back on the next account (about 15 to 30 seconds), and reopens the conversation that was cut off. That conversation gets one message telling it to carry on, so the work continues on its own. It only switches to an account that still has usage; if every account is out, you get a notification and nothing changes.
- **`/account`** in any Code tab session shows or hides a row above the prompt:

  > **work** · 5-hour 2% · weekly 2% · [Switch to personal] out until Oct 23, 1am · [Auto-switch: on] · [Hide]

  - **Switch to …** asks first, then does the same switch as the automatic one.
  - **Sign in …** shows instead for an account whose sign-in ran out; it opens Claude signed out for you to sign it in again.
  - **Auto-switch** turns automatic switching on or off.
  - The row also shows by itself when usage is above 95%, or when a parked sign-in has 3 days or less left.
- **Usage, live where it can be.** Every 10 minutes at most (after a turn, or `relay.sh usage`), the relay asks Anthropic (`api/oauth/usage`) for each account's usage with that account's terminal login: the live one, or its parked copy. That reading has windows the app's sessions don't report, such as a model's own weekly limit ("Fable weekly 0%"), which the row and `relay.sh status` show next to 5-hour and weekly. A parked login's access token lasts some hours; once it has expired the relay doesn't renew it (renewing rotates the refresh token, and the parked copy is the only one), so that account shows its last-known usage with its age ("weekly 100% · as of 3h ago"), saved by the mod while it was the one in use. A window past its reset time shows as reset. If Anthropic rate-limits these checks, the relay waits 15 minutes and the last figures stay. `relay.sh doctor` says which accounts are read live. An automatic switch skips any account whose last reading shows a window used up that hasn't reset.
- **Claude updates install during a switch.** Claude installs a downloaded update when it quits. When the relay closes Claude and an update is waiting, it lets the update finish (up to 3 minutes) before opening Claude again, so Claude opens on the new version.
- **Lost sessions are reported.** After each switch, sign-in or restart, the relay checks the shared session list for sessions that disappeared without being deleted in the app, and notifies you; `relay.sh doctor` lists them (copies may be in `backups/`).
- **Keeping parked sign-ins alive.** A claude.ai sign-in was seen to last 28 days from signing in. Every day at 04:30 a launchd job (`relay.sh keepalive`) opens Claude in the background on a throwaway profile folder holding only a parked sign-in, lets claude.ai load, quits it and parks the sign-in again; your own window is never touched. It counts as renewed only if the expiry date moved. Whether claude.ai extends a sign-in this way isn't known yet. If it can't be renewed, you get a notification 3 days before it expires, and the row warns from 7 days out and shows itself from 3; sign it in again with the row's Sign in button or `relay.sh signin <name>`. Only cookie expiry dates are read, never values.
- **Terminal `claude` follows the app.** Its login is the Keychain item `Claude Code-credentials`. Each account not in use has its terminal login parked in its own Keychain item (`desktop-account-switcher-cli`, one per account), never in a file. When the app switches, the terminal switches too, if a parked terminal login exists for the new account; the outgoing login is saved first, so the parked copy is always the newest (refresh tokens rotate, and putting back an old copy can revoke the login). To set it up once: `relay.sh cli-save` (saves the current terminal login), `claude /login` as the other account, `relay.sh cli-save` again, then `relay.sh cli-use <name>` to go back.
- **A limit in a terminal session moves only the terminal.** A terminal `claude`, or one run from a Code tab session's shell, signs in with the terminal login. When it hits a limit (and auto-switch is on), the mod cools that account down and moves only the terminal login; the app is left alone. New `claude` processes pick up the swapped login; whether one that's already open does isn't tested yet.
- **Scripted runs retry:** `relay.sh run -- -p "…" [claude args]` runs `claude`, and on a usage limit moves the terminal login and runs it once more.
- **Don't use another account switcher alongside this** (such as `caam activate claude …`): two tools writing the app's sign-in files fight each other.

### What carries over in a switch

- **Everything on your Mac:** the session list, every conversation's full history, project folders, worktrees, app preferences, `~/.claude` settings, hooks, mods and MCP servers. All accounts use one shared session list.
- **Conversations continue across accounts.** A session written on one account was continued on another and answered normally (checked 2026-10-20, 11 replies with thinking and 17 tool calls).

### What doesn't

- **Usage and billing** move to the new account. The first message after a switch re-reads the whole conversation without the prompt cache (caches aren't shared between accounts), so it costs more than usual.
- **Things tied to a claude.ai account follow the account:** claude.ai connectors, cloud sessions, artifacts and shared links. Remote Control's on/off carries over; its environments don't.
- **Claude restarts.** Any window or pane state that isn't saved is reset; open sessions are reopened.

## Commands

Day to day, everything is in the `/account` row. `~/.claude/desktop-account-switcher/relay.sh help` lists the commands; the main ones:

| Command | What it does |
| --- | --- |
| `setup <name>` | First run on a Mac, from the cloned repo. Safe to run again. |
| `add <name>` | Sign in another account and add it. |
| `signin <name>` | Sign an account in again after its sign-in ran out. Gives up after 10 minutes. |
| `use <name>` | Switch Claude to `<name>` now. |
| `remove <name>` | Take an account out. Its parked sign-in is kept in `backups/` until you delete it. |
| `status` | Accounts, usage, cooldowns, sessions waiting to be reopened. |
| `usage [--force]` | Every account's usage from Anthropic (asks at most every 10 minutes unless `--force`), and whether each is read live. |
| `doctor` | Check the whole setup: the app's version, files and any waiting update, links, mod, accounts, parked sign-ins and days left, one Claude window, shared session list and sessions lost from it, terminal logins, each account's usage, keep-alive job. |
| `restart` | Restart Claude on the same account, doing anything that needs it closed (linking a new session folder, a settings patch). |
| `history [<n>]` | The last switches, sign-ins and keep-alive results. |
| `cli-save`, `cli-use <name>` | Park the current terminal login; move terminal `claude` to an account's parked login. |
| `run -- <claude args>` | Run `claude`, retrying once on the next account after a usage limit. |

`add`, `signin`, `use` and `restart` close Claude, so they run as a launchd job and return at once; they work from inside Claude too. `signin`, `use` and `restart` take `--resume <sessionId>` to reopen a session afterwards. How it all works is in [docs/how-it-works.md](docs/how-it-works.md).

## Rules that keep it safe

- **One Claude window at a time.** The app has no single-instance lock; two windows on one folder share a sign-in (signing out in one signs out both) and fight over files. Open Claude from the Dock as usual; don't start a second copy.
- **Change app files only while Claude is closed.** The running app rewrites session files and preferences. That's why every change goes through a relay command that quits Claude first.
- **Signing out in the app ends that account's sign-in**, parked copy included. Use `signin` to sign it back in.
- **Don't switch onto an account without meaning to**: it restarts Claude on that account.

## Troubleshooting

- **A switch didn't happen.** Check auto-switch is on (row or `config.json`), and run `relay.sh status` and `relay.sh doctor`: the other account may be cooling down, have no parked sign-in, or the app's files may have changed. Then read `~/.claude/desktop-account-switcher/relay.log`.
- **doctor says Claude's files aren't where the switcher expects.** A Claude Desktop update probably moved them. Switching stays off until the switcher is updated for that version; your current account keeps working normally.
- **A session says its folder is missing.** For a scratch session, recreate the folder at the exact path in the session's `cwd`; the conversation is in `~/.claude/projects/` and is unaffected. For a worktree, `git worktree add <path> -b claude/<name> main` brings the folder back (unpushed branch tips can't be recovered).
- **An account sees an empty session list, or scratch sessions show up as projects.** `relay.sh restart` links the list and fixes the paths.
- **Signed out of an account.** The row's Sign in button, or `relay.sh signin <name>`.
- **Undo a change.** Look in `~/.claude/desktop-account-switcher/backups/`; each change backs up what it touched first.

## Uninstall

1. Turn auto-switch off.
2. `claude plugin uninstall desktop-account-switcher@desktop-account-switcher-local` and `claude plugin marketplace remove desktop-account-switcher-local`.
3. `launchctl bootout gui/$(id -u)/local.desktop-account-switcher.keepalive` and delete `~/Library/LaunchAgents/local.desktop-account-switcher.keepalive.plist`.
4. Parked sign-ins stay in `~/.claude/desktop-account-switcher/park/`; delete them to sign those accounts out for good.
5. The shared session list keeps working with one account. To split it again, restore the `*-shared-list` folders in `backups/` with Claude closed.

## Developing

`tests/e2e.sh` runs every flow end to end against a stand-in Claude app in a throwaway home folder (about a minute and a half; `E2E_FAILFAST=1` stops at the first failure). See [docs/how-it-works.md](docs/how-it-works.md#testing).
