// Every order of the events one session can get, in Claude Code's own engine (claude plugin
// test; tests/e2e.sh copies the mod and this file into a folder and runs it). Each sequence of
// up to 4 events, from: a prompt (P), the turn's end (C), the session's end (E), the session
// started on a reopen (R), at startup (S) or after a compact (K), a usage limit (L), and 16
// minutes passing (W), longer than a hand-off entry counts; between the others, 3 seconds. After
// every event, the files and what the session was told are held to a model of what the mod
// should have done, stated once below:
//   the session's busy marker (v2, the app's account) is there exactly while a prompt was the
//   last of P, C, E, R, S;
//   the hand-off entry it reopens for is used up by the first R or S, once, with the carry-on
//   message 2.5 seconds later; K uses up nothing;
//   L lists the session and the other one mid-turn on this account (never a marker from an
//   older mod or another account), each once, and starts the switch;
//   no session is listed twice;
//   entries more than 15 minutes old are never acted on, and the next start drops them.
// A last test checks that this covers sequences of any length (see it, at the end).
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

const EVENTS = ['P', 'C', 'E', 'R', 'S', 'K', 'L', 'W'] as const
type Ev = (typeof EVENTS)[number]
const fire: Record<Ev, (t: any, h: { clock: any }) => Promise<unknown>> = {
  P: t => t.classic.UserPromptSubmit({ session_id: 's1', cwd: '/tmp', prompt: 'hi', hook_event_name: 'UserPromptSubmit', transcript_path: '/dev/null' }),
  C: t => t.turn.complete({ answer: 'done', reason: 'answer', durationMs: 1, isAborted: false, turnId: 't1' }),
  E: t => t.session.end({ sessionId: 's1', reason: 'other', resume: { id: 's1' } }),
  R: t => t.classic.SessionStart({ session_id: 's1', source: 'resume', hook_event_name: 'SessionStart', transcript_path: '/dev/null' }),
  S: t => t.classic.SessionStart({ session_id: 's1', source: 'startup', hook_event_name: 'SessionStart', transcript_path: '/dev/null' }),
  K: t => t.classic.SessionStart({ session_id: 's1', source: 'compact', hook_event_name: 'SessionStart', transcript_path: '/dev/null' }),
  L: t => t.classic.StopFailure({ session_id: 's1', cwd: '/tmp', error: 'rate_limit', error_details: '', hook_event_name: 'StopFailure', transcript_path: '/dev/null' }),
  W: (t, h) => h.clock.advance(16 * 60_000), // longer than a hand-off entry counts (15 minutes)
}

const sequences: Ev[][] = []
for (let n = 1; n <= 4; n++) {
  const grow = (s: Ev[]): void => void (s.length === n ? sequences.push(s) : EVENTS.forEach(e => grow([...s, e])))
  grow([])
}

// The model's state: is the session mid-turn, and the hand-off entry of each session (s1, and
// s2, mid-turn on the same account): none, "swap" (the reopen after a switch by hand) or
// "limit", each fresh or old (written more than 15 minutes ago).
type Entry = 'none' | 'swap' | 'swap-old' | 'limit' | 'limit-old'
type State = { busy: boolean; s1: Entry; s2: Entry }
const key = (m: State) => `${m.busy ? 'busy' : 'idle'} s1:${m.s1} s2:${m.s2}`
// What each event should do to it, and whether the session is told to carry on.
function step(m: State, ev: Ev): { m: State; told: boolean; launch: boolean } {
  const n = { ...m }
  let told = false
  if (ev === 'P') n.busy = true
  if (ev === 'C' || ev === 'E' || ev === 'R' || ev === 'S') n.busy = false
  if (ev === 'R' || ev === 'S') {
    if (n.s1 === 'swap') (n.s1 = 'none'), (told = true) // used up, with the message
    // Entries more than 15 minutes old are dropped; a fresh limit entry waits for its switch.
    if (n.s1 === 'swap-old' || n.s1 === 'limit-old') n.s1 = 'none'
    if (n.s2 === 'limit-old') n.s2 = 'none'
  }
  if (ev === 'L') (n.s1 = 'limit'), (n.s2 = 'limit')
  if (ev === 'W') {
    if (n.s1 === 'swap') n.s1 = 'swap-old'
    if (n.s1 === 'limit') n.s1 = 'limit-old'
    if (n.s2 === 'limit') n.s2 = 'limit-old'
  }
  return { m: n, told, launch: ev === 'L' }
}
// What the files say, without times: if every sequence that reaches a state of the model leaves
// the same files, the mod's next step depends only on that state (it keeps nothing else between
// events), so the states and events checked here cover sequences of any length.
const seen = new Map<string, { files: Set<string>; depth: number; events: Set<Ev> }>()
function record(m: State, depth: number, files: Record<string, string>, next?: Ev) {
  const h = JSON.parse(files[`${D}/handoff.json`] ?? '{"resume":[]}')
  const snap = JSON.stringify({
    busy: `${D}/busy/s1.json` in files,
    resume: (h.resume as { sessionId: string; reason: string }[]).map(r => `${r.sessionId}:${r.reason}`).sort(),
  })
  const s = seen.get(key(m)) ?? { files: new Set<string>(), depth, events: new Set<Ev>() }
  s.files.add(snap)
  s.depth = Math.min(s.depth, depth)
  if (next) s.events.add(next)
  seen.set(key(m), s)
}

for (const seq of sequences) {
  test(`events ${seq.join('')}`, async (t: any, on: any) => {
    const files: Record<string, string> = {
      [`${D}/config.json`]: '{"armed":true}',
      // Claude was closed 5 seconds before the first event, this session listed to reopen after a
      // switch by hand. (An entry written up to a second after the close still counts: relay.sh
      // stamps the close to the second.)
      [`${D}/handoff.json`]: JSON.stringify({ closedAt: iso(-5000), resume: [{ sessionId: 's1', cwd: '', reason: 'swap', account: 'acct', at: iso(-5000) }] }),
      [`${D}/busy/s2.json`]: JSON.stringify({ sessionId: 's2', cwd: '/tmp', account: 'acct', busy: true, v: 2, at: 0 }),
      [`${D}/busy/old.json`]: JSON.stringify({ sessionId: 'old', cwd: '/tmp', account: 'acct', busy: true, at: 0 }),
      [`${D}/busy/elsewhere.json`]: JSON.stringify({ sessionId: 'elsewhere', cwd: '/tmp', account: 'other', busy: true, v: 2, at: 0 }),
    }
    const h = host(on, files)
    let m: State = { busy: false, s1: 'swap', s2: 'none' }
    let told = 0
    let launches = 0
    for (const [i, ev] of seq.entries()) {
      record(m, i, files, ev)
      const at = `after ${seq.slice(0, i + 1).join('')}`
      await fire[ev](t, h)
      await h.clock.advance(3000)
      const r = step(m, ev)
      m = r.m
      if (r.told) told++
      if (r.launch) launches++
      record(m, i + 1, files)
      const marker = files[`${D}/busy/s1.json`]
      must(m.busy === (marker !== undefined), `${at}: busy marker ${marker === undefined ? 'missing' : 'left'}`)
      if (marker) {
        const b = JSON.parse(marker)
        must(b.v === 2 && b.account === 'acct' && b.busy === true, `${at}: marker ${marker}`)
      }
      must(h.prompts.length === told, `${at}: told ${h.prompts.length} times, not ${told}`)
      must(h.prompts.every(p => p.includes('switched to another account by hand')), `${at}: told ${JSON.stringify(h.prompts)}`)
      const ids = (JSON.parse(files[`${D}/handoff.json`] ?? '{"resume":[]}').resume as { sessionId: string }[]).map(r => r.sessionId)
      must(new Set(ids).size === ids.length, `${at}: listed twice: ${JSON.stringify(ids)}`)
      must(!ids.includes('old') && !ids.includes('elsewhere'), `${at}: listed a session it shouldn't: ${JSON.stringify(ids)}`)
      must(ids.includes('s1') === (m.s1 !== 'none'), `${at}: s1 listed: ${ids.includes('s1')}, model ${key(m)}`)
      must(ids.includes('s2') === (m.s2 !== 'none'), `${at}: s2 listed: ${ids.includes('s2')}, model ${key(m)}`)
      const n = h.runs.filter(a => a.includes('launch')).length
      must(n === launches, `${at}: ${n} switches started, not ${launches}`)
    }
  })
}

// Run last: every state the sequences reached was first reached within 3 events, got every
// event (in the 4th place at the latest), and always left the same files. Then a sequence of
// any length only ever takes steps checked above.
test('every state reached, with every event, covers sequences of any length', async () => {
  must(seen.size > 0, 'no states recorded (the tests ran apart?)')
  for (const [k, s] of seen) {
    must(s.depth <= 3, `${k} is first reached after ${s.depth} events: a longer sequence could reach states not checked`)
    must(s.events.size === EVENTS.length, `${k} got only ${[...s.events].join('')}`)
    must(s.files.size === 1, `${k} left different files: ${[...s.files].join(' | ')}`)
  }
  console.log(`states: ${seen.size}; ${[...seen.keys()].join('; ')}`)
})
