// Stand-in for Anthropic's API that answers: every model request gets a one-word reply, and its
// stand-in token is logged, to show which login a running claude is using. Listens on 127.0.0.1
// only; prints its port. A token that doesn't look like a stand-in is logged only as "other".
//   bun tests/fakes/api-answers.ts <log file>        (or node, 24 and later)
import { appendFileSync } from 'node:fs'
import { createServer } from 'node:http'

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
const server = createServer((req, res) => {
  const path = new URL(req.url ?? '/', 'http://127.0.0.1').pathname
  req.resume()
  if (req.method === 'POST' && path === '/v1/messages') {
    const token = String(req.headers.authorization ?? '').replace('Bearer ', '')
    appendFileSync(log, `${token.startsWith('stand-in-') ? token : 'other'}\n`)
    res.writeHead(200, { 'content-type': 'text/event-stream' }).end(reply)
    return
  }
  res.writeHead(404, { 'content-type': 'application/json' }).end('{}')
})
server.listen(0, '127.0.0.1', () => console.log((server.address() as { port: number }).port))
