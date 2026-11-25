'use strict'
/*
 * Blossom farm kit - restart service.
 *
 * A small HTTP service on the farm computer that lets Blossom CRM show which
 * farm programs are running and start or restart them (the "Services" panel).
 *
 * Contract (the same one the product calls):
 *   every request carries   Authorization: Bearer <restart secret>
 *   GET  /status             -> 200 { hub, provider, cloudflare, keep_available,
 *                                      mongodb, action_in_progress }  (booleans)
 *   POST /start-all | /restart-all | /start-provider | /restart-provider
 *        | /restart-cloudflare
 *                            -> 200 { ok: true, message }   (work continues in
 *                               the background), 409 while another action runs
 *   anything else            -> 404, wrong or missing secret -> 401
 *
 * Security properties (see docs/security.md):
 *   - refuses to start without a secret of at least 32 characters; there is
 *     no built-in default;
 *   - the secret is read from a file (GADS_RESTART_SECRET_FILE) so that it is
 *     not visible in the service's registry entry or process list;
 *   - the secret is compared in constant time;
 *   - listens on 127.0.0.1 only (the tunnel connects to it locally);
 *   - sends no CORS headers: it is called server to server, never by a browser;
 *   - runs only fixed commands (sc.exe start|stop|query <fixed service name>);
 *     nothing from a request ever reaches a command line;
 *   - never logs the secret or request headers.
 *
 * No dependencies beyond Node.js itself.
 */

const http = require('http')
const crypto = require('crypto')
const fs = require('fs')
const { execFile } = require('child_process')

const HOST = '127.0.0.1' // fixed on purpose: not configurable
const DEFAULT_PORT = 19999
const MIN_SECRET_LENGTH = 32
const MAX_BODY_BYTES = 4096

// Windows service names created by install.ps1.
const SERVICES = Object.freeze({
  mongodb: 'MongoDB',
  hub: 'GadsHub',
  provider: 'GadsProvider',
  gate: 'FarmGate',
  keep_available: 'KeepAvailable',
  cloudflare: 'Cloudflared',
})

/** Constant-time comparison of two strings of any length. */
function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(String(a), 'utf8').digest()
  const hb = crypto.createHash('sha256').update(String(b), 'utf8').digest()
  return crypto.timingSafeEqual(ha, hb)
}

/** Reads the secret from the environment. Throws when there is none: no fallback. */
function loadSecret(env = process.env) {
  let secret = ''
  if (env.GADS_RESTART_SECRET_FILE) {
    try {
      secret = fs.readFileSync(env.GADS_RESTART_SECRET_FILE, 'utf8').replace(/^﻿/, '').trim()
    } catch (e) {
      throw new Error(`cannot read the secret file named in GADS_RESTART_SECRET_FILE (${e.code || e.message})`)
    }
  } else if (env.GADS_RESTART_SECRET) {
    secret = String(env.GADS_RESTART_SECRET).trim()
  }
  if (!secret) {
    throw new Error('no restart secret configured: set GADS_RESTART_SECRET_FILE to a file holding the secret. There is no default secret.')
  }
  if (secret.length < MIN_SECRET_LENGTH) {
    throw new Error(`the restart secret is too short (${secret.length} characters, minimum ${MIN_SECRET_LENGTH}). Generate a new one with scripts\\rotate-secrets.ps1.`)
  }
  return secret
}

/** The real service controller: sc.exe with fixed arguments, no shell. */
function scController() {
  const run = (args) => new Promise(resolve => {
    execFile('sc.exe', args, { windowsHide: true, timeout: 30000 }, (err, stdout) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, out: String(stdout || '') })
    })
  })
  return {
    // "STATE : 4 RUNNING": the label before the colon is translated on some
    // Windows languages, the number and the state name are not.
    isRunning: async name => /:\s*4\s+RUNNING/.test((await run(['query', name])).out),
    // "sc stop" returns as soon as the request is accepted; the service is
    // only down when its state reads 1 STOPPED. A service that does not exist
    // (error 1060) counts as stopped.
    isStopped: async name => {
      const r = await run(['query', name])
      return /:\s*1\s+STOPPED/.test(r.out) || r.code === 1060 || /\b1060\b/.test(r.out)
    },
    start: async name => (await run(['start', name])).code,
    stop: async name => (await run(['stop', name])).code,
  }
}

function createApp(options) {
  const secret = options && options.secret
  if (typeof secret !== 'string' || secret.length < MIN_SECRET_LENGTH) {
    throw new Error(`a restart secret of at least ${MIN_SECRET_LENGTH} characters is required`)
  }
  const sc = options.controller || scController()
  const log = options.log || (msg => console.log(`[restart-server] ${new Date().toISOString()} ${msg}`))
  const wait = options.wait || (ms => new Promise(r => setTimeout(r, ms)))
  // Time between answering and touching the tunnel, so the answer gets out.
  const replyGraceMs = options.replyGraceMs === undefined ? 1500 : options.replyGraceMs

  let actionInProgress = false

  // How long a stop may take before it is given up: nssm's own stop sequence
  // (console 5 s, then window, threads, terminate) plus a margin.
  const stopTimeoutMs = options.stopTimeoutMs === undefined ? 25000 : options.stopTimeoutMs
  const stopPollMs = 500

  const start = async name => { const code = await sc.start(name); log(`start ${name} -> ${code}`) }

  /**
   * Stops a service and waits until Windows reports it as stopped. Windows
   * refuses to stop a service while one that depends on it is still stopping
   * (error 1051), and refuses to start one that is still stopping (1056), so
   * a stop that is only requested is not enough. Returns true when stopped.
   */
  async function stopAndWait(name) {
    const code = await sc.stop(name)
    log(`stop ${name} -> ${code}`)
    if (typeof sc.isStopped !== 'function') { await wait(3000); return true }
    for (let waited = 0; ; waited += stopPollMs) {
      if (await sc.isStopped(name)) return true
      if (waited >= stopTimeoutMs) { log(`${name} did not stop within ${Math.round(stopTimeoutMs / 1000)} s`); return false }
      await wait(stopPollMs)
    }
  }

  // Order matters: the hub needs MongoDB, the provider needs the hub.
  async function startAll() {
    await start(SERVICES.mongodb); await wait(2000)
    await start(SERVICES.hub); await wait(3000)
    await start(SERVICES.provider); await wait(1000)
    await start(SERVICES.gate)
    await start(SERVICES.keep_available)
    await start(SERVICES.cloudflare)
  }
  async function restartAll() {
    await wait(replyGraceMs)
    await stopAndWait(SERVICES.cloudflare)
    // Everything that depends on the hub must be down before the hub is asked
    // to stop, otherwise Windows refuses and the hub is never restarted.
    await stopAndWait(SERVICES.keep_available)
    await stopAndWait(SERVICES.gate)
    await stopAndWait(SERVICES.provider)
    let hubStopped = await stopAndWait(SERVICES.hub)
    if (!hubStopped) hubStopped = await stopAndWait(SERVICES.hub)
    if (!hubStopped) log(`${SERVICES.hub} could NOT be stopped, so it was not restarted; the other services are started again`)
    await wait(1000)
    await startAll()
  }
  async function startProvider() {
    await start(SERVICES.provider)
    await start(SERVICES.gate)
  }
  async function restartProvider() {
    await stopAndWait(SERVICES.provider)
    await wait(1000)
    await startProvider()
  }
  async function restartCloudflare() {
    await wait(replyGraceMs)
    await stopAndWait(SERVICES.cloudflare)
    await wait(1000)
    await start(SERVICES.cloudflare)
  }

  const ACTIONS = {
    '/start-all': ['Starting all services...', startAll],
    '/restart-all': ['Restarting all services...', restartAll],
    '/start-provider': ['Starting provider...', startProvider],
    '/restart-provider': ['Provider restart initiated', restartProvider],
    '/restart-cloudflare': ['Tunnel restart initiated', restartCloudflare],
  }

  async function status() {
    const [hub, provider, gate, cloudflare, keepAvailable, mongodb] = await Promise.all([
      sc.isRunning(SERVICES.hub), sc.isRunning(SERVICES.provider), sc.isRunning(SERVICES.gate),
      sc.isRunning(SERVICES.cloudflare), sc.isRunning(SERVICES.keep_available), sc.isRunning(SERVICES.mongodb),
    ])
    return {
      hub,
      // the provider is only usable through its gate, so both must run
      provider: provider && gate,
      cloudflare,
      keep_available: keepAvailable,
      mongodb,
      action_in_progress: actionInProgress,
    }
  }

  function send(res, code, body) {
    const text = JSON.stringify(body)
    res.writeHead(code, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(text),
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    })
    res.end(text)
  }

  function authorized(req) {
    const header = req.headers['authorization']
    const m = typeof header === 'string' ? /^Bearer (.+)$/.exec(header) : null
    // compare even when the header is missing or malformed, so every refusal costs the same
    const ok = safeEqual(m ? m[1] : '', secret)
    return Boolean(m) && ok
  }

  function handle(req, res) {
    // Drain (and cap) any body: nothing in it is used.
    let received = 0
    req.on('data', chunk => {
      received += chunk.length
      if (received > MAX_BODY_BYTES) req.destroy()
    })
    req.on('error', () => {})

    if (!authorized(req)) return send(res, 401, { error: 'Unauthorized' })

    const path = String(req.url || '').split('?')[0]

    if (req.method === 'GET' && path === '/status') {
      status().then(s => send(res, 200, s)).catch(e => { log(`status failed: ${e && e.message}`); send(res, 500, { error: 'Status unavailable' }) })
      return
    }

    if (req.method === 'POST' && Object.prototype.hasOwnProperty.call(ACTIONS, path)) {
      if (actionInProgress) return send(res, 409, { error: 'Action already in progress' })
      const [message, fn] = ACTIONS[path]
      actionInProgress = true
      log(`action ${path}`)
      send(res, 200, { ok: true, message })
      Promise.resolve().then(fn)
        .catch(e => log(`action ${path} failed: ${e && e.message}`))
        .then(() => { actionInProgress = false; log(`action ${path} finished`) })
      return
    }

    send(res, 404, { error: 'Not found' })
  }

  const server = http.createServer(handle)
  server.headersTimeout = 10000
  server.requestTimeout = 15000
  server.keepAliveTimeout = 5000
  server.maxHeadersCount = 50

  return {
    server,
    /** Always binds 127.0.0.1; only the port can be chosen. */
    listen(port, cb) { return server.listen(port === undefined ? DEFAULT_PORT : port, HOST, cb) },
    isBusy: () => actionInProgress,
  }
}

function main() {
  let secret
  try { secret = loadSecret() } catch (e) {
    console.error(`[restart-server] REFUSING TO START: ${e.message}`)
    process.exit(1)
  }
  const port = Number(process.env.GADS_RESTART_PORT || DEFAULT_PORT)
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    console.error('[restart-server] REFUSING TO START: GADS_RESTART_PORT must be a port between 1024 and 65535.')
    process.exit(1)
  }
  const app = createApp({ secret })
  app.server.on('error', e => { console.error(`[restart-server] ${e.message}`); process.exit(1) })
  app.listen(port, () => console.log(`[restart-server] ${new Date().toISOString()} listening on http://${HOST}:${port}`))
}

module.exports = { createApp, loadSecret, safeEqual, scController, SERVICES, HOST, DEFAULT_PORT, MIN_SECRET_LENGTH }

if (require.main === module) main()
