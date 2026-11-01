// Stand-in for Anthropic's API that answers: every model request gets a one-word reply, and its
// stand-in token is logged, to show which login a running claude is using. Listens on 127.0.0.1
// only; prints its port. A token that doesn't look like a stand-in is logged only as "other".
//   bun tests/fakes/api-answers.ts <log file>
import { appendFileSync } from 'node:fs'

const log = process.argv[2] ?? '/dev/null'
const sse = (o: { type: string }) => `event: ${o.type}\ndata: ${JSON.stringify(o)}\n\n`
const reply = [
  sse({ type: 'message_start', message: { id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-haiku-5-5', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } } as never),
  sse({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } } as never),
  sse({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'ok' } } as never),
  sse({ type: 'content_block_stop', index: 0 } as never),
  sse({ type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 1 } } as never),
  sse({ type: 'message_stop' }),
].join('')
const server = Bun.serve({
  hostname: '127.0.0.1',
  port: 0,
  fetch(req) {
    const url = new URL(req.url)
    if (req.method === 'POST' && url.pathname === '/v1/messages') {
      const token = (req.headers.get('authorization') ?? '').replace('Bearer ', '')
      appendFileSync(log, `${token.startsWith('stand-in-') ? token : 'other'}\n`)
      return new Response(reply, { headers: { 'content-type': 'text/event-stream' } })
    }
    return new Response('{}', { status: 404, headers: { 'content-type': 'application/json' } })
  },
})
console.log(server.port)
