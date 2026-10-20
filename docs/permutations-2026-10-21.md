# Every permutation, 2026-10-21

A pass over the switcher's logic: the states the Mac can be in, every action in each of them, and what happens. Each row says what the relay does now; **fixed** marks the ones that were wrong before this pass, with what went wrong. Every fixed row has a section in `tests/e2e.sh`, except where noted.

## The states

| What | Can be |
| --- | --- |
| Claude | running, closed |
| Claude's sign-in | the account the app reports; signed out (that account parked, or not); another account's `Cookies` while the app still reports the old one (a switch cut off half-way) |
| Each other account's parked sign-in | live; run out (its cookie expired); looks live but claude.ai no longer takes it; none |
| `switch.lock` | free; held by a live run; left by a killed run; its pid reused by a newer process; held by the keep-alive (a job of its own) |
| The relay's launchd job | not running; running (`use`, `add`, `signin`, `restart`, a limit switch) |
| Keep-alive profile | empty; holding a parked sign-in from a keep-alive that was cut off |
| `handoff.json` | entries from the mod (a limit), from the relay (`--resume`), cut off mid-turn; for this account, another one, any; before or after the last close; written by several sessions at once |
| `busy/` | sessions mid-turn on this account, another one; left over from a quit that didn't end the turn |
| Accounts | 1, 2, 3 or more; an org not learnt yet |
| Terminal login | on the app's account, another one, none; a parked login for the target, or not; the live item missing |
| Usage figures | read, unreadable, a window used up that hasn't reset |

## Out of usage (the mod's trigger, then `relay.sh switch`)

| When | Now |
| --- | --- |
| Next account has a live parked sign-in and usage | Switches, reopens the cut-off sessions. |
| Next account's parked sign-in has run out, a third is fine | Skips it, switches to the third. **Fixed:** it was tried, didn't come up, and the switch failed, so Claude stayed on the spent account. |
| Next account's sign-in looks live but doesn't come up | Goes back, then tries the next ready account. **Fixed:** the switch failed on the first. |
| Every other account cooling down, used up or signed out | Notifies, drops this limit's hand-offs, changes nothing. |
| The keep-alive holds the lock (04:30) | The job starts and waits for the lock (up to 10 minutes), then switches. **Fixed:** "a switch is already under way" was logged and nothing switched; the account stayed spent. |
| Another relay job is running | Left to that job; it reopens the sessions the mod listed (they're meant for any account). |
| Claude has already left that account (several sessions hit the limit; you switched by hand meanwhile) | Records the cooldown, does nothing else. **Fixed:** the "5 minutes" rule covered the first case only by time. It also wrongly ignored a real limit on an account you had switched back to by hand within 5 minutes. |
| Several sessions hit the limit at the same moment | Each adds its entries to `handoff.json` under its lock. **Fixed:** they read and wrote the file unlocked and could lose each other's entries, so a session wasn't reopened. (Not in the e2e tests: the mod runs only inside Claude.) |
| Usage figures unreadable | Picks without them, logs it. |
| A new account's org isn't known yet | Per-account settings are copied by account id only. **Fixed:** keys got a literal `none` for the org, and Remote Control a `:<account>` key. |

## By hand (`use`, `restart`, `signin`, `add`, `remove`)

| When | Now |
| --- | --- |
| Another job or the keep-alive is running | Turned away with "a switch or sign-in is running". |
| `remove` while a switch or sign-in runs | Turned away the same way. **Fixed:** `remove` took no lock and could move an account's parked sign-in out from under a switch to it. |
| `use` to an account whose parked sign-in ran out | Refused before Claude closes, logged with what to run. **Fixed:** Claude was closed and opened twice for nothing. |
| `use`/`restart`/`signin` while other sessions are mid-turn | Those sessions are listed as cut off, reopened afterwards, and told to carry on. **Fixed:** only the session given with `--resume` came back. The others were reopened idle (by the app), their turn lost. |
| `signin` times out, or you sign in to an account other than the one asked for | The previous account comes back whole; what the app held goes to `backups/`. **Fixed:** a `Cookies-journal` from the signed-out profile could be left beside the previous account's `Cookies`. |
| `signin`/`add` to an account that already has a parked sign-in | The new sign-in is parked; the old one goes to `backups/`. Before, it was overwritten. |
| `use` to the account Claude is on | Logs "already on", changes nothing. |
| Claude closed when the command runs | Works the same; nothing is reopened (nothing was cut off). |

## Cut off half-way (the Mac shut down, the job was killed)

| What was cut off | Now |
| --- | --- |
| A sign-in waiting for you | Puts the previous sign-in back: at once on SIGTERM, otherwise at the start of the next locked command. |
| A keep-alive | Parks the sign-in again from the throwaway profile (to `backups/` if that account is gone or has one parked). |
| A switch, between parking the old sign-in and the app loading the new one | `swap.inflight` says so. On SIGTERM it's put back at once; otherwise by the next locked command, and `doctor` reports it. If the app had come up on the new account, it's left there. **Fixed:** nothing noticed. The next switch parked the new account's `Cookies` as the old account's, overwriting the old account's only sign-in. |
| Any of these, then Claude opened from the Dock | Still put right by the next command; `doctor` says so. |

## The lock

| When | Now |
| --- | --- |
| Held by a live run, however long | Kept. **Fixed:** after 15 minutes it was taken over, and a sign-in can run longer than that (10 minutes waiting for you, plus quitting Claude twice and letting an update install). |
| Its owner was killed | Taken over. |
| Its pid now belongs to a newer process | Taken over. (Before, only by the 15-minute rule.) |
| Two runs find it left over at the same moment | One takes it over (`switch.lock.takeover`); the other is turned away. **Fixed:** both could remove it, the second removing the first's new lock, and both ran. (Not in the e2e tests: a race of milliseconds.) |

## Files changed at the same moment

| File | Now |
| --- | --- |
| `handoff.json` | Every change, by the relay or the mod, reads, changes and writes it under `handoff.json.lock`. **Fixed:** several sessions starting together after a switch could put back each other's consumed entries, and a session could then get "carry on" again after a later restart. |
| `state.json` | Under its lock. **Fixed:** the usage check started after every turn could overwrite a cooldown a switch had just written. |
| `usage.json` | Under its lock, in the relay and in the mod. |
| Terminal login | Moves one at a time (`cli.lock`). **Fixed:** a terminal limit and an app switch could move it at once. |

## Smaller ones

- **Keep-alive:** checks again under the lock that the account is still parked (a switch between its check and the lock may have taken it into Claude), forgets the throwaway profile's last account before loading (so "did it load" means something), and reports a sign-in that has already run out instead of trying to renew it ("expires in -3 days").
- **Status and plan** say when a parked sign-in has run out, instead of "parked, ready to switch to".
- **Terminal follows the app** even when the live terminal login item is missing: there's nothing to save first. Before, the swap was refused.
- **Reopening:** the relay reopens only the entries the mod will act on (written before the last close, within 15 minutes, for this account or any). Before, it sent links for every entry, including ones left from a switch that went back.
- **The e2e suite** prints each section's start time, to see where a slow run spends it.
- **The e2e test of an update installing during a switch** failed sometimes: its stand-in ShipIt slept a fixed 4 seconds. It now waits for Claude to quit, as the real one does.

## Fixed in a second pass

- **Signed out.** `use`, `add` and `signin` while Claude is signed out were refused, because the app-files check counted "no claude.ai sign-in in `Cookies`" as the app's files having moved. The check now asks only that `Cookies` is the app's cookie database. Being signed out is a state like any other: the signed-out `Cookies` is parked, counts as "not signed in" (status, the row, a limit switch never picks it), and `doctor` warns. `setup` still needs a sign-in.
- **Signing in to another account than asked.** During `signin <name>`, signing in to another account already set up was ignored, and after 10 minutes it was thrown away. Now it's kept as that account (its old parked sign-in goes to `backups/`), and you're told.
- **A limit switch turned away by a running job** recorded no cooldown, so a restart could bring Claude back on the spent account and pick it again. The cooldown is now recorded either way.

## The mod

The mod runs only inside Claude Code, so `tests/fakes/mod-host.ts` stands in for the host: one session's process running the mod's real hooks for one event. Files, `relay.sh` and the clock are real; toasts and submitted prompts go to a log. The e2e suite drives it for:
- two sessions hitting the limit at the same moment, with a third mid-turn: all three listed once, the switch, all three reopened, all three starting together and each getting its message once
- a session cut off mid-turn by a switch by hand ("moved to another Claude account") and by a restart ("closed and reopened")
- a compact not counting as a reopen, auto-switch off, a switch that can't start (its entry taken back), a rate limit with usage left, a terminal `claude` on an API key

## The mod in Claude Code's own engine

`claude plugin test` loads a mod in Claude Code's own engine, with its rules for registering hooks, the events' fields and what each hook must return; `tests/host/mod.test.ts` stands in only for the host's services (files in memory, processes recorded). The suite runs it. What it found:

- **The mod in the repo didn't load at all.** It registered `turn.complete` twice without a matcher, which the engine refuses, and with it the whole mod: no limit switch, no carry-on message, no row. This was so before this pass; the Mac kept working only because Claude Code runs a cached older copy (0.3.0). The two hooks are one now, and the stand-in host refuses the same thing.
- **The live setup mixed versions.** The relay in use is the repo's (a link), the mod the cached 0.3.0, which leaves markers in `busy/` still saying busy hours after their turn (one 277 minutes old was found). The new relay would have reopened that session with "carry on". Now only markers the new mod writes (`v: 2`) count, in the relay and the mod. The mod's version is 0.4.0, so `claude plugin update desktop-account-switcher@desktop-account-switcher-local` installs it.
- **In the engine:** a turn marks its session busy (`v: 2`) and its end clears the marker; a limit lists the session and the ones mid-turn (not an old marker) under `handoff.json.lock` and starts the switch; a reopened session is told why once, a compact doesn't count, and a session cut off mid-turn is told it was moved. (The turn's end was at first skipped by the engine. The test was at fault: it fired `turn.complete` with `answer` as an object, and the engine's types make it the turn's final text, a string.)

## Swept, not listed

Two parts of the logic have too many states to list by hand, so `tests/sweep.sh` runs each one in every state and checks the result against a rule stated once.

- **A switch cut off while it moves the sign-ins.** A real `relay.sh use bob` is cut off at each of its moves of a sign-in file (a stand-in `mv` kills its job), for every move it makes. It's cut before or after that move, by SIGKILL or SIGTERM, and after a SIGKILL Claude is either left closed or opened from the Dock. The sweep covers three kinds of switch, each with and without the journals: one that works; one whose new sign-in doesn't come up, so the moves back are cut too; and one where the app reports bob late, just as the switch has given up and starts going back. Each case must end with Claude on alice, or on bob if the app had come up on bob before any move back; the other account parked under its own name; no journal beside another account's `Cookies`; and nothing left to recover.
  **Fixed:** the earlier recovery worked out how far the move had got from where the files were. Run against the earlier `relay.sh`, the sweep passes for a switch that works and one that goes back, but the late kind fails at every cut during the moves back. The app reported bob, so recovery took the switch for one that had worked, and left the files half-way back: Claude without alice's sign-in, or bob's sign-in nowhere parked. A switch now notes each move just before making it, and `back` before going back. Recovery undoes the moves, last first, unless the app came up on bob and the switch wasn't going back. On the late kind, the earlier relay gets 510 checks passed and 98 failed, every failure at a move back (moves 5 to 8 with the journals, 3 and 4 without); the current one passes all 608. The whole sweep (works, goes back, the pick) passes on the current relay: 3504 checks. A `swap.inflight` from an earlier relay notes no moves; for it, the old reading of where the files are is kept.
  Also fixed, found reading the code and not reached by any test: two backups of the same kind made in the same second shared a folder, and the second overwrote the first one's files. Each now gets its own folder.
- **Which account a limit switch picks.** Claude is on alice, and bob and carol are each put in every state that counts. The parked sign-in is live, run out or missing. A cooldown is running, has passed, or there is none. The last usage reading is fine (99%), has a 5-hour window used up, has a weekly window used up and since reset, or has the model's own weekly limit used up. And the limit that was hit is a general one or that model's. `relay.sh plan` must name the first of them that can be picked, or nobody.

## Every order of a session's events

`tests/host/sequences.test.ts` runs in Claude Code's own engine with the suite. It covers every sequence of up to 4 of the events one session can get: a prompt, the turn's end, the session's end, a start on a reopen, at startup or after a compact, and a usage limit. That is 7 + 49 + 343 + 2401 = 2800 sequences. After every event it checks the files and what the session was told against a model stated once:
- the busy marker is there exactly while a prompt was the last thing to happen;
- the reopen entry is used up by the first start, with the carry-on message once, and never by a compact;
- a limit lists this session and the other one mid-turn on its account (never an older mod's marker or another account's), each once, and starts the switch.

All 2800 pass. Its first run failed 210 sequences, every one a limit followed by a reopen. The fixture had Claude closing at the clock's first instant, so a limit at that same instant counted as written before the close, under the one-second grace that `relay.sh` needs because it stamps the close to the second. With the close moved 5 seconds before the first event, all pass. With one bug put in by hand (a reopened session not clearing its own busy marker), 388 fail.

## The mod in a real Claude Code session

`tests/host/live.sh` runs the mod in a real `claude -p` session: the real host, the real model, started as the app starts a session (`CLAUDE_CODE_ENTRYPOINT=claude-desktop` and an account id), in a throwaway home folder, so neither the installed mod nor the real data folder is touched. It costs a few cents of usage a run, so it is run by hand, not by `tests/e2e.sh`. What it shows, 9 checks, all passing:

- a turn marks its session busy: the marker (v2, the app's account) is there when the model looks from inside the turn;
- the turn's end clears it before the session ends: a look taken between two turns of one session finds nothing;
- a session resumed with a hand-off entry for it uses the entry up, logs the reopen, and gets the carry-on message once, which the session then answers as a turn of its own.

Run on the mod as it was at a2ce8e5 (the one that didn't load), 5 of the 9 fail.

The limit itself runs on the real host too, in `tests/e2e.sh` ("a real Claude Code session hits a usage limit"). The real `claude` runs with the mod, started as the app starts a session on bob, with a dummy token. It talks to `tests/fakes/api.ts`, a stand-in for Anthropic's API, which refuses every request the way the real API refuses one on a used-up 5-hour window: a 429 with the unified rate-limit headers. No real account is used, so the suite runs it every time. The chain runs end to end: the real host ends the turn with `StopFailure` and `rate_limit`, and the mod reads the 5-hour window at 100% from the session's own usage. It lists the session and launches the relay, which switches the stand-in Claude from bob to alice and reopens the session. Bob's cooldown runs to the reset the stand-in API gave (3 hours), not the relay's 5-hour default, so the window really came from the session. In one run the mod's own log line for the launch was missing, though the launch happened. The mod writes that line after the launch returns, and `claude -p` exits as its turn ends. A session in the app stays alive, so the suite doesn't check that line.

## What the stand-ins can't show

Every event the real host fires, in every order, in a live desktop session. The live relay log shows the real host firing the two that matter, with the fields the mod reads: a limit (`StopFailure`, `rate_limit`, a weekly window at 100%, three times) and a reopen (`SessionStart` with `source: resume`, five times).

## The slow run

The run I called a 12-minute run was shorter: the session's own record has it launched at 20:48:28 UTC and done at 20:57:21, 8 minutes 53 seconds, against 5 minutes 24 seconds for the run before it. Its one failure was a check that fails at once, with no wait behind it. It had no section timings (they were added right after), so which part was slow can't be known now. In that half hour other sessions on the Mac were running test suites (pytest in three other projects, one with four subagents of its own, and sf-map workflows driving Chromium and `npm test`), which is evidence of load, not proof that it was the cause. The timed runs since took five to six minutes; the latest took 317 seconds, no section more than about 30. Every wait in the suite is bounded (each `wait_for` gives up after its time-out and counts a failure), so a run that is slow but passes means the stand-ins were slow to answer, not that something hung.
