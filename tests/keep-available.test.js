'use strict'
// Tests of services/keep-available.sh (macOS) against a stand-in hub.
// Run with:  node --test tests/keep-available.test.js
// Needs bash and curl; skipped on Windows, where keep-available.ps1 is used.
const test = require('node:test')
const assert = require('node:assert')
const http = require('node:http')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn, execFileSync } = require('node:child_process')

const SCRIPT = path.join(__dirname, '..', 'services', 'keep-available.sh')
const skip = process.platform === 'win32' ? 'keep-available.sh is the macOS script' : false
const PASSWORD = 'pw-"quoted"\\and-$pecial'

/** A hub that knows one user, two workspaces, and streams a line every 200 ms. */
function fakeHub() {
  const seen = { logins: [], workspaceCalls: [], streams: [], open: new Set() }
  const server = http.createServer((req, res) => {
    let body = ''
    req.on('data', d => { body += d }).on('end', () => {
      const url = new URL(req.url, 'http://x')
      if (req.method === 'POST' && url.pathname === '/authenticate') {
        let json = {}
        try { json = JSON.parse(body) } catch (_) { /* refused below */ }
        seen.logins.push({ json, contentType: req.headers['content-type'] })
        if (json.username !== 'farm-keepalive' || json.password !== PASSWORD) { res.writeHead(401); return res.end('{}') }
        res.writeHead(200, { 'Content-Type': 'application/json' })
        return res.end(JSON.stringify({ result: { access_token: 'token-123' } }))
      }
      if (req.headers.authorization !== 'Bearer token-123') { res.writeHead(401); return res.end('{}') }
      if (url.pathname === '/workspaces') {
        seen.workspaceCalls.push(req.url)
        res.writeHead(200, { 'Content-Type': 'application/json' })
        return res.end(JSON.stringify({ result: { workspaces: [{ id: 'ws-1', name: 'Default' }, { id: 'ws-2', name: 'Second' }], total: 2 } }))
      }
      if (url.pathname === '/available-devices') {
        seen.streams.push(url.searchParams.get('workspaceId'))
        res.writeHead(200, { 'Content-Type': 'text/event-stream' })
        const timer = setInterval(() => res.write('data: []\n\n'), 200)
        seen.open.add(res)
        req.on('close', () => { clearInterval(timer); seen.open.delete(res) })
        return
      }
      res.writeHead(404); res.end('{}')
    })
  })
  return { server, seen }
}

const waitFor = async (what, ms) => {
  for (let waited = 0; waited < ms; waited += 50) {
    if (what()) return true
    await new Promise(r => setTimeout(r, 50))
  }
  return what()
}

test('keep-available.sh: signs in, subscribes to every workspace, keeps the login off every command line, reconnects', { skip }, async () => {
  const hub = fakeHub()
  await new Promise(r => hub.server.listen(0, '127.0.0.1', r))
  const port = hub.server.address().port
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keep-available-'))
  const config = path.join(dir, 'keep-available.json')
  fs.writeFileSync(config, JSON.stringify({ hubUrl: `http://127.0.0.1:${port}`, username: 'farm-keepalive', password: PASSWORD }, null, 2), { mode: 0o600 })
  const child = spawn('bash', [SCRIPT, config], { env: { ...process.env, TMPDIR: dir }, stdio: ['ignore', 'pipe', 'pipe'] })
  let out = ''
  child.stdout.on('data', d => { out += d })
  child.stderr.on('data', d => { out += d })
  try {
    assert.ok(await waitFor(() => hub.seen.open.size === 2, 15000), `two streams expected, log:\n${out}`)
    assert.deepStrictEqual(hub.seen.logins[0].json, { username: 'farm-keepalive', password: PASSWORD }, 'the password arrives intact, quotes and backslashes included')
    assert.match(hub.seen.logins[0].contentType, /application\/json/)
    assert.deepStrictEqual(hub.seen.workspaceCalls, ['/workspaces?page=1&limit=100'])
    assert.deepStrictEqual(hub.seen.streams.slice().sort(), ['ws-1', 'ws-2'])
    assert.match(out, /subscribed to 2 workspace\(s\)/)

    // Nothing secret on any command line: not the password, not the token.
    const commandLines = execFileSync('ps', ['-A', '-o', 'args='], { encoding: 'utf8' })
    assert.ok(!commandLines.includes('token-123'), 'the hub token must not be in a process list')
    assert.ok(!commandLines.includes('pw-"quoted"'), 'the password must not be in a process list')
    assert.ok(!out.includes('token-123') && !out.includes('quoted'), 'and not in the log')

    // The hub closes the streams: the script notices and subscribes again.
    for (const res of hub.seen.open) res.destroy()
    assert.ok(await waitFor(() => hub.seen.logins.length >= 2 && hub.seen.open.size === 2, 20000), `a new subscription expected, log:\n${out}`)
    assert.match(out, /the hub closed a stream, reconnecting/)
  } finally {
    child.kill('SIGTERM')
    await new Promise(r => child.on('exit', r))
    for (const res of hub.seen.open) res.destroy()
    await new Promise(r => hub.server.close(r))
    assert.deepStrictEqual(fs.readdirSync(dir).filter(n => n.startsWith('keep-available.') && n !== 'keep-available.json'), [], 'its temporary folder is removed when it stops')
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('keep-available.sh: a hub that refuses the login is retried with a growing pause, and nothing is subscribed', { skip }, async () => {
  const hub = fakeHub()
  await new Promise(r => hub.server.listen(0, '127.0.0.1', r))
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keep-available-'))
  const config = path.join(dir, 'keep-available.json')
  fs.writeFileSync(config, JSON.stringify({ hubUrl: `http://127.0.0.1:${hub.server.address().port}`, username: 'farm-keepalive', password: 'wrong' }))
  const child = spawn('bash', [SCRIPT, config], { env: { ...process.env, TMPDIR: dir }, stdio: ['ignore', 'pipe', 'pipe'] })
  let out = ''
  child.stdout.on('data', d => { out += d })
  try {
    assert.ok(await waitFor(() => hub.seen.logins.length >= 2, 15000), `a second attempt expected, log:\n${out}`)
    assert.strictEqual(hub.seen.streams.length, 0)
    assert.match(out, /the hub refused the login/)
    assert.ok(!out.includes('wrong'), 'the password is not logged')
  } finally {
    child.kill('SIGTERM')
    await new Promise(r => child.on('exit', r))
    await new Promise(r => hub.server.close(r))
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
