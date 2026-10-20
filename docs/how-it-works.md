# How it works

The internals behind the [README](../README.md): what moves where in a switch, what the mod does, and the files involved.

- **The app's account is its claude.ai sign-in**, the `Cookies` file in its one profile folder (`~/Library/Application Support/Claude`). Accounts not in use have their sign-ins parked in `~/.claude/desktop-account-switcher/park/<accountUuid>/`. A switch closes Claude, moves the sign-ins, and opens Claude again; the app then makes its own Code tab token for that account. The sign-ins are moved, never read. The one token the relay uses is a terminal login's access token, to ask Anthropic for that account's usage (`relay.sh usage`, after Claude Graft's usage monitor): it goes to `curl` on stdin, never on a command line, in a log or on screen. The research behind this is in [how-the-desktop-app-signs-in.md](how-the-desktop-app-signs-in.md).
- **The app's files are checked before Claude is closed.** None of these files are a public interface; an app update could move them. Before any switch or sign-in, the relay checks that `config.json` names the signed-in account (`lastKnownAccountUuid`), that `Cookies` holds a claude.ai sign-in, and that the session folders are there. If not, it doesn't close Claude, and `relay.sh doctor` says what's missing. The Claude Desktop versions checked by hand are listed in `TESTED_VERSIONS` at the top of `relay.sh`; doctor flags any other version.
- **New accounts are learnt from the app.** `relay.sh add <name>` opens Claude signed out. Whatever account other than the current one you sign in to is added as `<name>`: its `accountUuid` from the app's `config.json`, its `orgUuid` from the session folder the app makes for it (`claude-code-sessions/<account>/<org>/`). If there are several, it takes the only one no other account has.
- **One session list.** The app keeps sessions under `claude-code-sessions/<account>/<org>/` (and `local-agent-mode-sessions/…` for Cowork). Every account/org pair is a link to one shared folder, so every account sees the same sessions. Session files hold no account fields. The first time there are two accounts, the first account's folder becomes the shared one. When the app makes a real folder for an account in `accounts.json` (a new account's first sign-in), the next sign-in, switch or restart backs it up, moves its sessions into the shared folder, keeps the emptied folder as `<org>.merged-<time>`, and links it.
- **Per-account settings follow you.** A few app preferences are stored per account (keys holding the account or org id in `claude_desktop_config.json`), and Remote Control's on/off in `remote-control-state.json`. While Claude is closed for a switch, the relay copies the outgoing account's onto the incoming one.
- **Scratch paths are kept inside the app's folder.** The app files a session under Scratch only if its folder is inside its own `scratch-workspaces`, and on launch it deletes scratch folders no session names by exact path. While Claude is closed, the relay points any session using another profile folder's path back inside it.
- **The mod** (`mod/`, installed as `desktop-account-switcher@desktop-account-switcher-local`) runs in every Code tab session in the desktop app:
  - It records which sessions are mid-turn.
  - When a turn fails with `rate_limit` while a usage window is at 95% or more (or the error says a limit was reached) and auto-switch is on (with no 5-hour or weekly window that full, it asks Anthropic first whether the model's own weekly limit is; the switch then cools the account down until that limit resets), it writes a hand-off listing the sessions to reopen and starts the relay. If the relay doesn't switch after all (it can't start, no other account has usage, or the new sign-in doesn't come up), those entries are dropped.
  - In a session the relay reopened, it sends one message saying why (a usage limit, a switch by hand, a restart, a sign-in) and to carry on. It acts only when the session starts by being reopened (not on a compact or clear), only if the relay closed Claude after the entry was written (`closedAt`, stamped as it quits Claude), and only within 15 minutes; older entries are dropped.
  - It draws the `/account` row and handles `/account add <name>`.
- **The relay** (`relay.sh`) does anything that closes Claude as a one-shot launchd job, so it survives Claude quitting. A command run by hand (`use`, `add`, `signin`, `restart`) queues that job and returns; the job's plist sets `ACCOUNT_SWITCHER_JOB`, which tells the relay to do the work itself. An out-of-usage switch:
  1. Takes a lock, so only one switch runs at a time; a second trigger within 5 minutes is ignored.
  2. Puts the spent account on cooldown until its reset time (from the usage window).
  3. Reads every account's usage from Anthropic where a login allows, and picks the next account after it in `accounts.json` that isn't cooling down, has a parked sign-in, and has no window used up (5-hour or weekly, or the model limit that ran out) that hasn't reset since its last reading.
  4. Checks the app's files and quits Claude. If Claude has downloaded an update, it installs as Claude quits; the relay waits (up to 3 minutes) for it to finish, so Claude opens on the new version instead of being replaced underneath later. Then it moves the sign-ins, links any new session folders, copies per-account settings across, fixes scratch paths, and opens Claude.
  5. Waits up to 45 seconds for the new account to come up; if it doesn't, puts the previous sign-in back.
  6. Reopens each handed-off session with `claude://resume?session=<id>`.
  7. Checks the shared session list for sessions that went missing (after Claude Graft's record sweep): a session file gone with no `deleted_<id>` marker from the app was lost, not deleted. Each is logged and notified once; `relay.sh doctor` lists them.

## Files

| In this repo | What it is |
| --- | --- |
| `relay.sh` | The switcher. Linked from `~/.claude/desktop-account-switcher/relay.sh`. |
| `mod/` | The Claude Code mod (hooks + the `/account` row). Linked from `~/.claude/desktop-account-switcher/mod`, which is the `desktop-account-switcher-local` plugin marketplace. |
| `accounts.example.json` | What `~/.claude/desktop-account-switcher/accounts.json` looks like (setup and `add` write it for you). |
| `tests/` | End-to-end tests (`tests/e2e.sh`) and the stand-ins they run against. |
| `docs/` | This page, research notes on the app's sign-in, and the history of the earlier design. |

Live state, never in git, in `~/.claude/desktop-account-switcher/`:

| File | What it holds |
| --- | --- |
| `accounts.json` | Each account's `name`, `accountUuid`, `orgUuid`, and optionally `email` (shown by `status`). Order is the order accounts are tried. |
| `config.json` | `{ "armed": true }` turns automatic switching on (the row's toggle writes it). |
| `state.json` | Cooldowns (`accountUuid` → reset time), the last switches, and when usage was last read from Anthropic. |
| `usage.json` | Each account's last usage reading (`source`: `anthropic` or `session`) and when it was taken. |
| `seen-sessions.json` | The session ids in the shared list at the last check, to tell when one goes missing. |
| `park/<accountUuid>/` | The parked sign-in (`Cookies`, `Cookies-journal`) of each account not in use. |
| `handoff.json` | Sessions waiting to be reopened, and when the relay last closed Claude (`closedAt`). |
| `busy/` | Which sessions are mid-turn. |
| `relay.log` | Everything the relay and the mod did, in local time. |
| `backups/` | Copies taken before each change: session lists, preferences, session files whose paths were rewritten, removed accounts. |

## Testing

`tests/e2e.sh` runs `relay.sh` the way a person does, in a throwaway home folder. It runs against a stand-in Claude app (a process that shows in `ps` under the app's path, and "signs in" from a test Cookies file), and stand-ins for `open`, `launchctl`, the Keychain, notifications and the `claude` CLI. It covers setup, adding accounts, the shared session list, switching by hand and on a usage limit, every account out, a changed app layout, terminal logins, removing an account, and moving from the old launchd label. Nothing touches the real Claude, Keychain or launchd. `ACCOUNT_SWITCHER_APP` points the relay at the stand-in app; `ACCOUNT_SWITCHER_FAST` shortens its fixed waits.

When a new Claude Desktop version is out, try a switch by hand (`relay.sh use <name>`). If it works, add the version to `TESTED_VERSIONS`.
