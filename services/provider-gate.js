'use strict'
/*
 * Blossom farm kit - provider gate.
 *
 * Why this exists: the GADS provider (checked in the v6.0.0 source,
 * provider/router/handler.go) has no authentication of its own. Whoever can
 * reach its port can list the phones, take screenshots and tap. Blossom CRM
 * needs the provider on a public https host name (live video signalling and
 * the assistant go there), so the kit never publishes the provider's port.
 * The tunnel points at this gate instead, and the gate only lets a request
 * through when it carries a session token that the hub on this computer
 * accepts - the same token Blossom already sends:
 *
 *   Authorization: Bearer <hub token>        (server calls)
 *   ...?token=<hub token>                    (the browser's WebSocket)
 *
 * The token is checked by asking the local hub (GET /user-info) and the
 * answer is cached for a short time. Plain HTTP and WebSocket upgrades are
 * both passed on unchanged once the token is accepted.
 *
 * Listens on 127.0.0.1 only, talks to 127.0.0.1 only. No dependencies.
 */

const http = require('http')
const net = require('net')
const crypto = require('crypto')

const HOST = '127.0.0.1' // fixed on purpose
const VALID_TTL_MS = 30000
const INVALID_TTL_MS = 5000
const MAX_CACHE = 500
const MAX_TOKEN_LENGTH = 4096

// Never passed on, even with a valid token: profiling endpoints and the
// endpoints the provider only serves to its own local helpers.
const BLOCKED = [/^\/debug(\/|$)/i, /^\/device\/[^/]+\/appium-plugin(\/|$)/i]

function portFrom(value, fallback, name) {
  const port = value === undefined || value === '' ? fallback : Number(value)
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error(`${name} must be a port between 1024 and 65535`)
  return port
}

function tokenFrom(req) {
  const header = req.headers['authorization']
  if (typeof header === 'string') {
    const m = /^Bearer (.+)$/.exec(header)
    if (m) return m[1]
  }
  const q = String(req.url || '').indexOf('?')
  if (q >= 0) {
    try {
      const t = new URLSearchParams(String(req.url).slice(q + 1)).get('token')
      if (t) return t
    } catch (_) { /* fall through */ }
  }
  return ''
}

function createGate(options) {
  const hubPort = options.hubPort
  const upstreamPort = options.upstreamPort
  const log = options.log || (msg => console.log(`[provider-gate] ${new Date().toISOString()} ${msg}`))
  const now = options.now || (() => Date.now())
  const cache = new Map() // sha256(token) -> { ok, until }

  /** Resolves true (accepted), false (refused) or null (the hub could not be asked). */
  function askHub(token) {
    return new Promise(resolve => {
      const req = http.request({
        host: HOST, port: hubPort, path: '/user-info', method: 'GET',
        headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' }, timeout: 8000,
      }, res => {
        res.resume()
        if (res.statusCode === 200) resolve(true)
        else if (res.statusCode === 401 || res.statusCode === 403) resolve(false)
        else resolve(null)
      })
      req.on('timeout', () => req.destroy(new Error('timeout')))
      req.on('error', () => resolve(null))
      req.end()
    })
  }

  async function check(token) {
    if (!token || token.length > MAX_TOKEN_LENGTH || /[\r\n]/.test(token)) return false
    const key = crypto.createHash('sha256').update(token, 'utf8').digest('hex')
    const hit = cache.get(key)
    if (hit && hit.until > now()) return hit.ok
    const ok = await askHub(token)
    if (ok === null) return null // not cached: the hub may be back in a second
    if (cache.size >= MAX_CACHE) cache.clear()
    cache.set(key, { ok, until: now() + (ok ? VALID_TTL_MS : INVALID_TTL_MS) })
    return ok
  }

  const pathOf = req => String(req.url || '').split('?')[0]
  const blocked = req => BLOCKED.some(re => re.test(pathOf(req)))

  function reply(res, code, error) {
    const text = JSON.stringify({ error })
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(text), 'Cache-Control': 'no-store' })
    res.end(text)
  }

  const server = http.createServer((req, res) => {
    req.on('error', () => {})
    if (blocked(req)) { req.resume(); return reply(res, 404, 'Not found') }
    check(tokenFrom(req)).then(ok => {
      if (ok === null) { req.resume(); return reply(res, 503, 'The hub on the farm computer is not answering, so the token cannot be checked') }
      if (!ok) { req.resume(); return reply(res, 401, 'Unauthorized') }
      const up = http.request({ host: HOST, port: upstreamPort, method: req.method, path: req.url, headers: req.headers }, upRes => {
        res.writeHead(upRes.statusCode || 502, upRes.headers)
        upRes.pipe(res)
      })
      up.on('error', () => { if (!res.headersSent) reply(res, 502, 'The provider on the farm computer is not answering'); else res.destroy() })
      res.on('close', () => up.destroy())
      req.pipe(up)
    }).catch(e => { log(`request failed: ${e && e.message}`); if (!res.headersSent) reply(res, 500, 'Gate error') })
  })

  server.on('upgrade', (req, socket, head) => {
    socket.on('error', () => {})
    const refuse = (code, text) => { socket.end(`HTTP/1.1 ${code} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`) }
    if (blocked(req)) return refuse(404, 'Not Found')
    check(tokenFrom(req)).then(ok => {
      if (ok === null) return refuse(503, 'Service Unavailable')
      if (!ok) return refuse(401, 'Unauthorized')
      const up = net.connect(upstreamPort, HOST, () => {
        let raw = `${req.method} ${req.url} HTTP/1.1\r\n`
        for (let i = 0; i < req.rawHeaders.length; i += 2) raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`
        up.write(raw + '\r\n')
        if (head && head.length) up.write(head)
        up.pipe(socket)
        socket.pipe(up)
      })
      // Sockets handed over by an upgrade stay half-open after the other side
      // hangs up, so both ends are torn down together explicitly.
      let connected = false
      const done = () => { up.destroy(); socket.destroy() }
      up.on('connect', () => { connected = true })
      up.on('error', () => { if (!connected && !socket.destroyed) refuse(502, 'Bad Gateway'); else done() })
      for (const s of [socket, up]) { s.on('end', done); s.on('close', done) }
      socket.on('error', done)
    }).catch(() => refuse(500, 'Internal Server Error'))
  })

  server.headersTimeout = 15000
  server.keepAliveTimeout = 5000

  return {
    server,
    /** Always binds 127.0.0.1; only the port can be chosen. */
    listen(port, cb) { return server.listen(port, HOST, cb) },
  }
}

function main() {
  let port, hubPort, upstreamPort
  try {
    port = portFrom(process.env.FARM_GATE_PORT, 10002, 'FARM_GATE_PORT')
    hubPort = portFrom(process.env.FARM_GATE_HUB_PORT, 10000, 'FARM_GATE_HUB_PORT')
    upstreamPort = portFrom(process.env.FARM_GATE_PROVIDER_PORT, 10001, 'FARM_GATE_PROVIDER_PORT')
  } catch (e) {
    console.error(`[provider-gate] REFUSING TO START: ${e.message}`)
    process.exit(1)
  }
  const gate = createGate({ hubPort, upstreamPort })
  gate.server.on('error', e => { console.error(`[provider-gate] ${e.message}`); process.exit(1) })
  gate.listen(port, () => console.log(`[provider-gate] ${new Date().toISOString()} listening on http://${HOST}:${port} -> provider ${HOST}:${upstreamPort}, tokens checked with hub ${HOST}:${hubPort}`))
}

module.exports = { createGate, tokenFrom, HOST }

if (require.main === module) main()
