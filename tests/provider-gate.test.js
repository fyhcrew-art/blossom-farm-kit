'use strict'
const test = require('node:test')
const assert = require('node:assert')
const http = require('node:http')
const net = require('node:net')
const path = require('node:path')

const { createGate, tokenFrom, routedPath, withoutToken, HOST } = require(path.join(__dirname, '..', 'services', 'provider-gate.js'))

const GOOD = 'good-token'

const listen = server => new Promise(r => server.listen(0, '127.0.0.1', () => r(server.address().port)))
const close = server => new Promise(r => { if (server.closeAllConnections) server.closeAllConnections(); server.close(() => r()) })

/** A fake hub (only /user-info) and a fake, unauthenticated provider. */
async function world(fn, opts) {
  const seen = { hub: 0, provider: [] }
  const hub = http.createServer((req, res) => {
    seen.hub++
    if (opts && opts.hubStatus) { res.writeHead(opts.hubStatus); return res.end() }
    const ok = req.url === '/user-info' && req.headers.authorization === `Bearer ${GOOD}`
    res.writeHead(ok ? 200 : 401, { 'Content-Type': 'application/json' })
    res.end(ok ? '{"username":"blossom"}' : '{"error":"invalid or expired token"}')
  })
  const provider = http.createServer((req, res) => {
    const chunks = []
    req.on('data', c => chunks.push(c))
    req.on('end', () => {
      seen.provider.push(`${req.method} ${req.url}`)
      res.writeHead(200, { 'Content-Type': 'application/json', 'X-From': 'provider' })
      res.end(JSON.stringify({ path: req.url, method: req.method, body: Buffer.concat(chunks).toString() }))
    })
  })
  provider.on('upgrade', (req, socket) => {
    seen.provider.push(`UPGRADE ${req.url}`)
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
    socket.on('data', d => socket.write(d)) // echo
    socket.on('end', () => socket.destroy())
    socket.on('error', () => {})
  })
  const hubPort = await listen(hub)
  const upstreamPort = await listen(provider)
  let t = 1000
  const gate = createGate({ hubPort, upstreamPort, log: () => {}, now: () => t })
  const port = await new Promise(r => gate.listen(0, () => r(gate.server.address().port)))
  try { await fn({ port, seen, gate, advance: ms => { t += ms }, provider, hub }) } finally {
    await close(gate.server); await close(hub); await close(provider)
  }
}

function get(port, urlPath, headers, method, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: urlPath, method: method || 'GET', headers: headers || {} }, res => {
      const chunks = []
      res.on('data', c => chunks.push(c))
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString() }))
    })
    req.on('error', reject)
    if (body) req.write(body)
    req.end()
  })
}

function upgrade(port, urlPath, headers) {
  return new Promise((resolve, reject) => {
    const s = net.connect(port, '127.0.0.1', () => {
      let raw = `GET ${urlPath} HTTP/1.1\r\nHost: farm-provider.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n`
      for (const k of Object.keys(headers || {})) raw += `${k}: ${headers[k]}\r\n`
      s.write(raw + '\r\n')
    })
    let buf = ''
    s.on('data', d => {
      buf += d.toString()
      if (buf.includes('\r\n\r\n') && !s.headDone) { s.headDone = true; resolve({ socket: s, head: buf.split('\r\n')[0], read: () => buf }) }
    })
    s.on('error', reject)
    s.on('close', () => { if (!s.headDone) resolve({ socket: s, head: buf.split('\r\n')[0], read: () => buf }) })
  })
}

test('tokenFrom: header first, then the token query parameter', () => {
  assert.strictEqual(tokenFrom({ headers: { authorization: 'Bearer abc' }, url: '/x?token=zzz' }), 'abc')
  assert.strictEqual(tokenFrom({ headers: {}, url: '/device/1/ios-webrtc?token=q%2B1' }), 'q+1')
  assert.strictEqual(tokenFrom({ headers: { authorization: 'Basic abc' }, url: '/x' }), '')
  assert.strictEqual(tokenFrom({ headers: {}, url: '/x' }), '')
})

test('binds to 127.0.0.1 only', async () => {
  await world(async ({ gate }) => {
    assert.strictEqual(HOST, '127.0.0.1')
    assert.strictEqual(gate.server.address().address, '127.0.0.1')
  })
})

test('without a token, or with one the hub refuses, nothing reaches the provider', async () => {
  await world(async ({ port, seen }) => {
    for (const p of ['/devices', '/info', '/', '/device/abc/screenshot', '/device/abc/info']) {
      assert.strictEqual((await get(port, p)).status, 401, p)
      assert.strictEqual((await get(port, p, { Authorization: 'Bearer stolen' })).status, 401, p)
      assert.strictEqual((await get(port, p + '?token=stolen')).status, 401, p)
    }
    assert.strictEqual((await get(port, '/device/abc/tap', {}, 'POST', '{"x":1,"y":1}')).status, 401)
    assert.deepStrictEqual(seen.provider, [])
  })
})

test('with a token the hub accepts, the request is passed on; the token never reaches the provider\'s URL', async () => {
  await world(async ({ port, seen }) => {
    const r = await get(port, '/device/abc/tap', { Authorization: `Bearer ${GOOD}`, 'Content-Type': 'application/json' }, 'POST', '{"x":10,"y":20}')
    assert.strictEqual(r.status, 200)
    assert.strictEqual(r.headers['x-from'], 'provider')
    assert.deepStrictEqual(JSON.parse(r.text), { path: '/device/abc/tap', method: 'POST', body: '{"x":10,"y":20}' })
    assert.strictEqual((await get(port, `/device/abc/info?token=${GOOD}`)).status, 200)
    assert.strictEqual((await get(port, `/device/abc/files?path=%2Ftmp%2Fa+b&token=${GOOD}&x=1`)).status, 200)
    assert.strictEqual((await get(port, `/device/abc/info?%74oken=${GOOD}`)).status, 200)
    assert.deepStrictEqual(seen.provider, ['POST /device/abc/tap', 'GET /device/abc/info', 'GET /device/abc/files?path=%2Ftmp%2Fa+b&x=1', 'GET /device/abc/info'])
    for (const line of seen.provider) assert.ok(!line.includes(GOOD), 'the provider must not see (and log) the token')
  })
})

test('withoutToken: removes only the token parameter and keeps the rest byte for byte', () => {
  assert.strictEqual(withoutToken('/x'), '/x')
  assert.strictEqual(withoutToken('/x?token=abc'), '/x')
  assert.strictEqual(withoutToken('/x?a=1&token=abc&b=%20z'), '/x?a=1&b=%20z')
  assert.strictEqual(withoutToken('/x?token=abc&token=def&c'), '/x?c')
  assert.strictEqual(withoutToken('/x?%74oken=abc&tokens=1&Token=2'), '/x?tokens=1&Token=2')
  assert.strictEqual(withoutToken('/x?a=%zz&token=abc'), '/x?a=%zz')
})

test('routedPath: the decoded path the provider routes on, or null for anything ambiguous', () => {
  assert.strictEqual(routedPath('/'), '/')
  assert.strictEqual(routedPath('/devices?x=%2f'), '/devices')
  assert.strictEqual(routedPath('/device/00008030-000A1B2C3D4E5F6A/info'), '/device/00008030-000A1B2C3D4E5F6A/info')
  assert.strictEqual(routedPath('/%64ebug/pprof/heap'), '/debug/pprof/heap')
  assert.strictEqual(routedPath('//debug//pprof/'), '/debug/pprof')
  assert.strictEqual(routedPath('/device/x/a%20b'), '/device/x/a b')
  for (const bad of ['', '*', 'http://127.0.0.1:10001/debug/pprof/', 'debug', '/a%2fb', '/a%2Fb', '/a%5cb', '/a\\b', '/a%25b', '/a%00b', '/a%0ab',
    '/a%7fb', '/a%zzb', '/a%', '/a%ff', '/a/../debug', '/a/./b', '/%2e%2e/debug', '/a/%2e/b']) {
    assert.strictEqual(routedPath(bad), null, JSON.stringify(bad))
  }
})

test('percent-encoded spellings of blocked paths are not passed on either, with a valid token', async () => {
  await world(async ({ port, seen }) => {
    const h = { Authorization: `Bearer ${GOOD}` }
    for (const p of ['/%64ebug/pprof/heap', '/%44EBUG/pprof/heap', '/d%65bug/pprof/profile?seconds=30', '/%64%65%62%75%67', '//debug/pprof/',
      '/device/x/%61ppium-plugin/register', '/device/x/appium%2Dplugin/register', '/device/x/APPIUM-%70lugin']) {
      assert.strictEqual((await get(port, p, h)).status, 404, p)
    }
    for (const p of ['/%2e%2e/debug/pprof/', '/device/x/..%2fdebug', '/device/x%2fappium-plugin/y', '/a%5cdebug', '/%25%36%34ebug', '/a%zz']) {
      assert.strictEqual((await get(port, p, h)).status, 400, p)
    }
    assert.match((await upgrade(port, `/%64ebug/pprof/?token=${GOOD}`)).head, /404/)
    assert.match((await upgrade(port, `/device/x/%61ppium-plugin/ws?token=${GOOD}`)).head, /404/)
    assert.match((await upgrade(port, `/device/x/..%2f..%2fdebug?token=${GOOD}`)).head, /400/)
    assert.deepStrictEqual(seen.provider, [])
  })
})

test('profiling and local-helper endpoints are never passed on, even with a valid token', async () => {
  await world(async ({ port, seen }) => {
    for (const p of ['/debug/pprof/', '/debug/pprof/heap', '/DEBUG/pprof/cmdline', '/device/abc/appium-plugin/register']) {
      assert.strictEqual((await get(port, p, { Authorization: `Bearer ${GOOD}` })).status, 404, p)
    }
    assert.deepStrictEqual(seen.provider, [])
  })
})

test('the hub answer is cached briefly, and asked again afterwards', async () => {
  await world(async ({ port, seen, advance }) => {
    const h = { Authorization: `Bearer ${GOOD}` }
    await get(port, '/info', h); await get(port, '/info', h); await get(port, '/info', h)
    assert.strictEqual(seen.hub, 1)
    advance(31000)
    await get(port, '/info', h)
    assert.strictEqual(seen.hub, 2)
    await get(port, '/info', { Authorization: 'Bearer bad' }); await get(port, '/info', { Authorization: 'Bearer bad' })
    assert.strictEqual(seen.hub, 3)
    advance(6000)
    await get(port, '/info', { Authorization: 'Bearer bad' })
    assert.strictEqual(seen.hub, 4)
  })
})

test('when the hub cannot be asked the gate fails closed with 503', async () => {
  await world(async ({ port, seen }) => {
    assert.strictEqual((await get(port, '/devices', { Authorization: `Bearer ${GOOD}` })).status, 503)
    assert.deepStrictEqual(seen.provider, [])
  }, { hubStatus: 500 })
})

test('when the provider is down an accepted request gets 502', async () => {
  await world(async ({ port, provider }) => {
    await close(provider)
    assert.strictEqual((await get(port, '/info', { Authorization: `Bearer ${GOOD}` })).status, 502)
  })
})

test('WebSocket upgrade: refused without a valid token', async () => {
  await world(async ({ port, seen }) => {
    assert.match((await upgrade(port, '/device/abc/ios-webrtc')).head, /401/)
    assert.match((await upgrade(port, '/device/abc/ios-webrtc?token=stolen')).head, /401/)
    assert.match((await upgrade(port, `/debug/pprof/?token=${GOOD}`)).head, /404/)
    assert.deepStrictEqual(seen.provider, [])
  })
})

test('WebSocket upgrade: passed through both ways with the token in the query string', async () => {
  await world(async ({ port, seen, gate }) => {
    const c = await upgrade(port, `/device/abc/ios-webrtc?token=${GOOD}`)
    assert.match(c.head, /101/)
    c.socket.write('hello-through-the-gate')
    for (let i = 0; i < 100 && !c.read().includes('hello-through-the-gate'); i++) await new Promise(r => setTimeout(r, 10))
    assert.ok(c.read().includes('hello-through-the-gate'))
    c.socket.destroy()
    assert.deepStrictEqual(seen.provider, ['UPGRADE /device/abc/ios-webrtc'])
    // the gate must not keep the connection once the browser has gone
    let left = 1
    for (let i = 0; i < 100 && left; i++) {
      await new Promise(r => setTimeout(r, 10))
      left = await new Promise(r => gate.server.getConnections((e, n) => r(n)))
    }
    assert.strictEqual(left, 0)
  })
})
