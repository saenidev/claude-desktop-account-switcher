import type { EngineInterface, Register } from 'claude-code'

// When the account a Claude Desktop session runs on is out of usage, record the
// sessions the switch will cut off and start ~/.claude/account-relay/relay.sh,
// which moves the app to the next signed-in profile folder and reopens them.
// A session reopened that way gets one message telling it to carry on.
//
// Nothing here reads a token: the account comes from the app's own
// CLAUDE_CODE_ACCOUNT_UUID, the usage from the session's rate-limit windows.

type Host = EngineInterface

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

type Handoff = { resume: { sessionId: string; cwd: string; reason: string; at: string }[] }
type Busy = { sessionId: string; cwd: string; account: string; busy: boolean; at: number }

async function paths($: Host) {
  const home = (await $.env.get('HOME')) ?? ''
  const dir = `${home}/.claude/account-relay`
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
// `claude` runs on the Keychain login, which this relay does not move.
async function isDesktop($: Host) {
  return (await $.env.get('CLAUDE_CODE_ENTRYPOINT')) === 'claude-desktop'
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
  const handoff = await readJson<Handoff>($, p.handoff, { resume: [] })
  for (const r of handoff.resume) if (!resume.has(r.sessionId)) resume.set(r.sessionId, r)
  await $.fs.write(p.handoff, JSON.stringify({ resume: [...resume.values()] }, null, 2))

  const { armed } = await readJson($, p.config, { armed: false })
  if (!armed) {
    await log($, `disarmed: would switch away from ${account} (${reason}); hand-off lists ${resume.size} session(s)`)
    return `disarmed: hand-off written for ${resume.size} session(s); the app was not touched`
  }
  const argv = ['/bin/bash', p.relay, 'launch', '--from', account, ...(resetsAt ? ['--resets-at', isoZ(resetsAt)] : [])]
  const ran = await $.process.run(argv, { timeoutMs: 15_000 })
  await log($, `launched relay away from ${account} (${reason}), exit ${ran.exitCode}`)
  return ran.exitCode === 0 ? `switching away from this account; ${resume.size} session(s) will reopen` : `relay failed to start: ${ran.stderr.trim()}`
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
    const handoff = await readJson<Handoff>($, p.handoff, { resume: [] })
    const mine = handoff.resume.find(x => x.sessionId === e.session_id)
    if (mine === undefined) return r
    await $.fs.write(p.handoff, JSON.stringify({ resume: handoff.resume.filter(x => x.sessionId !== e.session_id) }, null, 2))
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
    if (e.error !== 'rate_limit' || !(await isDesktop($))) return r
    const { rateLimits } = await $.session.usage()
    const full = rateLimits.filter(w => w.kind !== 'spend_limit' && w.percentUsed >= NEAR_FULL)
    const saysLimit = /usage limit|weekly limit|5-hour limit|limit reached|out of (extra )?usage/i.test(e.error_details ?? '')
    if (full.length === 0 && !saysLimit) {
      await log($, `rate_limit in ${e.session_id} but no window near full (${rateLimits.map(w => `${w.kind} ${w.percentUsed}%`).join(', ') || 'no reading'}); not switching`)
      return r
    }
    const resetsAt = full.map(w => w.resetsAt).filter((t): t is string => !!t).sort().at(-1)
    const said = await relay($, e.session_id, e.cwd, `limit hit: ${full.map(w => `${w.kind} ${w.percentUsed}%`).join(', ') || 'limit message'}`, resetsAt)
    $.ui.toast(`Account relay: ${said}`, { timeoutMs: 10_000 })
    return r
  }).catch(($, e, next) => (next.called ? undefined : next(e)))
}
