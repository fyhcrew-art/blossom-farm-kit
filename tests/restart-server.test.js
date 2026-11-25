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
const { createApp, loadSecret, safeEqual, scController, launchctlController, controllerFor, servicesFor, SERVICES, MACOS_SERVICES, HOST } = require(SERVER)

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
  // The Windows names unless a test asks otherwise: these tests must give the
  // same result on every system they run on.
  const app = createApp({
    secret: SECRET, controller, services: options.services || SERVICES, log: () => {}, replyGraceMs: 0,
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

/**
 * A controller that behaves like the Windows service manager with nssm
 * services: "stop" only requests the stop (the service stays STOP_PENDING for
 * a number of state queries), the hub cannot be stopped while a service that
 * depends on it is not fully stopped (1051), and a service that is still
 * stopping cannot be started (1056).
 */
function slowController(pendingPolls) {
  const state = {}
  for (const name of Object.values(SERVICES)) state[name] = 'running'
  const pending = {}
  const calls = []
  const dependents = [SERVICES.provider, SERVICES.keep_available]
  const tick = name => { if (state[name] === 'stopping' && --pending[name] <= 0) state[name] = 'stopped' }
  return {
    calls, state,
    isRunning: async name => state[name] === 'running',
    isStopped: async name => { tick(name); return state[name] === 'stopped' },
    start: async name => {
      if (state[name] === 'stopping') { calls.push(`start ${name} -> 1056`); return 1056 }
      calls.push(`start ${name}`); state[name] = 'running'; return 0
    },
    stop: async name => {
      if (name === SERVICES.hub && dependents.some(d => state[d] !== 'stopped')) { calls.push(`stop ${name} -> 1051`); return 1051 }
      if (state[name] === 'stopped') { calls.push(`stop ${name} -> 1062`); return 1062 }
      calls.push(`stop ${name}`); state[name] = 'stopping'; pending[name] = pendingPolls; return 0
    },
  }
}

test('POST /restart-all waits for every dependent service to be stopped before it stops the hub', async () => {
  const controller = slowController(4)
  await withApp({ controller }, async ({ app, port }) => {
    assert.strictEqual((await request(port, 'POST', '/restart-all', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(controller.calls, [
      'stop Cloudflared', 'stop KeepAvailable', 'stop FarmGate', 'stop GadsProvider', 'stop GadsHub',
      'start MongoDB', 'start GadsHub', 'start GadsProvider', 'start FarmGate', 'start KeepAvailable', 'start Cloudflared'])
    for (const name of Object.values(SERVICES)) assert.strictEqual(controller.state[name], 'running', name)
  })
})

test('POST /restart-provider does not start the provider while it is still stopping', async () => {
  const controller = slowController(6)
  await withApp({ controller }, async ({ app, port }) => {
    assert.strictEqual((await request(port, 'POST', '/restart-provider', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(controller.calls, ['stop GadsProvider', 'start GadsProvider', 'start FarmGate'])
    assert.strictEqual(controller.state[SERVICES.provider], 'running')
  })
})

test('a service that never stops is given up after the timeout and everything is started again', async () => {
  const controller = slowController(1)
  const realStop = controller.stop
  controller.stop = async name => { if (name === SERVICES.hub) { controller.calls.push('stop GadsHub (hangs)'); return 0 } return realStop(name) }
  const logged = []
  const app = createApp({ secret: SECRET, controller, services: SERVICES, log: m => logged.push(m), replyGraceMs: 0, wait: async () => {}, stopTimeoutMs: 2000 })
  await new Promise(r => app.listen(0, r))
  try {
    assert.strictEqual((await request(app.server.address().port, 'POST', '/restart-all', auth)).status, 200)
    await settle(app)
    assert.strictEqual(controller.calls.filter(c => c === 'stop GadsHub (hangs)').length, 2, 'the hub stop is retried once')
    assert.ok(logged.some(m => /GadsHub could NOT be stopped/.test(m)))
    assert.deepStrictEqual(controller.calls.slice(-6), ['start MongoDB', 'start GadsHub', 'start GadsProvider', 'start FarmGate', 'start KeepAvailable', 'start Cloudflared'])
    assert.strictEqual(app.isBusy(), false)
  } finally { await new Promise(r => app.server.close(r)) }
})

test('the real controller reads "stopped" from the state number, and treats a missing service as stopped', () => {
  const src = fs.readFileSync(SERVER, 'utf8')
  assert.match(src, /1\\s\+STOPPED/)
  assert.match(src, /1060/)
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

// ---------------------------------------------------------------------------
// The service controllers. Their program (sc.exe, launchctl) is replaced by a
// stand-in that records every call; nothing is started or stopped for real.
// ---------------------------------------------------------------------------

test('servicesFor and controllerFor choose by system: launchd on macOS, the Windows service manager otherwise', async () => {
  assert.strictEqual(servicesFor('darwin'), MACOS_SERVICES)
  assert.strictEqual(servicesFor('win32'), SERVICES)
  assert.strictEqual(servicesFor('linux'), SERVICES)
  assert.deepStrictEqual(Object.keys(MACOS_SERVICES), Object.keys(SERVICES), 'the same six programs on both systems')
  for (const name of Object.values(MACOS_SERVICES)) assert.match(name, /^blossom-farm\.[a-z]+(-[a-z]+)*$/)
  const calls = []
  const run = async args => { calls.push(args.join(' ')); return { code: 0, out: '' } }
  await controllerFor('darwin', run).stop('blossom-farm.hub')
  await controllerFor('win32', run).stop('GadsHub')
  assert.deepStrictEqual(calls, ['bootout system/blossom-farm.hub', 'stop GadsHub'])
})

test('sc controller: reads the state number, treats a missing service as stopped, runs fixed arguments', async () => {
  const calls = []
  const answers = {
    'query GadsHub': { code: 0, out: 'SERVICE_NAME: GadsHub\r\n        STATE              : 4  RUNNING\r\n' },
    'query FarmGate': { code: 0, out: '        ESTADO             : 1  STOPPED\r\n' },
    'query KeepAvailable': { code: 0, out: '        STATE              : 3  STOP_PENDING\r\n' },
    'query Nope': { code: 1060, out: '[SC] EnumQueryServicesStatus:OpenService FAILED 1060:\r\n' },
  }
  const sc = scController(async args => { calls.push(args.join(' ')); return answers[args.join(' ')] || { code: 0, out: '' } })
  assert.strictEqual(await sc.isRunning('GadsHub'), true)
  assert.strictEqual(await sc.isStopped('GadsHub'), false)
  assert.strictEqual(await sc.isRunning('FarmGate'), false)
  assert.strictEqual(await sc.isStopped('FarmGate'), true, 'a translated label does not matter')
  assert.strictEqual(await sc.isStopped('KeepAvailable'), false, 'still stopping is not stopped')
  assert.strictEqual(await sc.isStopped('Nope'), true)
  assert.strictEqual(await sc.start('GadsHub'), 0)
  assert.strictEqual(await sc.stop('GadsHub'), 0)
  assert.deepStrictEqual(calls.slice(-2), ['start GadsHub', 'stop GadsHub'])
})

/** What "launchctl print system/<label>" writes for a daemon (shortened). */
const printOut = state => `system/blossom-farm.hub = {\n\tactive count = 1\n\tpath = /Library/LaunchDaemons/blossom-farm.hub.plist\n\ttype = LaunchDaemon\n\tstate = ${state}\n\n\tprogram = /bin/bash\n\tpid = 412\n}\n`
const NOT_FOUND = { code: 113, out: 'Bad request.\nCould not find service "blossom-farm.hub" in domain for system\n' }

test('launchctl controller: running, not running and not loaded', async () => {
  let answer = { code: 0, out: printOut('running') }
  const calls = []
  const asked = []
  let command = '/opt/farm/bin/GADS hub --host-address=127.0.0.1 --port=10000'
  const lc = launchctlController(async args => { calls.push(args.join(' ')); return answer }, async pid => { asked.push(pid); return command })
  assert.strictEqual(await lc.isRunning('blossom-farm.hub'), true)
  assert.deepStrictEqual(asked, ['412'], 'the process launchd names is the one that is looked at')
  assert.strictEqual(await lc.isStopped('blossom-farm.hub'), false)
  // launchd says "running" while the wrapper still waits for MongoDB: that is not the hub
  command = '/bin/bash /opt/farm/services/farm-run.sh --log /opt/farm/logs/hub.log --wait 27017 -- /opt/farm/bin/GADS hub'
  assert.strictEqual(await lc.isRunning('blossom-farm.hub'), false, 'the wrapper waiting for a port is not the program')
  command = ''
  assert.strictEqual(await lc.isRunning('blossom-farm.hub'), false, 'a process that is gone is not running')
  command = '/opt/farm/bin/GADS hub'
  answer = { code: 0, out: 'system/blossom-farm.hub = {\n\tstate = running\n}\n' }
  assert.strictEqual(await lc.isRunning('blossom-farm.hub'), true, 'without a process number, the state launchd gives is taken')
  answer = { code: 0, out: printOut('not running') }
  assert.strictEqual(await lc.isRunning('blossom-farm.hub'), false, '"not running" must not read as running')
  assert.strictEqual(await lc.isStopped('blossom-farm.hub'), false, 'launchd still knows it, so it may not be loaded again yet')
  answer = NOT_FOUND
  assert.strictEqual(await lc.isRunning('blossom-farm.hub'), false)
  assert.strictEqual(await lc.isStopped('blossom-farm.hub'), true)
  assert.ok(calls.every(c => c === 'print system/blossom-farm.hub'))
})

test('launchctl controller: start loads the property list when launchd does not know the service, then starts it', async () => {
  const calls = []
  let loaded = false
  const lc = launchctlController(async args => {
    calls.push(args.join(' '))
    if (args[0] === 'print') return loaded ? { code: 0, out: printOut('running') } : NOT_FOUND
    if (args[0] === 'bootstrap') { loaded = true; return { code: 0, out: '' } }
    return { code: 0, out: '' }
  })
  assert.strictEqual(await lc.start('blossom-farm.hub'), 0)
  assert.deepStrictEqual(calls, ['print system/blossom-farm.hub', 'bootstrap system /Library/LaunchDaemons/blossom-farm.hub.plist', 'kickstart system/blossom-farm.hub'])
  calls.length = 0
  assert.strictEqual(await lc.start('blossom-farm.hub'), 0)
  assert.deepStrictEqual(calls, ['print system/blossom-farm.hub', 'kickstart system/blossom-farm.hub'], 'already loaded: no second bootstrap')
  calls.length = 0
  assert.strictEqual(await lc.stop('blossom-farm.hub'), 0)
  assert.deepStrictEqual(calls, ['bootout system/blossom-farm.hub'])
})

test('launchctl controller: a property list that cannot be loaded is reported, and nothing is started', async () => {
  const calls = []
  const lc = launchctlController(async args => {
    calls.push(args[0])
    if (args[0] === 'print') return NOT_FOUND
    if (args[0] === 'bootstrap') return { code: 5, out: 'Bootstrap failed: 5: Input/output error\n' }
    return { code: 0, out: '' }
  })
  assert.strictEqual(await lc.start('blossom-farm.hub'), 5)
  assert.deepStrictEqual(calls, ['print', 'bootstrap'])
})

/**
 * A stand-in for launchctl that behaves like launchd: bootout only begins the
 * removal (the service stays known for a number of "print" calls), bootstrap
 * fails while the service is still known (as launchd does, with error 5 or
 * 37), and a bootstrapped service runs at once (RunAtLoad).
 */
function fakeLaunchd(pendingPolls) {
  const state = {}
  for (const name of Object.values(MACOS_SERVICES)) state[name] = 'running'
  const pending = {}
  const calls = []
  const label = t => String(t).replace(/^system\//, '')
  const run = async args => {
    const [verb, a, b] = args
    if (verb === 'print') {
      const name = label(a)
      if (state[name] === 'leaving' && --pending[name] <= 0) state[name] = 'gone'
      if (!state[name] || state[name] === 'gone') return { code: 113, out: `Could not find service "${name}" in domain for system\n` }
      return { code: 0, out: `system/${name} = {\n\tstate = ${state[name] === 'running' ? 'running' : 'not running'}\n}\n` }
    }
    if (verb === 'bootout') {
      const name = label(a)
      if (state[name] === 'gone') { calls.push(`bootout ${name} -> 113`); return { code: 113, out: '' } }
      calls.push(`bootout ${name}`); state[name] = 'leaving'; pending[name] = pendingPolls
      return { code: 0, out: '' }
    }
    if (verb === 'bootstrap') {
      const name = String(b).replace(/^\/Library\/LaunchDaemons\//, '').replace(/\.plist$/, '')
      assert.strictEqual(a, 'system')
      assert.match(String(b), /^\/Library\/LaunchDaemons\/blossom-farm\.[a-z-]+\.plist$/)
      if (state[name] !== 'gone') { calls.push(`bootstrap ${name} -> 5`); return { code: 5, out: 'Bootstrap failed: 5: Input/output error\n' } }
      calls.push(`bootstrap ${name}`); state[name] = 'running'
      return { code: 0, out: '' }
    }
    if (verb === 'kickstart') { calls.push(`kickstart ${label(a)}`); return { code: 0, out: '' } }
    throw new Error(`unexpected launchctl call: ${args.join(' ')}`)
  }
  return { run, calls, state }
}

async function withMacApp(launchd, fn) {
  const app = createApp({ secret: SECRET, platform: 'darwin', run: launchd.run, log: () => {}, replyGraceMs: 0, wait: async () => {} })
  await new Promise(r => app.listen(0, r))
  try { await fn({ app, port: app.server.address().port }) } finally { await new Promise(r => app.server.close(r)) }
}

test('macOS: GET /status answers the same six booleans, read from launchd', async () => {
  const launchd = fakeLaunchd(1)
  await withMacApp(launchd, async ({ port }) => {
    let r = await request(port, 'GET', '/status', auth)
    assert.strictEqual(r.status, 200)
    assert.deepStrictEqual(r.json, { hub: true, provider: true, cloudflare: true, keep_available: true, mongodb: true, action_in_progress: false })
    launchd.state[MACOS_SERVICES.gate] = 'gone'
    launchd.state[MACOS_SERVICES.cloudflare] = 'stopped'
    r = await request(port, 'GET', '/status', auth)
    assert.deepStrictEqual(r.json, { hub: true, provider: false, cloudflare: false, keep_available: true, mongodb: true, action_in_progress: false })
    assert.strictEqual((await request(port, 'GET', '/status')).status, 401)
  })
})

test('macOS: POST /restart-all takes every service out of launchd in order, waits, and loads them again; MongoDB is not stopped', async () => {
  const launchd = fakeLaunchd(4)
  await withMacApp(launchd, async ({ app, port }) => {
    const r = await request(port, 'POST', '/restart-all', auth)
    assert.strictEqual(r.status, 200)
    assert.deepStrictEqual(r.json, { ok: true, message: 'Restarting all services...' })
    await settle(app)
    assert.deepStrictEqual(launchd.calls, [
      'bootout blossom-farm.cloudflared', 'bootout blossom-farm.keep-available', 'bootout blossom-farm.gate', 'bootout blossom-farm.provider', 'bootout blossom-farm.hub',
      'kickstart blossom-farm.mongodb',
      'bootstrap blossom-farm.hub', 'kickstart blossom-farm.hub',
      'bootstrap blossom-farm.provider', 'kickstart blossom-farm.provider',
      'bootstrap blossom-farm.gate', 'kickstart blossom-farm.gate',
      'bootstrap blossom-farm.keep-available', 'kickstart blossom-farm.keep-available',
      'bootstrap blossom-farm.cloudflared', 'kickstart blossom-farm.cloudflared'])
    for (const name of Object.values(MACOS_SERVICES)) assert.strictEqual(launchd.state[name], 'running', name)
  })
})

test('macOS: /restart-provider, /start-provider and /restart-cloudflare touch only their own services', async () => {
  const launchd = fakeLaunchd(3)
  await withMacApp(launchd, async ({ app, port }) => {
    assert.strictEqual((await request(port, 'POST', '/restart-provider', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(launchd.calls.splice(0), ['bootout blossom-farm.provider', 'bootstrap blossom-farm.provider', 'kickstart blossom-farm.provider', 'kickstart blossom-farm.gate'])
    assert.strictEqual((await request(port, 'POST', '/start-provider', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(launchd.calls.splice(0), ['kickstart blossom-farm.provider', 'kickstart blossom-farm.gate'])
    assert.strictEqual((await request(port, 'POST', '/restart-cloudflare', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(launchd.calls.splice(0), ['bootout blossom-farm.cloudflared', 'bootstrap blossom-farm.cloudflared', 'kickstart blossom-farm.cloudflared'])
  })
})

test('macOS: /start-all brings back services that launchd no longer knows', async () => {
  const launchd = fakeLaunchd(1)
  for (const name of Object.values(MACOS_SERVICES)) launchd.state[name] = 'gone'
  await withMacApp(launchd, async ({ app, port }) => {
    assert.strictEqual((await request(port, 'POST', '/start-all', auth)).status, 200)
    await settle(app)
    assert.deepStrictEqual(launchd.calls.filter(c => c.startsWith('bootstrap')), [
      'bootstrap blossom-farm.mongodb', 'bootstrap blossom-farm.hub', 'bootstrap blossom-farm.provider',
      'bootstrap blossom-farm.gate', 'bootstrap blossom-farm.keep-available', 'bootstrap blossom-farm.cloudflared'])
    assert.deepStrictEqual((await request(port, 'GET', '/status', auth)).json,
      { hub: true, provider: true, cloudflare: true, keep_available: true, mongodb: true, action_in_progress: false })
  })
})

test('GET /status on macOS: a service whose wrapper still waits for another service is not reported as running', async () => {
  const pids = { 'blossom-farm.mongodb': 11, 'blossom-farm.hub': 12, 'blossom-farm.provider': 13, 'blossom-farm.gate': 14, 'blossom-farm.keep-available': 15, 'blossom-farm.cloudflared': 16 }
  // MongoDB is down: its job has no process; the hub, the provider and keep-available wait in the wrapper
  const run = async args => {
    const name = String(args[1]).replace(/^system\//, '')
    if (name === 'blossom-farm.mongodb') return { code: 0, out: `system/${name} = {\n\tstate = not running\n}\n` }
    return { code: 0, out: `system/${name} = {\n\tstate = running\n\tpid = ${pids[name]}\n}\n` }
  }
  const commandOf = async pid => ([12, 13, 15].includes(Number(pid)) ? '/bin/bash /opt/farm/services/farm-run.sh --log x --wait 10000 -- program' : '/opt/farm/bin/program')
  const app = createApp({ secret: SECRET, platform: 'darwin', run, commandOf, log: () => {}, replyGraceMs: 0, wait: async () => {} })
  await new Promise(r => app.listen(0, r))
  try {
    const r = await request(app.server.address().port, 'GET', '/status', { Authorization: `Bearer ${SECRET}` })
    assert.deepStrictEqual(r.json, { hub: false, provider: false, cloudflare: true, keep_available: false, mongodb: false, action_in_progress: false })
  } finally { await new Promise(r => app.server.close(r)) }
})

test('the macOS controller only ever runs /bin/launchctl and /bin/ps by their full paths, with fixed arguments (no shell)', () => {
  const src = fs.readFileSync(SERVER, 'utf8')
  assert.match(src, /execFile\('\/bin\/launchctl'/)
  assert.match(src, /execFile\('\/bin\/ps', \['-o', 'command=', '-p', String\(pid\)\]/)
  assert.strictEqual((src.match(/execFile\(/g) || []).length, 3, 'three programs are ever run: sc.exe, launchctl and ps')
  assert.doesNotMatch(src, /execSync|spawn|shell:\s*true/)
})
