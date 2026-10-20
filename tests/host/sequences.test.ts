// Every order of the events one session can get, in Claude Code's own engine (claude plugin
// test; tests/e2e.sh copies the mod and this file into a folder and runs it). Each sequence of
// up to 4 events, from: a prompt (P), the turn's end (C), the session's end (E), the session
// started on a reopen (R), at startup (S) or after a compact (K), and a usage limit (L). After
// every event, the files and what the session was told are held to a model of what the mod
// should have done, stated once below:
//   the session's busy marker (v2, the app's account) is there exactly while a prompt was the
//   last of P, C, E, R, S;
//   the hand-off entry it reopens for is used up by the first R or S, once, with the carry-on
//   message 2.5 seconds later; K uses up nothing;
//   L lists the session and the other one mid-turn on this account (never a marker from an
//   older mod or another account), each once, and starts the switch;
//   no session is listed twice.
// The host's services are stood in for as in mod.test.ts: files in memory, processes recorded.
import { mock, test } from 'claude-code/testing'

const D = '/h/.claude/desktop-account-switcher'
const iso = (ms: number) => new Date(ms).toISOString()
const must = (ok: unknown, what: string) => {
  if (!ok) throw new Error(what)
}

function host(on: any, files: Record<string, string>) {
  const runs: string[][] = []
  const prompts: string[] = []
  mock.env(on, { HOME: '/h', CLAUDE_CODE_ENTRYPOINT: 'claude-desktop', CLAUDE_CODE_ACCOUNT_UUID: 'acct' })
  mock.store(on)
  const clock = mock.clock(on)
  on('fs.read', ($: unknown, e: any) => {
    if (!(e.path in files)) throw new Error(`no file ${e.path}`)
    return { value: files[e.path] }
  })
  on('fs.write', ($: unknown, e: any) => ((files[e.path] = e.text), { value: undefined }))
  on('fs.list', ($: unknown, e: any) => ({
    value: Object.keys(files).filter(p => p.startsWith(`${e.path}/`)).map(p => ({ name: p.slice(e.path.length + 1), kind: 'file' })),
  }))
  on('process.run', ($: unknown, e: any) => {
    const argv: string[] = e.argv ?? e.command ?? []
    runs.push(argv)
    if (argv[0] === '/bin/rm') for (const p of argv.slice(2)) delete files[p]
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })
  on('prompt.submit', ($: unknown, e: any) => (prompts.push(e.text), { text: e.text }))
  on('ui.toast', () => ({ value: undefined }))
  on('session.id', () => ({ value: 's1' }))
  on('session.identity', () => ({ value: { kind: 'oauth-token' } }))
  on('session.usage', () => ({ value: { rateLimits: [{ kind: 'five_hour', percentUsed: 100, resetsAt: iso(3 * 3600_000) }] } }))
  for (const ev of ['classic.UserPromptSubmit', 'classic.StopFailure', 'classic.SessionStart']) on(ev, () => ({}))
  on('turn.complete', () => ({ text: 'done' }))
  on('session.end', () => ({ sessionId: 's1' }))
  return { runs, prompts, clock }
}

const EVENTS = ['P', 'C', 'E', 'R', 'S', 'K', 'L'] as const
type Ev = (typeof EVENTS)[number]
const fire: Record<Ev, (t: any) => Promise<unknown>> = {
  P: t => t.classic.UserPromptSubmit({ session_id: 's1', cwd: '/tmp', prompt: 'hi', hook_event_name: 'UserPromptSubmit', transcript_path: '/dev/null' }),
  C: t => t.turn.complete({ answer: 'done', reason: 'answer', durationMs: 1, isAborted: false, turnId: 't1' }),
  E: t => t.session.end({ sessionId: 's1', reason: 'other', resume: { id: 's1' } }),
  R: t => t.classic.SessionStart({ session_id: 's1', source: 'resume', hook_event_name: 'SessionStart', transcript_path: '/dev/null' }),
  S: t => t.classic.SessionStart({ session_id: 's1', source: 'startup', hook_event_name: 'SessionStart', transcript_path: '/dev/null' }),
  K: t => t.classic.SessionStart({ session_id: 's1', source: 'compact', hook_event_name: 'SessionStart', transcript_path: '/dev/null' }),
  L: t => t.classic.StopFailure({ session_id: 's1', cwd: '/tmp', error: 'rate_limit', error_details: '', hook_event_name: 'StopFailure', transcript_path: '/dev/null' }),
}

const sequences: Ev[][] = []
for (let n = 1; n <= 4; n++) {
  const grow = (s: Ev[]): void => void (s.length === n ? sequences.push(s) : EVENTS.forEach(e => grow([...s, e])))
  grow([])
}

for (const seq of sequences) {
  test(`events ${seq.join('')}`, async (t: any, on: any) => {
    const files: Record<string, string> = {
      [`${D}/config.json`]: '{"armed":true}',
      // Claude was closed 5 seconds before the first event, this session listed to reopen after a
      // switch by hand. (An entry written up to a second after the close still counts: relay.sh
      // stamps the close to the second.)
      [`${D}/handoff.json`]: JSON.stringify({ closedAt: iso(-5000), resume: [{ sessionId: "s1", cwd: "", reason: "swap", account: "acct", at: iso(-5000) }] }),
      [`${D}/busy/s2.json`]: JSON.stringify({ sessionId: 's2', cwd: '/tmp', account: 'acct', busy: true, v: 2, at: 0 }),
      [`${D}/busy/old.json`]: JSON.stringify({ sessionId: 'old', cwd: '/tmp', account: 'acct', busy: true, at: 0 }),
      [`${D}/busy/elsewhere.json`]: JSON.stringify({ sessionId: 'elsewhere', cwd: '/tmp', account: 'other', busy: true, v: 2, at: 0 }),
    }
    const h = host(on, files)
    // The model.
    let busy = false
    let toReopen = true // the swap entry, until an R or S uses it up
    let told = 0
    let launches = 0
    for (const [i, ev] of seq.entries()) {
      const at = `after ${seq.slice(0, i + 1).join('')}`
      await fire[ev](t)
      await h.clock.advance(3000)
      if (ev === 'P') busy = true
      if (ev === 'C' || ev === 'E' || ev === 'R' || ev === 'S') busy = false
      if ((ev === 'R' || ev === 'S') && toReopen) (toReopen = false), told++
      if (ev === 'L') (toReopen = false), launches++ // the limit's own entry replaces the swap entry
      const marker = files[`${D}/busy/s1.json`]
      must(busy === (marker !== undefined), `${at}: busy marker ${marker === undefined ? 'missing' : 'left'}`)
      if (marker) {
        const b = JSON.parse(marker)
        must(b.v === 2 && b.account === 'acct' && b.busy === true, `${at}: marker ${marker}`)
      }
      must(h.prompts.length === told, `${at}: told ${h.prompts.length} times, not ${told}`)
      must(h.prompts.every(p => p.includes('switched to another account by hand')), `${at}: told ${JSON.stringify(h.prompts)}`)
      const ids = (JSON.parse(files[`${D}/handoff.json`] ?? '{"resume":[]}').resume as { sessionId: string }[]).map(r => r.sessionId)
      must(new Set(ids).size === ids.length, `${at}: listed twice: ${JSON.stringify(ids)}`)
      must(!ids.includes('old') && !ids.includes('elsewhere'), `${at}: listed a session it shouldn't: ${JSON.stringify(ids)}`)
      must(ids.includes('s1') === (toReopen || seq.slice(0, i + 1).includes('L')), `${at}: s1 listed: ${ids.includes('s1')}`)
      must(ids.includes('s2') === seq.slice(0, i + 1).includes('L'), `${at}: s2 listed: ${ids.includes('s2')}`)
      const n = h.runs.filter(a => a.includes('launch')).length
      must(n === launches, `${at}: ${n} switches started, not ${launches}`)
    }
  })
}
