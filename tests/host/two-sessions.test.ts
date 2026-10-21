// Two sessions on the same account, every interleaving of their events, in Claude Code's own
// engine (tests/e2e.sh runs it with the other tests in tests/host). Each session can get a
// prompt (P1, P2), its turn's end (C1, C2), a start on a reopen (R1, R2) and a usage limit (L1,
// L2); and 16 minutes can pass (W). sequences.test.ts covers one session's other events (the
// session's end, startup, compact), which act as these do. Every sequence of up to 4 events
// runs, and then, from one sequence reaching each state of the model first reached later, every
// event again, until every state reached has had every event. After every event the files and
// what each session was told are held to the model below; a last test checks that each state
// always left the same files, so sequences of any length only take steps checked here.
import { mock, test } from 'claude-code/testing'

const D = '/h/.claude/desktop-account-switcher'
const iso = (ms: number) => new Date(ms).toISOString()
const must = (ok: unknown, what: string) => {
  if (!ok) throw new Error(what)
}

function host(on: any, files: Record<string, string>, cur: { id: string }) {
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
  on('prompt.submit', ($: unknown, e: any) => (prompts.push(`${cur.id}: ${e.text}`), { text: e.text }))
  on('ui.toast', () => ({ value: undefined }))
  on('session.id', () => ({ value: cur.id }))
  on('session.identity', () => ({ value: { kind: 'oauth-token' } }))
  on('session.usage', () => ({ value: { rateLimits: [{ kind: 'five_hour', percentUsed: 100, resetsAt: iso(3 * 3600_000) }] } }))
  for (const ev of ['classic.UserPromptSubmit', 'classic.StopFailure', 'classic.SessionStart']) on(ev, () => ({}))
  on('turn.complete', () => ({ text: 'done' }))
  return { runs, prompts, clock }
}

const EVENTS = ['P1', 'C1', 'R1', 'L1', 'P2', 'C2', 'R2', 'L2', 'W'] as const
type Ev = (typeof EVENTS)[number]
const who = (ev: Ev) => (ev.endsWith('2') ? 's2' : 's1')
async function fire(ev: Ev, t: any, h: { clock: any }, cur: { id: string }) {
  if (ev === 'W') return h.clock.advance(16 * 60_000) // longer than a hand-off entry counts
  const s = (cur.id = who(ev))
  const base = { session_id: s, transcript_path: '/dev/null' }
  if (ev[0] === 'P') return t.classic.UserPromptSubmit({ ...base, cwd: '/tmp', prompt: 'hi', hook_event_name: 'UserPromptSubmit' })
  if (ev[0] === 'C') return t.turn.complete({ answer: 'done', reason: 'answer', durationMs: 1, isAborted: false, turnId: `t-${s}` })
  if (ev[0] === 'R') return t.classic.SessionStart({ ...base, source: 'resume', hook_event_name: 'SessionStart' })
  return t.classic.StopFailure({ ...base, cwd: '/tmp', error: 'rate_limit', error_details: '', hook_event_name: 'StopFailure' })
}

// The model: each session mid-turn or not, and its hand-off entry: none, "swap" (s1's reopen
// after a switch by hand) or "limit", each fresh or old (written more than 15 minutes ago).
type Entry = 'none' | 'swap' | 'swap-old' | 'limit' | 'limit-old'
type S = { b1: boolean; b2: boolean; e1: Entry; e2: Entry }
const START: S = { b1: false, b2: false, e1: 'swap', e2: 'none' }
const key = (m: S) => `s1 ${m.b1 ? 'busy' : 'idle'} ${m.e1}, s2 ${m.b2 ? 'busy' : 'idle'} ${m.e2}`
const old = (e: Entry): Entry => (e === 'swap' ? 'swap-old' : e === 'limit' ? 'limit-old' : e)
function step(m: S, ev: Ev): { m: S; told?: 's1' | 's2'; launch: boolean } {
  const n = { ...m }
  let told: 's1' | 's2' | undefined
  const [b, e, ob, oe] = who(ev) === 's1' ? (['b1', 'e1', 'b2', 'e2'] as const) : (['b2', 'e2', 'b1', 'e1'] as const)
  if (ev === 'W') return { m: { ...n, e1: old(n.e1), e2: old(n.e2) }, launch: false }
  if (ev[0] === 'P') n[b] = true
  if (ev[0] === 'C') n[b] = false
  if (ev[0] === 'R') {
    n[b] = false
    if (n[e] === 'swap') (n[e] = 'none'), (told = who(ev)) // used up, with the message
    // Every entry more than 15 minutes old is dropped; a fresh limit entry waits for its switch.
    for (const k of ['e1', 'e2'] as const) if (n[k] === 'swap-old' || n[k] === 'limit-old') n[k] = 'none'
  }
  if (ev[0] === 'L') {
    n[e] = 'limit'
    if (n[ob]) n[oe] = 'limit' // the other session, mid-turn on the same account, is listed too
  }
  return { m: n, told, launch: ev[0] === 'L' }
}
const run = (seq: Ev[]) => seq.reduce((m, ev) => step(m, ev).m, START)

// Every sequence of up to 4 events; then, while some state is first reached by a longer one,
// one sequence reaching it, followed by each event.
const sequences: Ev[][] = []
const first = new Map<string, Ev[]>()
const grow = (s: Ev[], n: number): void => {
  if (s.length === n) {
    sequences.push(s)
    const k = key(run(s))
    if (!first.has(k)) first.set(k, s)
    return
  }
  EVENTS.forEach(e => grow([...s, e], n))
}
first.set(key(START), [])
for (let n = 1; n <= 4; n++) grow([], n)
let frontier = [...first.entries()].filter(([, s]) => s.length === 4).map(([, s]) => s)
while (frontier.length > 0) {
  const next: Ev[][] = []
  for (const s of frontier)
    for (const e of EVENTS) {
      const longer = [...s, e]
      sequences.push(longer)
      const k = key(run(longer))
      if (!first.has(k)) first.set(k, longer), next.push(longer)
    }
  frontier = next
}

const seen = new Map<string, { files: Set<string>; events: Set<Ev> }>()
function record(m: S, files: Record<string, string>, next?: Ev) {
  const h = JSON.parse(files[`${D}/handoff.json`] ?? '{"resume":[]}')
  const snap = JSON.stringify({
    busy: ['s1', 's2'].filter(s => `${D}/busy/${s}.json` in files),
    // A limit's entries say why ("limit hit: ..." for the session that hit it, "mid-turn ..." for
    // one listed with it); everything that reads them (the mod's message, relay.sh) treats the
    // two alike, so they're one kind here.
    resume: (h.resume as { sessionId: string; reason: string }[]).map(r => `${r.sessionId}:${/^(limit hit|mid-turn)/.test(r.reason) ? 'limit' : r.reason}`).sort(),
  })
  const s = seen.get(key(m)) ?? { files: new Set<string>(), events: new Set<Ev>() }
  s.files.add(snap)
  if (next) s.events.add(next)
  seen.set(key(m), s)
}

for (const seq of sequences) {
  test(`two sessions ${seq.join(' ')}`, async (t: any, on: any) => {
    const files: Record<string, string> = {
      [`${D}/config.json`]: '{"armed":true}',
      // Claude was closed 5 seconds before the first event; s1 listed to reopen after a switch by hand.
      [`${D}/handoff.json`]: JSON.stringify({ closedAt: iso(-5000), resume: [{ sessionId: 's1', cwd: '', reason: 'swap', account: 'acct', at: iso(-5000) }] }),
      [`${D}/busy/old.json`]: JSON.stringify({ sessionId: 'old', cwd: '/tmp', account: 'acct', busy: true, at: 0 }),
      [`${D}/busy/elsewhere.json`]: JSON.stringify({ sessionId: 'elsewhere', cwd: '/tmp', account: 'other', busy: true, v: 2, at: 0 }),
    }
    const cur = { id: 's1' }
    const h = host(on, files, cur)
    let m = START
    const told: string[] = []
    let launches = 0
    for (const [i, ev] of seq.entries()) {
      record(m, files, ev)
      const at = `after ${seq.slice(0, i + 1).join(' ')}`
      await fire(ev, t, h, cur)
      await h.clock.advance(3000)
      const r = step(m, ev)
      m = r.m
      if (r.told) told.push(r.told)
      if (r.launch) launches++
      record(m, files)
      for (const [s, busy] of [['s1', m.b1], ['s2', m.b2]] as const) {
        const marker = files[`${D}/busy/${s}.json`]
        must(busy === (marker !== undefined), `${at}: ${s}'s busy marker ${marker === undefined ? 'missing' : 'left'} (model: ${key(m)})`)
        if (marker) must(JSON.parse(marker).v === 2, `${at}: ${s}'s marker ${marker}`)
      }
      const got = h.prompts.map(p => p.slice(0, 2))
      must(JSON.stringify(got) === JSON.stringify(told), `${at}: told ${JSON.stringify(got)}, not ${JSON.stringify(told)}`)
      must(h.prompts.every(p => p.includes('switched to another account by hand')), `${at}: told ${JSON.stringify(h.prompts)}`)
      const ids = (JSON.parse(files[`${D}/handoff.json`] ?? '{"resume":[]}').resume as { sessionId: string }[]).map(r => r.sessionId)
      must(new Set(ids).size === ids.length, `${at}: listed twice: ${JSON.stringify(ids)}`)
      must(!ids.includes('old') && !ids.includes('elsewhere'), `${at}: listed a session it shouldn't: ${JSON.stringify(ids)}`)
      must(ids.includes('s1') === (m.e1 !== 'none') && ids.includes('s2') === (m.e2 !== 'none'), `${at}: listed ${JSON.stringify(ids)} (model: ${key(m)})`)
      const n = h.runs.filter(a => a.includes('launch')).length
      must(n === launches, `${at}: ${n} switches started, not ${launches}`)
    }
  })
}

// Run last: every state reached had every event, and always left the same files.
test('two sessions: every state reached, with every event, covers any length', async () => {
  must(seen.size > 0, 'no states recorded (the tests ran apart?)')
  for (const [k, s] of seen) {
    must(s.events.size === EVENTS.length, `${k} got only ${[...s.events].join(' ')}`)
    must(s.files.size === 1, `${k} left different files: ${[...s.files].join(' | ')}`)
  }
  console.log(`two sessions: ${sequences.length} sequences, ${seen.size} states`)
})
