// Stand-in for the Claude Code host the mod runs in: one session's process, running the mod's
// real hooks (mod/hooks/register.tsx) for one event, as Claude Code would. Files, processes
// (relay.sh) and the clock are real; what the host would show (toasts, a submitted prompt, a
// registered command, a command's reply, the row's text) goes to $HOME/mod-host.log as JSON
// lines instead.
//   bun tests/fakes/mod-host.ts <event> '<payload JSON>'
// The session is described by the environment: CLAUDE_CODE_ENTRYPOINT and
// CLAUDE_CODE_ACCOUNT_UUID (set by the app), MOD_SESSION (its id), MOD_IDENTITY (its login's
// kind), MOD_USAGE (its rate-limit windows, JSON). The process waits for timers the mod set
// (the carry-on message is sent 2.5 seconds after a session starts), as a live session would.
import { plugin } from 'bun'
import { appendFileSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

const [event, payload] = [process.argv[2], JSON.parse(process.argv[3] ?? '{}')]
const session = process.env.MOD_SESSION ?? 'session'
const out = (kind: string, text: string) =>
  appendFileSync(`${process.env.HOME}/mod-host.log`, JSON.stringify({ session, kind, text }) + '\n')

// The session's own environment: this stand-in may itself be started from inside Claude Code,
// whose variables a desktop session wouldn't have.
const env: Record<string, string | undefined> = { ...process.env }
delete env.CLAUDECODE
delete env.CLAUDE_CODE_CHILD_SESSION

const state = new Map<string, unknown>()
const host = {
  atom: (key: { plugin: string; key: string }, init: unknown) => ({ id: `${key.plugin}/${key.key}`, init }),
  read: async (_$: unknown, a: { id: string; init: unknown }) => (state.has(a.id) ? state.get(a.id) : a.init),
  update: async (_$: unknown, a: { id: string; init: unknown }, f: (v: unknown) => unknown) => {
    state.set(a.id, f(state.has(a.id) ? state.get(a.id) : a.init))
  },
}
// The row as a tree of { type, props }, read back as text: a Button as [its label].
type Node = { type: unknown; props: { children?: unknown; label?: string } }
const element = (type: unknown, props: Node['props']): Node => ({ type, props })
const jsx = { jsx: element, jsxs: element, jsxDEV: element, Fragment: 'Fragment' }
const textOf = (n: unknown): string => {
  if (n === null || n === undefined || n === false) return ''
  if (typeof n === 'string' || typeof n === 'number') return String(n)
  if (Array.isArray(n)) return n.map(textOf).filter(Boolean).join(' ')
  const { type, props } = n as Node
  return [type === 'Button' ? `[${props.label}]` : '', textOf(props.children)].filter(Boolean).join(' ')
}
plugin({
  name: 'claude-code host',
  setup(build) {
    build.module('claude-code', () => ({ exports: host, loader: 'object' }))
    for (const m of ['react/jsx-runtime', 'react/jsx-dev-runtime']) build.module(m, () => ({ exports: jsx, loader: 'object' }))
  },
})

const $ = {
  env: { get: async (k: string) => env[k] },
  fs: {
    read: async (p: string) => readFileSync(p, 'utf8'),
    write: async (p: string, text: string) => {
      mkdirSync(dirname(p), { recursive: true })
      writeFileSync(p, text)
    },
    list: async (p: string) => readdirSync(p, { withFileTypes: true }).map(d => ({ name: d.name, kind: d.isDirectory() ? 'directory' : 'file' })),
  },
  process: {
    run: async (argv: string[], opts?: { timeoutMs?: number }) => {
      const p = Bun.spawn(argv, { stdout: 'pipe', stderr: 'pipe', env: process.env })
      const timer = opts?.timeoutMs ? setTimeout(() => p.kill(), opts.timeoutMs) : undefined
      const [stdout, stderr, exitCode] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited])
      if (timer) clearTimeout(timer)
      return { exitCode, stdout, stderr }
    },
  },
  clock: { now: async () => Date.now(), after: (ms: number, f: () => void) => void setTimeout(f, ms) },
  ui: { toast: (text: string) => out('toast', text), resolve: () => ({ Box: 'Box', Button: 'Button', Text: 'Text' }), invalidate: (event: string) => out('invalidate', event) },
  prompt: { submit: async ({ text }: { text: string }) => out('prompt', text) },
  session: {
    id: async () => session,
    identity: async () => ({ kind: process.env.MOD_IDENTITY ?? 'desktop' }),
    usage: async () => ({ rateLimits: JSON.parse(process.env.MOD_USAGE ?? '[]') }),
  },
  command: { register: async (c: { name: string }) => out('command', c.name) },
}

// Every handler for an event, in the order registered, each passing on to the next.
type Handler = ($: unknown, e: unknown, next: Next) => unknown
type Next = ((e: unknown) => Promise<unknown>) & { called: boolean }
const handlers: { name: string; filter?: Record<string, unknown>; run: Handler; onError?: Handler }[] = []
const on = (name: string, a: Handler | Record<string, unknown>, b?: Handler) => {
  const h = typeof a === 'function' ? { name, run: a } : { name, filter: a, run: b as Handler }
  // Claude Code's own rule: one hook per event without a matcher, or the mod doesn't load.
  if (h.filter === undefined && handlers.some(x => x.name === name && x.filter === undefined))
    throw new Error(`on("${name}") is registered twice without a matcher`)
  handlers.push(h)
  return { catch: (f: Handler) => void ((h as { onError?: Handler }).onError = f) }
}
const { register } = await import('../../mod/hooks/register.tsx')
register(on)

const chain = handlers.filter(h => h.name === event)
const step = async (i: number, e: unknown): Promise<unknown> => {
  const next = (async (e2: unknown) => {
    next.called = true
    return step(i + 1, e2)
  }) as Next
  next.called = false
  const h = chain[i]
  if (h === undefined) return undefined
  try {
    return await h.run($, e, next)
  } catch (err) {
    if (h.onError === undefined) throw err
    return h.onError($, e, next)
  }
}
const result = await step(0, payload)
if (event === 'command.run') out('reply', (result as { text?: string } | undefined)?.text ?? '')
if (event === 'ui.render') out('row', textOf(result))
