// The mod in Claude Code's own engine (claude plugin test; tests/e2e.sh copies the mod and this
// file into a folder and runs it). The engine loads the mod as Claude Code does (its rules for
// registering hooks, how $ calls reach the host), and delivers each event to its hooks. What
// the host would do for those calls is stood in for here: files in memory, processes recorded.
// A test file may import only 'claude-code', so nothing here touches the disk.
import { mock, test } from 'claude-code/testing'

const D = '/h/.claude/desktop-account-switcher'
const iso = (ms: number) => new Date(ms).toISOString()

function host(on: any, files: Record<string, string>) {
  const runs: string[][] = []
  const prompts: string[] = []
  const toasts: string[] = []
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
  on('ui.toast', ($: unknown, e: any) => (toasts.push(e.text ?? e.message ?? ''), { value: undefined }))
  on('session.id', () => ({ value: 's1' }))
  on('session.identity', () => ({ value: { kind: 'desktop' } }))
  on('session.usage', () => ({ value: { rateLimits: [{ kind: 'five_hour', percentUsed: 100, resetsAt: iso(3 * 3600_000) }] } }))
  for (const ev of ['classic.UserPromptSubmit', 'classic.StopFailure', 'classic.SessionStart']) on(ev, () => ({}))
  on('turn.complete', () => ({ text: 'done' }))
  return { runs, prompts, toasts, clock }
}
const must = (ok: unknown, what: string) => {
  if (!ok) throw new Error(what)
}

test('a turn marks its session busy, and its end clears it', async (t: any, on: any) => {
  const files: Record<string, string> = {}
  const h = host(on, files)
  await t.classic.UserPromptSubmit({ session_id: 's1', cwd: '/tmp', prompt: 'hi', hook_event_name: 'UserPromptSubmit', transcript_path: '/dev/null' })
  const busy = JSON.parse(files[`${D}/busy/s1.json`] ?? 'null')
  must(busy?.busy === true && busy?.v === 2 && busy?.account === 'acct', `busy marker: ${files[`${D}/busy/s1.json`]}`)
  await t.turn.complete({ answer: 'done', reason: 'answer', durationMs: 1, isAborted: false, turnId: 't1' })
  must(!(`${D}/busy/s1.json` in files), `marker left after the turn: ${JSON.stringify(h.runs)}`)
})

test('a limit lists the session and the ones mid-turn, then starts the switch', async (t: any, on: any) => {
  const files: Record<string, string> = {
    [`${D}/config.json`]: '{"armed":true}',
    [`${D}/busy/s2.json`]: JSON.stringify({ sessionId: 's2', cwd: '/tmp', account: 'acct', busy: true, v: 2, at: 0 }),
    [`${D}/busy/old.json`]: JSON.stringify({ sessionId: 'old', cwd: '/tmp', account: 'acct', busy: true, at: 0 }),
  }
  const h = host(on, files)
  await t.classic.StopFailure({ session_id: 's1', cwd: '/tmp', error: 'rate_limit', error_details: '', hook_event_name: 'StopFailure', transcript_path: '/dev/null' })
  const ids = (JSON.parse(files[`${D}/handoff.json`] ?? '{"resume":[]}').resume as { sessionId: string }[]).map(r => r.sessionId).sort()
  must(JSON.stringify(ids) === '["s1","s2"]', `hand-off lists ${JSON.stringify(ids)} (a marker from an older mod doesn't count)`)
  must(h.runs.some(a => a.includes('launch') && a.includes('--from') && a.includes('acct')), `no launch: ${JSON.stringify(h.runs)}`)
  must(h.runs.some(a => a[0] === '/bin/sh' && a.some(x => x.endsWith('handoff.json.lock'))), 'hand-off changed without its lock')
})

test('a reopened session is told why, once', async (t: any, on: any) => {
  const files: Record<string, string> = {
    [`${D}/handoff.json`]: JSON.stringify({
      closedAt: iso(0),
      resume: [
        { sessionId: 's1', cwd: '', reason: 'swap', account: 'acct', at: iso(0) },
        { sessionId: 's9', cwd: '', reason: 'closed', account: '', from: 'other', at: iso(0) },
      ],
    }),
  }
  const h = host(on, files)
  await t.classic.SessionStart({ session_id: 's1', source: 'resume', hook_event_name: 'SessionStart', transcript_path: '/dev/null' })
  await h.clock.advance(3000)
  must(h.prompts.length === 1 && h.prompts[0].includes('switched to another account by hand'), `prompts: ${JSON.stringify(h.prompts)}`)
  const left = (JSON.parse(files[`${D}/handoff.json`]).resume as { sessionId: string }[]).map(r => r.sessionId)
  must(JSON.stringify(left) === '["s9"]', `entries left: ${JSON.stringify(left)}`)
  await t.classic.SessionStart({ session_id: 's1', source: 'resume', hook_event_name: 'SessionStart', transcript_path: '/dev/null' })
  await h.clock.advance(3000)
  must(h.prompts.length === 1, 'told twice')
  await t.classic.SessionStart({ session_id: 's9', source: 'compact', hook_event_name: 'SessionStart', transcript_path: '/dev/null' })
  await h.clock.advance(3000)
  must(h.prompts.length === 1, 'a compact counted as a reopen')
  await t.classic.SessionStart({ session_id: 's9', source: 'startup', hook_event_name: 'SessionStart', transcript_path: '/dev/null' })
  await h.clock.advance(3000)
  must(h.prompts[1]?.includes('moved to another Claude account while this session was mid-turn'), `cut-off session: ${JSON.stringify(h.prompts)}`)
})
