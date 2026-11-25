'use strict'
// Run with:  node --test tests/
const test = require('node:test')
const assert = require('node:assert')
const http = require('node:http')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const SERVER = path.join(__dirname, '..', 'services', 'restart-server.js')
const { createApp, loadSecret, safeEqual, SERVICES, HOST } = require(SERVER)

const SECRET = 'a'.repeat(64)

/** A stand-in for sc.exe that records every call. */
function fakeController(initial) {
  const running = new Set(initial || Object.values(SERVICES))
  const calls = []
  return {
    calls, running,
    isRunning: async name => running.has(name),
    start: async name => { calls.push(`start ${name}`); running.add(name); return 0 },
    stop: async name => { calls.push(`stop ${name}`); running.delete(name); return 0 },
  }
}

function request(port, method, urlPath, headers, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers: headers || {} }, res => {
      const chunks = []
      res.on('data', c => chunks.push(c))
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString()
        let json = null
        try { json = JSON.parse(text) } catch (_) { /* not JSON */ }
        resolve({ status: res.statusCode, headers: res.headers, text, json })
      })
    })
    req.on('error', reject)
    if (body !== undefined) req.write(body)
    req.end()
  })
}

async function withApp(options, fn) {
  const controller = options.controller || fakeController()
  let release
  const gate = new Promise(r => { release = r })
  const app = createApp({
    secret: SECRET, controller, log: () => {}, replyGraceMs: 0,
    wait: options.hold ? () => gate : async () => {},
  })
  await new Promise(r => app.listen(0, r))
  const port = app.server.address().port
  try { await fn({ app, port, controller, release }) } finally {
    release()
    await new Promise(r => app.server.close(r))
  }
}

const auth = { Authorization: `Bearer ${SECRET}` }
const settle = async app => { for (let i = 0; i < 200 && app.isBusy(); i++) await new Promise(r => setTimeout(r, 5)) }

test('refuses to be created without a secret, or with a short one', () => {
  assert.throws(() => createApp({}), /secret/)
  assert.throws(() => createApp({ secret: '' }), /secret/)
  assert.throws(() => createApp({ secret: 'short-secret' }), /secret/)
})

test('loadSecret: no secret configured -> throws, there is no default', () => {
  assert.throws(() => loadSecret({}), /no restart secret configured/)
  assert.throws(() => loadSecret({ GADS_RESTART_SECRET: '' }), /no restart secret configured/)
  assert.throws(() => loadSecret({ GADS_RESTART_SECRET: 'too-short' }), /too short/)
  assert.throws(() => loadSecret({ GADS_RESTART_SECRET_FILE: path.join(os.tmpdir(), 'does-not-exist-' + Date.now()) }), /cannot read/)
})

test('loadSecret: reads the secret from a file, trimming BOM and newline', () => {
  const file = path.join(os.tmpdir(), `restart-secret-${process.pid}-${Date.now()}.txt`)
  fs.writeFileSync(file, '﻿' + SECRET + '\r\n')
  try { assert.strictEqual(loadSecret({ GADS_RESTART_SECRET_FILE: file }), SECRET) } finally { fs.unlinkSync(file) }
})

test('the process exits with an error when started without a secret', () => {
  const env = Object.assign({}, process.env)
  delete env.GADS_RESTART_SECRET
  delete env.GADS_RESTART_SECRET_FILE
  const r = spawnSync(process.execPath, [SERVER], { env, encoding: 'utf8', timeout: 15000 })
  assert.strictEqual(r.status, 1)
  assert.match(r.stderr, /REFUSING TO START/)
  assert.match(r.stderr, /no default secret/i)
})

test('the source has no fallback secret, no wildcard CORS and no public bind address', () => {
  const src = fs.readFileSync(SERVER, 'utf8')
  // a fallback would look like:  process.env.X || 'some-default'
  assert.doesNotMatch(src, /env\.[A-Z_]+\s*\|\|\s*['"`]/)
  assert.doesNotMatch(src, /Access-Control-Allow-Origin/i)
  assert.doesNotMatch(src, /0\.0\.0\.0/)
})

test('safeEqual: correct for equal, different and different-length input, and uses timingSafeEqual', () => {
  assert.strictEqual(safeEqual(SECRET, SECRET), true)
  assert.strictEqual(safeEqual(SECRET, 'b'.repeat(64)), false)
  assert.strictEqual(safeEqual(SECRET, SECRET + 'x'), false)
  assert.strictEqual(safeEqual('', SECRET), false)
  const original = crypto.timingSafeEqual
  let used = 0
  crypto.timingSafeEqual = (a, b) => { used++; assert.strictEqual(a.length, b.length); return original(a, b) }
  try { safeEqual('abc', 'a much longer value than abc') } finally { crypto.timingSafeEqual = original }
  assert.strictEqual(used, 1)
})

test('binds to 127.0.0.1 only', async () => {
  await withApp({}, async ({ app }) => {
    assert.strictEqual(HOST, '127.0.0.1')
    assert.strictEqual(app.server.address().address, '127.0.0.1')
    assert.strictEqual(app.server.address().family, 'IPv4')
  })
})

test('auth: missing, malformed and wrong secrets are refused with 401 on every route', async () => {
  await withApp({}, async ({ port, controller }) => {
    const bad = [undefined, {}, { Authorization: SECRET }, { Authorization: 'Bearer ' }, { Authorization: 'Bearer wrong' },
      { Authorization: `Bearer ${SECRET}x` }, { Authorization: `bearer ${SECRET}` }, { Authorization: `Basic ${SECRET}` },
      { Authorization: `Bearer ${SECRET.slice(0, -1)}` }]
    for (const headers of bad) {
      for (const [method, p] of [['GET', '/status'], ['POST', '/restart-all'], ['POST', '/start-provider'], ['GET', '/nope'], ['OPTIONS', '/status']]) {
        const r = await request(port, method, p, headers)
        assert.strictEqual(r.status, 401, `${method} ${p} with ${JSON.stringify(headers)}`)
        assert.deepStrictEqual(r.json, { error: 'Unauthorized' })
      }
    }
    assert.deepStrictEqual(controller.calls, [], 'nothing may run without the secret')
  })
})

test('no CORS headers are sent, with or without the secret', async () => {
  await withApp({}, async ({ port }) => {
    for (const headers of [auth, {}, { Origin: 'https://evil.example', ...auth }]) {
      const r = await request(port, 'GET', '/status', headers)
      for (const h of Object.keys(r.headers)) assert.ok(!h.startsWith('access-control-'), `unexpected header ${h}`)
    }
    const pre = await request(port, 'OPTIONS', '/status', { Origin: 'https://evil.example', 'Access-Control-Request-Method': 'POST' })
    assert.strictEqual(pre.status, 401)
  })
})

test('GET /status: the six booleans of the contract, nothing else', async () => {
  await withApp({}, async ({ port }) => {
    const r = await request(port, 'GET', '/status', auth)
    assert.strictEqual(r.status, 200)
    assert.deepStrictEqual(r.json, { hub: true, provider: true, cloudflare: true, keep_available: true, mongodb: true, action_in_progress: false })
    assert.match(r.headers['content-type'], /application\/json/)
    assert.strictEqual(r.headers['cache-control'], 'no-store')
  })
})

test('GET /status: reports stopped services; provider needs its gate too', async () => {
  const controller = fakeController([SERVICES.mongodb, SERVICES.hub, SERVICES.provider])
  await withApp({ controller }, async ({ port }) => {
    const r = await request(port, 'GET', '/status?x=1', auth)
    assert.deepStrictEqual(r.json, { hub: true, provider: false, cloudflare: false, keep_available: false, mongodb: true, action_in_progress: false })
  })
})

test('POST /start-all starts everything in dependency order', async () => {
  const controller = fakeController([])
  await withApp({ controller }, async ({ app, port }) => {
    const r = await request(port, 'POST', '/start-all', { ...auth, 'Content-Type': 'application/json' }, '{}')
    assert.strictEqual(r.status, 200)
    assert.strictEqual(r.json.ok, true)
    assert.strictEqual(typeof r.json.message, 'string')
    await settle(app)
    assert.deepStrictEqual(controller.calls, ['start MongoDB', 'start GadsHub', 'start GadsProvider', 'start FarmGate', 'start KeepAvailable', 'start Cloudflared'])
  })
})

test('POST /restart-all stops in reverse order, then starts; MongoDB is not stopped', async () => {
  await withApp({}, async ({ app, port, controller }) => {
    const r = await request(port, 'POST', '/restart-all', auth, '{}')
    assert.strictEqual(r.status, 200)
    await settle(app)
    assert.deepStrictEqual(controller.calls, [
      'stop Cloudflared', 'stop KeepAvailable', 'stop FarmGate', 'stop GadsProvider', 'stop GadsHub',
      'start MongoDB', 'start GadsHub', 'start GadsProvider', 'start FarmGate', 'start KeepAvailable', 'start Cloudflared'])
  })
})

test('POST /start-provider, /restart-provider, /restart-cloudflare touch only their own services', async () => {
  await withApp({}, async ({ app, port, controller }) => {
    assert.strictEqual((await request(port, 'POST', '/start-provider', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(controller.calls.splice(0), ['start GadsProvider', 'start FarmGate'])

    assert.strictEqual((await request(port, 'POST', '/restart-provider', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(controller.calls.splice(0), ['stop GadsProvider', 'start GadsProvider', 'start FarmGate'])

    assert.strictEqual((await request(port, 'POST', '/restart-cloudflare', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(controller.calls.splice(0), ['stop Cloudflared', 'start Cloudflared'])
  })
})

test('409 while an action is in progress; status says so; free again afterwards', async () => {
  await withApp({ hold: true }, async ({ app, port, release }) => {
    const first = await request(port, 'POST', '/restart-provider', auth)
    assert.strictEqual(first.status, 200)
    const second = await request(port, 'POST', '/start-all', auth)
    assert.strictEqual(second.status, 409)
    assert.deepStrictEqual(second.json, { error: 'Action already in progress' })
    const st = await request(port, 'GET', '/status', auth)
    assert.strictEqual(st.json.action_in_progress, true)
    release()
    await settle(app)
    assert.strictEqual((await request(port, 'GET', '/status', auth)).json.action_in_progress, false)
    assert.strictEqual((await request(port, 'POST', '/start-provider', auth)).status, 200)
    await settle(app)
  })
})

test('a failing action does not leave the service busy', async () => {
  const controller = fakeController()
  controller.stop = async () => { throw new Error('boom') }
  await withApp({ controller }, async ({ app, port }) => {
    assert.strictEqual((await request(port, 'POST', '/restart-provider', auth)).status, 200)
    await settle(app)
    assert.strictEqual(app.isBusy(), false)
  })
})

test('unknown paths and wrong methods -> 404, and run nothing', async () => {
  await withApp({}, async ({ port, controller }) => {
    for (const [m, p] of [['GET', '/'], ['GET', '/restart-all'], ['POST', '/status'], ['POST', '/stop-all'], ['DELETE', '/status'],
      ['POST', '/restart-all/extra'], ['POST', '/__proto__'], ['POST', '/constructor'], ['PUT', '/start-all']]) {
      const r = await request(port, m, p, auth)
      assert.strictEqual(r.status, 404, `${m} ${p}`)
    }
    assert.deepStrictEqual(controller.calls, [])
  })
})

test('an oversized body is cut off and nothing from a body is ever used', async () => {
  await withApp({}, async ({ app, port, controller }) => {
    const r = await request(port, 'POST', '/start-provider', auth, JSON.stringify({ service: 'evil & calc.exe', action: 'stop' }))
    assert.strictEqual(r.status, 200)
    await settle(app)
    assert.deepStrictEqual(controller.calls, ['start GadsProvider', 'start FarmGate'])
    await request(port, 'POST', '/nope', auth, 'x'.repeat(100000)).catch(() => {})
  })
})

test('the real controller only ever runs sc.exe with fixed service names (no shell)', () => {
  const src = fs.readFileSync(SERVER, 'utf8')
  assert.match(src, /execFile\('sc\.exe'/)
  assert.match(src, /const \{ execFile \} = require\('child_process'\)/)
  assert.doesNotMatch(src, /execSync|spawn|shell:\s*true/)
  for (const name of Object.values(SERVICES)) assert.match(name, /^[A-Za-z]+$/)
})
