# History: the one-app-per-account design (retired 2026-10-20)

Before switching in place, each account had its own profile folder and its own copy of the app. It was retired the same day because it changed too much besides the subscription: two windows, two icons, separate settings, and links landing in the wrong window. This page records what it was and what it taught, since some of the code is still in `relay.sh`.

## What it was

- **One profile folder per account.** `~/Library/Application Support/Claude` for one account, `…/Claude-second` for the other, each opened with `--user-data-dir`. Each folder had its own sign-in, settings and session list.
- **One app per account.** The original orange `/Applications/Claude.app` and a blue copy, `~/Applications/Claude Blue.app`, an untouched copy with a Finder custom icon (`dock-icon/`) so it kept updating and caused no Keychain prompts.
- **`relay.sh sync`** kept the copy on the original's version and put its icon back. macOS lets only Anthropic-signed processes change a launched Anthropic-signed bundle, so the mod ran it at session start rather than a launchd agent.
- **`relay.sh guard`**, a launchd agent every 5 seconds, closed a window running the wrong app for its folder and the newer of two windows on one folder.
- **`tests/matrix.sh`** ran every way of opening the app (either app by hand, a bare `claude://` link, the relay) from every starting state. Results: [history-matrix-results-2026-10-20.md](history-matrix-results-2026-10-20.md).

## What the app does that shaped it

- It has no single-instance lock. Two windows can open the same profile folder and share its sign-in, so signing out in one signs out both.
- Only `--user-data-dir` picks a folder (release builds delete `CLAUDE_USER_DATA_DIR`). The Dock, Spotlight, Finder and `claude://` links never pass it, so an app opened by hand opens the default folder.
- Every window claims `claude://` at startup. A bare `open claude://…` goes to `/Applications/Claude.app` and starts it if it isn't running, which opened a second window on the same folder. `open -a <app> <link>` targets one app.
- A copy moved to the Trash still claims `claude://` until it's unregistered with `lsregister -u`.
- Re-signing a copy makes the "Claude Safe Storage" Keychain key ask for a password and stops the copy updating.

## What went wrong, and what it taught

- **Two windows on one folder** (a bare link starting the original app) led to a sign-out that hit both windows.
- **Linking the second folder's scratch workspaces without rewriting the sessions' saved paths** let the app's launch sweep delete 21 scratch folders (it removes folders under its own `scratch-workspaces/<account>/<org>` that no session names by exact path). The conversations were untouched and no files had been written into those folders; the empty folders were recreated later at their exact paths. The relay now rewrites such paths while Claude is closed (`fix_scratch_paths`).
- **Live test switches onto the main account without asking each time** left Claude on an account that was out of usage. Don't run test switches without asking.

## Switching in place (what replaced it)

Moving only the `Cookies` file into the profile folder brings the app up as that account; the app then makes its own Code tab token ("Login-state transition … clearing oauth cache"). That was checked on a throwaway folder first, then live. `tools/migrate-to-inplace.sh` did the one-time move: one shared session list, the second account's sign-in parked, the blue copy unregistered and moved to the Trash.
