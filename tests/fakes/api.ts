// Stand-in for Anthropic's API, for a real Claude Code session in tests/e2e.sh: every model
// request is refused as a usage limit, as the real API refuses one on an account whose 5-hour
// window is used up (429, rate_limit_error, and the unified rate-limit headers saying so).
// Anything else gets a 404. Listens on 127.0.0.1 only; prints its port, and logs each request's
// method and path (never its headers) to the file named by $1.
//   bun tests/fakes/api.ts <log file>
import { appendFileSync } from 'node:fs'

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
const server = Bun.serve({
  hostname: '127.0.0.1',
  port: 0,
  fetch(req) {
    const path = new URL(req.url).pathname
    appendFileSync(log, `${req.method} ${path}\n`)
    if (req.method === 'POST' && path === '/v1/messages') {
      const body = { type: 'error', error: { type: 'rate_limit_error', message: "This request would exceed your account's rate limit. Please try again later." } }
      return new Response(JSON.stringify(body), { status: 429, headers: limited })
    }
    return new Response(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: 'not here' } }), { status: 404, headers: { 'content-type': 'application/json' } })
  },
})
console.log(server.port)
