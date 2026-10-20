# How Claude Desktop handles sign-in (Claude 2.42304.2, Claude Code 2.1.299)

Mapped 2026-10-20 from the app's own code (`app.asar` main-process bundle), the Claude Code program the app runs, the app's logs (`~/Library/Logs/Claude/main.log`), caam's Go source, and file/Keychain metadata. No secret values were read or printed; tokens were compared by SHA-256 fingerprint only.

## Where the sign-in lives

| Piece | Where | What it does |
| --- | --- | --- |
| claude.ai web login | `~/Library/Application Support/Claude/Cookies` (per profile folder) | **The app's identity.** The web page reports the account to the main process over IPC ("Account details received via IPC"). |
| Code tab token cache | `config.json` key `oauth:tokenCacheV2`, encrypted with Electron safeStorage | The app's own OAuth tokens for Code tab sessions. Loaded once per launch, kept in memory, written back on every refresh. |
| `lastKnownAccountUuid` | `config.json` | The account the cache belongs to. |
| Claude Code CLI login | Keychain item `Claude Code-credentials` (+ `~/.claude/.credentials.json`) | Used by terminal `claude` only. **Code tab sessions never use it.** |
| Code tab sessions | `claude-code-sessions/<account>/<org>/`, `local-agent-mode-sessions/<account>/…` | **Stored per account.** Another account's sessions are not listed. |

## How a Code tab session gets its token

1. The app starts each session with `CLAUDE_CODE_OAUTH_TOKEN` (an access token from its own cache) plus `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH` and `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH`.
2. When the app refreshes, it pushes the new token into the running session (`update_environment_variables`). The CLI sets `process.env` and clears its cached credential.
3. On a 401, the CLI asks the app for a token (`requestHostAuthTokenRefresh` / the SDK getOAuthToken callback) and uses whatever the app answers.

So a token set inside a session by anything other than the app gets overwritten at the app's next refresh or the next 401.

## What happens when the web login changes accounts

From `main.log`, 2026-10-20 15:45:20:

> `[account] Login-state transition (loggedOut: true → false, uuid: 22222222… → 11111111…), clearing oauth cache`

The app wipes the token cache when the web account changes, and the session list switches to the new account's folder. Restoring `config.json` alone (what caam does for the desktop) can't change the app's account: on the next launch the web login reports its own account, and the mismatched cache is cleared.

## Refresh tokens rotate

- caam's saved `main` profile (03:53 today) has refresh token fingerprint `af32a3c98f`. The live Keychain login has `3955bb4e8b`, rewritten at 07:19 UTC. A refresh issued a new refresh token.
- caam's CHANGELOG: Claude OAuth uses "rotating refresh-token families (replaying a stale copy can revoke the whole family".
- Consequence: never restore an old copy of a login that has been used since it was saved. The old copy was deliberately **not** tried, since that could revoke the live login.

## Claude Graft

It launches the same Claude app with `--user-data-dir=~/Library/Application Support/Claude-<n>`. Each folder has its own cookies, token cache and session lists, so each account stays signed in independently and refreshes its own tokens. `Claude-2` exists here but has no account signed in.

## State on 2026-10-20 17:05

- Desktop app (`Claude/`): first@example.com (`11111111…`), the only running instance.
- second@example.com (`22222222…`): signed out of the app at 15:45. Still the CLI Keychain login and caam's `main` profile.
- caam profile `main` includes `~/.claude.json` and `~/.claude/settings.json` (hooks, MCP setup), which caam would swap on `activate`.

## Second profile folder audit (2026-10-20, 19:30)

Every top-level entry of `Claude/` was compared with `Claude-second/`.

| Item | Handling | Why |
| --- | --- | --- |
| Code tab and Cowork session lists (`claude-code-sessions/22222222…`, `local-agent-mode-sessions/22222222…`) | **Linked** to `Claude/` | One list per account; only the second window writes it. Backup: `~/.claude/account-relay/backups/2026-10-20-before-link/` |
| App preferences (`claude_desktop_config.json`: bypass permissions, trusted folders, preview origins, remote control; `ccd-session-presets.json`) | **Copied** | Not secrets. Previous second copies backed up in `backups/2026-10-20-second-prefs-before-copy/` |
| Theme (`darkMode`, `scale`, `userThemeMode` in `config.json`) | **Merged** in | The rest of `config.json` is that folder's own login and stays separate |
| Desktop extensions (Filesystem, iMessage) and their settings | **Copied** | |
| In-app browser sign-ins (`Partitions`) | **Copied** | Same Mac, same safeStorage key |
| Login (`Cookies`, `oauth:tokenCacheV2`) | Separate | That's what makes it a different account |
| Worktree list (`git-worktrees.json`) | Separate, on purpose | Two windows managing the same worktrees could fight. Effect: archiving a second session made in a worktree before today leaves its worktree on disk instead of removing it |
| Scratch "No folder" workspaces | **Linked** (`Claude-second/scratch-workspaces` → `Claude/scratch-workspaces`) | The 23 second scratch sessions point at `Claude/scratch-workspaces/`; without the link the second window listed each as its own project instead of "No folder" |
| Cowork VM (`vm_bundles`, 10 GB; `claude-code-vm`) | Not copied | The app downloads it again the first time Cowork runs in that window |
| Web page state (`Local Storage`, `IndexedDB`, `Session Storage`) | Not copied | Holds claude.ai page state tied to the signed-in account. Some UI state (possibly sidebar filters) may live here and need setting once in that window |
| Caches, GPU caches, crash reports, usage-history charts | Not copied | Rebuilt by the app |

The worktree clean-up was checked because the second window started with an empty worktree list: in every log since 2026-09-20, `untracked-dir GC` has removed 0 folders, and it keeps folders it didn't make ("kept … (not-ours)"). Five worktrees in the main list are missing, together with their `claude/…` branches. They were last logged on 2026-10-03/04 and were removed outside the app.

Copies don't sync: a preference or extension added in one window later has to be added in the other too.
