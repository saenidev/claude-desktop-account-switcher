import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Step } from '../types'

// When the account a Claude Desktop session runs on is out of usage, record the
// sessions the switch will cut off and start ~/.claude/desktop-account-switcher/relay.sh,
// which moves the app to the other account and reopens them.
// A session reopened that way gets one message telling it to carry on.
//
// /account shows a row above the prompt to switch by hand and to turn automatic
// switching on or off; the row also shows by itself while usage is above 95%.
//
// Nothing here reads a token: the account comes from the app's own
// CLAUDE_CODE_ACCOUNT_UUID, the usage from the session's rate-limit windows.

type Host = EngineInterface
type Account = { name: string; accountUuid: string }

const NEAR_FULL = 95
const BUSY_FRESH_MS = 6 * 60 * 60 * 1000
const CARRY_ON = 'Carry on from where you were cut off; if your last step may not have finished, check it before going on.'
const CONTINUE = `The Claude account this session was running on ran out of usage, so the desktop app moved to another account and reopened this session. ${CARRY_ON}`
// Hand-offs relay.sh writes when it closes Claude for something other than a usage limit.
const REOPENED: Record<string, { text: string; toast: string }> = {
  restart: { text: `The relay restarted the desktop app (same account) and reopened this session. ${CARRY_ON}`, toast: 'Claude restarted; carrying on.' },
  relaunch: { text: `The relay restarted the desktop app (same account) and reopened this session. ${CARRY_ON}`, toast: 'Claude restarted; carrying on.' },
  signin: { text: `The relay closed the desktop app for a sign-in, put the previous account back, and reopened this session. ${CARRY_ON}`, toast: 'Back on your account; carrying on.' },
  swap: { text: `The desktop app was switched to another account by hand and reopened this session. ${CARRY_ON}`, toast: 'Switched account; carrying on.' },
}

type Handoff = { resume: { sessionId: string; cwd: string; reason: string; at: string }[]; closedAt?: string }
type Busy = { sessionId: string; cwd: string; account: string; busy: boolean; at: number }

async function paths($: Host) {
  const home = (await $.env.get('HOME')) ?? ''
  const dir = `${home}/.claude/desktop-account-switcher`
  return { dir, handoff: `${dir}/handoff.json`, config: `${dir}/config.json`, busy: `${dir}/busy`, relay: `${dir}/relay.sh`, log: `${dir}/relay.log` }
}

async function readJson<T>($: Host, path: string, fallback: T): Promise<T> {
  try {
    return JSON.parse(await $.fs.read(path)) as T
  } catch {
    return fallback
  }
}

async function log($: Host, text: string) {
  const p = await paths($)
  // Local time from date(1), matching relay.sh's lines in the same log.
  await $.process.run(['/bin/sh', '-c', 'printf "%s mod: %s\\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$1" >> "$2"', 'sh', text, p.log]).catch(() => undefined)
}

// Only Code tab sessions in the desktop app run on the app's login; a terminal
// `claude` runs on the Keychain login, which the app switch does not move. A `claude -p`
// started from a Code tab session's shell inherits CLAUDE_CODE_ENTRYPOINT and the app's
// CLAUDE_CODE_ACCOUNT_UUID, but also CLAUDECODE and CLAUDE_CODE_CHILD_SESSION, which Claude
// Code sets only for the processes it starts; the app sets neither on its sessions.
async function isDesktop($: Host) {
  if ((await $.env.get('CLAUDE_CODE_ENTRYPOINT')) !== 'claude-desktop') return false
  return !(await $.env.get('CLAUDECODE')) && !(await $.env.get('CLAUDE_CODE_CHILD_SESSION'))
}

async function markBusy($: Host, sessionId: string, cwd: string, busy: boolean) {
  const p = await paths($)
  const account = (await $.env.get('CLAUDE_CODE_ACCOUNT_UUID')) ?? ''
  const entry: Busy = { sessionId, cwd, account, busy, at: await $.clock.now() }
  await $.fs.write(`${p.busy}/${sessionId}.json`, JSON.stringify(entry))
}

const isoZ = (t: string) => new Date(t).toISOString().replace(/\.\d+Z$/, 'Z')

/** The hand-off and the relay, run when the limit hits. */
async function relay($: Host, sessionId: string, cwd: string, reason: string, resetsAt: string | undefined) {
  const p = await paths($)
  const account = (await $.env.get('CLAUDE_CODE_ACCOUNT_UUID')) ?? ''
  if (account === '') return 'no account id in this session; nothing to do'
  const now = await $.clock.now()

  // This session, and every other session on the same account that is mid-turn.
  const resume = new Map<string, Handoff['resume'][number]>()
  resume.set(sessionId, { sessionId, cwd, reason, at: new Date(now).toISOString() })
  for (const f of await $.fs.list(p.busy).catch(() => [])) {
    if (f.kind !== 'file' || !f.name.endsWith('.json')) continue
    const b = await readJson<Busy | null>($, `${p.busy}/${f.name}`, null)
    if (b && b.busy && b.account === account && now - b.at < BUSY_FRESH_MS && !resume.has(b.sessionId))
      resume.set(b.sessionId, { sessionId: b.sessionId, cwd: b.cwd, reason: 'mid-turn when the account ran out', at: new Date(now).toISOString() })
  }
  const { armed } = await readJson($, p.config, { armed: false })
  if (!armed) {
    await log($, `disarmed: would switch away from ${account} (${reason}); would reopen ${resume.size} session(s)`)
    return `disarmed: would reopen ${resume.size} session(s); the app was not touched`
  }
  const handoff = await readJson<Handoff>($, p.handoff, { resume: [] })
  for (const r of handoff.resume) if (!resume.has(r.sessionId)) resume.set(r.sessionId, r)
  await $.fs.write(p.handoff, JSON.stringify({ ...handoff, resume: [...resume.values()] }, null, 2))

  const argv = ['/bin/bash', p.relay, 'launch', '--from', account, ...(resetsAt ? ['--resets-at', isoZ(resetsAt)] : [])]
  const ran = await $.process.run(argv, { timeoutMs: 15_000 })
  await log($, `launched relay away from ${account} (${reason}), exit ${ran.exitCode}`)
  if (ran.exitCode === 0) return `switching away from this account; ${resume.size} session(s) will reopen`
  await $.fs.write(p.handoff, JSON.stringify(handoff, null, 2)) // no switch coming: take the entries back
  return `relay failed to start: ${ran.stderr.trim()}`
}

// A hand-off entry counts only when Claude was closed after it was written (relay.sh
// stamps closedAt as it quits Claude) and recently: a switch, restart or sign-in reopens
// its sessions within a few minutes (a sign-in waits up to 10). Anything else is left over
// from a switch that never happened.
const HANDOFF_MAX_MS = 15 * 60 * 1000

function live(h: Handoff, entry: Handoff['resume'][number], now: number) {
  const closed = Date.parse(h.closedAt ?? '')
  return closed + 1000 >= Date.parse(entry.at) && now - closed < HANDOFF_MAX_MS
}

export const register: Register = on => {
  // A session reopened by the relay: say once that it should carry on.
  on('classic.SessionStart', async ($, e, next) => {
    const r = await next(e)
    if (!(await isDesktop($))) return r
    const p = await paths($)
    // Keep app copies on the real app's version with their icons. macOS lets only apps from
    // the same developer change a launched Anthropic-signed bundle, so this runs from here
    // (inside Claude) rather than from a launchd agent. Detached: it never delays the session.
    await $.process.run(['/bin/sh', '-c', 'nohup /bin/bash "$1" sync >/dev/null 2>&1 &', 'sh', p.relay]).catch(() => undefined)
    // Only a session coming back after Claude closed; a compact or clear starts a session too.
    if (e.source !== 'resume' && e.source !== 'startup') return r
    const handoff = await readJson<Handoff>($, p.handoff, { resume: [] })
    const now = await $.clock.now()
    const stale = handoff.resume.filter(x => !live(handoff, x, now) && now - Date.parse(x.at) >= HANDOFF_MAX_MS)
    const mine = handoff.resume.find(x => x.sessionId === e.session_id && live(handoff, x, now))
    if (mine === undefined && stale.length === 0) return r
    const keep = handoff.resume.filter(x => x !== mine && !stale.includes(x))
    await $.fs.write(p.handoff, JSON.stringify({ ...handoff, resume: keep }, null, 2))
    if (stale.length > 0) await log($, `dropped ${stale.length} stale hand-off entr${stale.length === 1 ? 'y' : 'ies'} (${stale.map(x => x.sessionId).join(', ')})`)
    if (mine === undefined) return r
    const msg = REOPENED[mine.reason] ?? { text: CONTINUE, toast: 'Reopened on another Claude account; carrying on.' }
    await log($, `reopened ${e.session_id} (${e.source}, ${mine.reason}); sending the carry-on message`)
    $.ui.toast(msg.toast, { timeoutMs: 8000 })
    $.clock.after(2500, () => void $.prompt.submit({ text: msg.text }))
    return r
  }).catch(($, e, next) => (next.called ? undefined : next(e)))

  on('classic.UserPromptSubmit', async ($, e, next) => {
    if (await isDesktop($)) await markBusy($, e.session_id, e.cwd, true).catch(() => undefined)
    return next(e)
  }).catch(($, e, next) => (next.called ? undefined : next(e)))

  on('classic.Stop', async ($, e, next) => {
    if (await isDesktop($)) await markBusy($, e.session_id, e.cwd, false).catch(() => undefined)
    return next(e)
  }).catch(($, e, next) => (next.called ? undefined : next(e)))

  // The limit: a turn that died on rate_limit while a usage window is nearly full.
  on('classic.StopFailure', async ($, e, next) => {
    const r = await next(e)
    if (e.error !== 'rate_limit') return r
    // A terminal `claude`, or a nested one started from a Code tab session (it inherits the
    // session's environment), signs in with the terminal (Keychain) login. A limit there moves
    // only the terminal login (relay.sh cli-switch), never the app. Only a limit on the token
    // the app hands its sessions says the app's account is out.
    const identity = await $.session.identity().catch(() => undefined)
    const kind = identity?.kind ?? ''
    if (kind === 'claude.ai' || !(await isDesktop($))) {
      if (kind !== 'claude.ai') return r // an API key or a cloud provider: nothing to switch
      const p = await paths($)
      const { armed } = await readJson($, p.config, { armed: false })
      const windows = (await $.session.usage().catch(() => ({ rateLimits: [] }))).rateLimits
      const resetsAt = windows.filter(w => w.percentUsed >= NEAR_FULL && w.resetsAt).map(w => isoZ(w.resetsAt as string)).sort().at(-1)
      if (!armed) {
        await log($, `terminal: rate_limit in ${e.session_id} on the terminal login; switching is off`)
        return r
      }
      const ran = await $.process.run(['/bin/bash', p.relay, 'cli-switch', ...(resetsAt ? [resetsAt] : [])]).catch(() => undefined)
      await log($, `terminal: rate_limit in ${e.session_id}; cli-switch exit ${ran?.exitCode ?? 'failed'}`)
      $.ui.toast(ran?.exitCode === 0 ? 'Terminal login moved to the other account; run the command again.' : 'Terminal login is out of usage, and no other account is ready.', { timeoutMs: 10_000 })
      return r
    }
    const { rateLimits } = await $.session.usage()
    const full = rateLimits.filter(w => w.kind !== 'spend_limit' && w.percentUsed >= NEAR_FULL)
    const saysLimit = /usage limit|weekly limit|5-hour limit|limit reached|out of (extra )?usage/i.test(e.error_details ?? '')
    if (full.length === 0 && !saysLimit) {
      await log($, `rate_limit in ${e.session_id} but no window near full (${rateLimits.map(w => `${w.kind} ${w.percentUsed}%`).join(', ') || 'no reading'}); not switching`)
      return r
    }
    const resetsAt = full.map(w => w.resetsAt).filter((t): t is string => !!t).sort().at(-1)
    const said = await relay($, e.session_id, e.cwd, `limit hit: ${full.map(w => `${w.kind} ${w.percentUsed}%`).join(', ') || 'limit message'}; login ${identity?.kind ?? 'unknown'}`, resetsAt)
    $.ui.toast(`Account switcher: ${said}`, { timeoutMs: 10_000 })
    return r
  }).catch(($, e, next) => (next.called ? undefined : next(e)))

  registerRow(on)
}

// The account row above the prompt.

const step = atom({ plugin: 'desktop-account-switcher', key: 'step' } as const, { kind: 'idle' } as Step)
// Bumped when something the row shows may have changed, so it draws again.
const redraw = atom({ plugin: 'desktop-account-switcher', key: 'redraw' } as const, 0)
const shown = atom({ plugin: 'desktop-account-switcher', key: 'shown' } as const, null as boolean | null)

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
function when(iso: string) {
  const d = new Date(iso)
  const h = d.getHours()
  return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${h % 12 || 12}${h < 12 ? 'am' : 'pm'}`
}

const WINDOW: Record<string, string> = { five_hour: '5-hour', seven_day: 'weekly' }

async function usage($: Host) {
  const { rateLimits } = await $.session.usage().catch(() => ({ rateLimits: [] }))
  return rateLimits.filter(w => w.kind in WINDOW)
}

// Each account's last usage reading, saved while it's the one in use (after caam's
// `limits --cached`): the parked account's figures are as old as its last session, so
// they're shown with their age, and a window past its reset time counts as reset.
type Snapshot = { at: number; windows: { kind: string; percentUsed: number; resetsAt?: string }[] }

async function saveSnapshot($: Host) {
  const identity = await $.session.identity().catch(() => undefined)
  if (['claude.ai', 'console', 'api-key'].includes(identity?.kind ?? '')) return // not the app's login
  const account = (await $.env.get('CLAUDE_CODE_ACCOUNT_UUID')) ?? ''
  const windows = await usage($)
  if (account === '' || windows.length === 0) return
  const p = await paths($)
  const all = await readJson<Record<string, Snapshot>>($, `${p.dir}/usage.json`, {})
  all[account] = { at: Date.now(), windows: windows.map(w => ({ kind: w.kind, percentUsed: w.percentUsed, resetsAt: w.resetsAt })) }
  await $.fs.write(`${p.dir}/usage.json`, JSON.stringify(all, null, 2) + '\n')
}

function ago(ms: number) {
  const m = Math.round(ms / 60000)
  return m < 60 ? `${m}m ago` : m < 48 * 60 ? `${Math.round(m / 60)}h ago` : `${Math.round(m / 1440)}d ago`
}

// "weekly 100% (resets Oct 23, 1am) · as of 3h ago", or "weekly reset since" once past it.
function lastKnown(s: Snapshot | undefined, now: number) {
  if (s === undefined) return 'no usage reading yet'
  const parts = s.windows
    .filter(w => w.kind in WINDOW)
    .map(w => (w.resetsAt && Date.parse(w.resetsAt) <= now ? `${WINDOW[w.kind]} reset since` : `${WINDOW[w.kind]} ${Math.round(w.percentUsed)}%`))
  return `${parts.join(' · ')} · as of ${ago(now - s.at)}`
}

const DAY = 24 * 60 * 60 * 1000
const WARN_DAYS = 7
const SHOW_DAYS = 3

// A parked sign-in's expiry (ms), from the sessionKey cookie's metadata (its value is
// encrypted and never read); null when nothing is parked for that account.
async function signinExpiry($: Host, dir: string, accountUuid: string): Promise<number | null> {
  const db = `${dir}/park/${accountUuid}/Cookies`
  const ran = await $.process
    .run(['/usr/bin/sqlite3', `file:${db}?mode=ro&immutable=1`, "select max(expires_utc)/1000000-11644473600 from cookies where name='sessionKey'"])
    .catch(() => undefined)
  const seconds = Number(ran?.stdout.trim())
  return ran?.exitCode === 0 && seconds > 0 ? seconds * 1000 : null
}

function registerRow(on: Parameters<Register>[0]) {
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    if (!(await isDesktop($))) return r
    await $.command.register({ name: 'account', description: 'Show or hide the account row: switch Claude accounts, turn auto-switch on or off' })
    return r
  })

  on('command.run', { command: 'account' }, async $ => {
    const near = (await usage($)).some(w => w.percentUsed > NEAR_FULL)
    const visible = (await read($, shown)) ?? near
    await update($, shown, () => !visible)
    await update($, step, (): Step => ({ kind: 'idle' }))
    return { text: visible ? 'Account row hidden.' : 'Account row shown above the prompt.' }
  })

  // Usage moves with every turn.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (await isDesktop($)) await saveSnapshot($).catch(() => undefined)
    await update($, redraw, n => n + 1)
    return r
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || !(await isDesktop($))) return next(e)
    await read($, redraw)
    const windows = await usage($)
    const near = windows.filter(w => w.percentUsed > NEAR_FULL)
    const p = await paths($)
    const accounts = (await readJson<{ accounts: Account[] }>($, `${p.dir}/accounts.json`, { accounts: [] })).accounts
    if (accounts.length < 2) return next(e)
    const current = (await $.env.get('CLAUDE_CODE_ACCOUNT_UUID')) ?? ''
    const now = Date.now()
    const expiry = new Map<string, number | null>()
    for (const a of accounts.filter(a => a.accountUuid !== current)) expiry.set(a.accountUuid, await signinExpiry($, p.dir, a.accountUuid))
    const expiringSoon = [...expiry.values()].some(t => t === null || t - now < SHOW_DAYS * DAY)
    if (!((await read($, shown)) ?? (near.length > 0 || expiringSoon))) return next(e)
    const cooldowns = (await readJson<{ cooldowns?: Record<string, string> }>($, `${p.dir}/state.json`, {})).cooldowns ?? {}
    const armed = (await readJson<{ armed?: boolean }>($, p.config, {})).armed === true
    const snapshots = await readJson<Record<string, Snapshot>>($, `${p.dir}/usage.json`, {})
    const me = accounts.find(a => a.accountUuid === current)
    const outUntil = (a: Account) => {
      const t = cooldowns[a.accountUuid]
      return t !== undefined && Date.parse(t) > now ? when(t) : undefined
    }
    const s = await read($, step)
    const { Box, Button, Text } = $.ui.resolve(e)

    if (s.kind === 'switching') {
      return (
        <Box>
          <Text dimColor>Switching to {s.to}. Claude closes in a few seconds and reopens this session.</Text>
        </Box>
      )
    }

    if (s.kind === 'confirm') {
      const target = accounts.find(a => a.name === s.to)
      const out = target ? outUntil(target) : undefined
      return (
        <Box gap={1}>
          <Text>
            Switch to {s.to}?{out ? ` It's out of usage until ${out}.` : ''} Claude closes and reopens this session.
          </Text>
          <Button
            key="yes"
            variant="primary"
            label={`Switch to ${s.to}`}
            onPress={async () => {
              await update($, step, (): Step => ({ kind: 'switching', to: s.to }))
              const sessionId = await $.session.id()
              const ran = await $.process.run(['/bin/bash', p.relay, 'swap-later', s.to, '--resume', sessionId]).catch(() => undefined)
              if (ran === undefined || ran.exitCode !== 0) {
                $.ui.toast(`Couldn't start the switch to ${s.to}. See ~/.claude/desktop-account-switcher/relay.log.`)
                await update($, step, (): Step => ({ kind: 'idle' }))
              }
            }}
          />
          <Button key="cancel" label="Cancel" onPress={() => update($, step, (): Step => ({ kind: 'idle' }))} />
        </Box>
      )
    }

    const used = windows.map(w => `${WINDOW[w.kind]} ${Math.round(w.percentUsed)}%`).join(' · ')
    return (
      <Box gap={1}>
        <Text weight="semibold">{me?.name ?? 'Unknown account'}</Text>
        {used ? <Text dimColor={near.length === 0}>{used}</Text> : null}
        {accounts
          .filter(a => a.accountUuid !== current)
          .map(a => {
            const out = outUntil(a)
            const exp = expiry.get(a.accountUuid) ?? null
            if (exp === null || exp <= now) {
              return (
                <Text key={`to-${a.name}`}>
                  {a.name} is signed out: run relay.sh signin-later {a.name}
                </Text>
              )
            }
            return (
              <Box gap={1}>
                <Button key={`to-${a.name}`} label={`Switch to ${a.name}`} onPress={() => update($, step, (): Step => ({ kind: 'confirm', to: a.name }))} />
                <Text dimColor>{out ? `out until ${out}` : lastKnown(snapshots[a.accountUuid], now)}</Text>
                {exp - now < WARN_DAYS * DAY ? <Text>sign-in expires {when(new Date(exp).toISOString())}</Text> : null}
              </Box>
            )
          })}
        <Button
          key="auto"
          dimColor
          label={armed ? 'Auto-switch: on' : 'Auto-switch: off'}
          onPress={async () => {
            const config = await readJson<Record<string, unknown>>($, p.config, {})
            await $.fs.write(p.config, JSON.stringify({ ...config, armed: !armed }, null, 2) + '\n')
            $.ui.toast(armed ? 'Automatic switching is off.' : 'Automatic switching is on.')
            await update($, redraw, n => n + 1)
          }}
        />
        <Button key="hide" role="dismiss" dimColor label="Hide" onPress={() => update($, shown, () => false)} />
      </Box>
    )
  })
}
