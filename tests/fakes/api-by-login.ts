// Stand-in for Anthropic's API where one login is out of usage and the others aren't: a model
// request with the stand-in token named in the file $2 (read anew each request) is refused as a
// used-up 5-hour window, like tests/fakes/api.ts; any other gets a one-word reply, like
// tests/fakes/api-answers.ts. Each request's stand-in token and what it got go to the log $1.
// Listens on 127.0.0.1 only; prints its port.
//   bun tests/fakes/api-by-login.ts <log file> <file naming the token that's out>
import { appendFileSync, readFileSync } from 'node:fs'
import { createServer } from 'node:http'

const log = process.argv[2] ?? '/dev/null'
const outFile = process.argv[3] ?? '/dev/null'
const sse = (o: { type: string }) => `event: ${o.type}\ndata: ${JSON.stringify(o)}\n\n`
const reply = [
  sse({ type: 'message_start', message: { id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-haiku-5-5', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } } as never),
  sse({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } } as never),
  sse({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'ok' } } as never),
  sse({ type: 'content_block_stop', index: 0 } as never),
  sse({ type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 1 } } as never),
  sse({ type: 'message_stop' }),
].join('')
const limited = () => {
  const reset = Math.floor(Date.now() / 1000) + 3 * 3600
  return {
    'content-type': 'application/json',
    'request-id': 'req_stand_in',
    'anthropic-ratelimit-unified-status': 'rejected',
    'anthropic-ratelimit-unified-reset': String(reset),
    'anthropic-ratelimit-unified-representative-claim': 'five_hour',
    'anthropic-ratelimit-unified-5h-status': 'rejected',
    'anthropic-ratelimit-unified-5h-utilization': '1.0',
    'anthropic-ratelimit-unified-5h-reset': String(reset),
    'anthropic-ratelimit-unified-7d-status': 'allowed',
    'anthropic-ratelimit-unified-7d-utilization': '0.4',
    'anthropic-ratelimit-unified-7d-reset': String(reset + 3 * 86400),
    'anthropic-ratelimit-unified-overage-status': 'rejected',
  }
}
const server = createServer((req, res) => {
  const path = new URL(req.url ?? '/', 'http://127.0.0.1').pathname
  req.resume()
  if (req.method !== 'POST' || path !== '/v1/messages') {
    res.writeHead(404, { 'content-type': 'application/json' }).end('{}')
    return
  }
  const token = String(req.headers.authorization ?? '').replace('Bearer ', '')
  const name = token.startsWith('stand-in-') ? token : 'other'
  let out = ''
  try {
    out = readFileSync(outFile, 'utf8').trim()
  } catch {}
  if (token === out) {
    appendFileSync(log, `${name} refused\n`)
    const body = { type: 'error', error: { type: 'rate_limit_error', message: "This request would exceed your account's rate limit. Please try again later." } }
    res.writeHead(429, limited()).end(JSON.stringify(body))
    return
  }
  appendFileSync(log, `${name} answered\n`)
  res.writeHead(200, { 'content-type': 'text/event-stream' }).end(reply)
})
server.listen(0, '127.0.0.1', () => console.log((server.address() as { port: number }).port))
