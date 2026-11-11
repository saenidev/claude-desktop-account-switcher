// Stand-in for Anthropic's API, for a real Claude Code session in the tests: every model
// request is refused as a usage limit, as the real API refuses one on an account whose 5-hour
// window is used up (429, rate_limit_error, and the unified rate-limit headers saying so).
// Anything else gets a 404. Listens on 127.0.0.1 only; prints its port, and logs each request's
// method and path (never its headers) to the file named by $1.
//   bun tests/fakes/api.ts <log file>        (or node, 24 and later)
import { appendFileSync } from 'node:fs'
import { createServer } from 'node:http'

const log = process.argv[2] ?? '/dev/null'
const reset = Math.floor(Date.now() / 1000) + 3 * 3600
const limited = {
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
const server = createServer((req, res) => {
  const path = new URL(req.url ?? '/', 'http://127.0.0.1').pathname
  appendFileSync(log, `${req.method} ${path}\n`)
  req.resume()
  if (req.method === 'POST' && path === '/v1/messages') {
    const body = { type: 'error', error: { type: 'rate_limit_error', message: "This request would exceed your account's rate limit. Please try again later." } }
    res.writeHead(429, limited).end(JSON.stringify(body))
    return
  }
  res.writeHead(404, { 'content-type': 'application/json' }).end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: 'not here' } }))
})
server.listen(0, '127.0.0.1', () => console.log((server.address() as { port: number }).port))
