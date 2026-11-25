'use strict'
// Tests of tests/fake-blossom.js itself: the stand-in must hold to the pairing
// contract, because the pairing tests of both systems are only as good as it.
// Run with:  node --test tests/fake-blossom.test.js
// Needs the openssl program (for the certificate of the run); skipped without it.
const test = require('node:test')
const assert = require('node:assert')
const https = require('node:https')
const http = require('node:http')
const crypto = require('node:crypto')
const fs = require('node:fs')
const { execFileSync } = require('node:child_process')
const { startFakeBlossom, normalizeCode, formatCode, newCode, CODE_RE, TOKEN_RE } = require('./fake-blossom')

let skip = false
try { execFileSync('openssl', ['version'], { stdio: 'ignore' }) } catch (_) {
  if (process.platform !== 'win32') skip = 'the openssl program is not installed'
}

const newToken = () => 'bft_' + crypto.randomBytes(32).toString('base64url')
const computer = { label: 'TEST-PC', platform: 'windows', os_version: 'Windows 10.0', kit_version: '9.9.9' }
const site = { hub_url: 'https://farm-hub.agency.io', provider_url: 'https://farm-provider.agency.io', provider_nickname: 'Provider1', hub_user: 'blossom', hub_password: 'pw-1', restart_url: 'https://farm-restart.agency.io', restart_secret: 'secret-1' }

function call(fake, method, path, { token, body, plain } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL((plain ? fake.controlUrl : fake.origin) + path)
    const headers = { 'Content-Type': 'application/json' }
    if (token) headers.Authorization = 'Bearer ' + token
    const options = { method, hostname: url.hostname, port: url.port, path: url.pathname, headers, ca: fs.readFileSync(fake.certFile), agent: false }
    const req = (plain ? http : https).request(options, res => {
      let text = ''
      res.on('data', d => { text += d }).on('end', () => {
        let json = null
        try { json = JSON.parse(text) } catch (_) { /* not JSON */ }
        resolve({ status: res.statusCode, json, headers: res.headers })
      })
    })
    req.on('error', reject)
    req.end(body === undefined ? undefined : JSON.stringify(body))
  })
}
const flip = (fake, name, body) => call(fake, 'POST', '/__test/' + name, { body: body || {}, plain: true }).then(r => r.json)

test('pairing codes: 100 bits, no look-alike letters, forgiving of how people type them', () => {
  for (let i = 0; i < 200; i++) assert.match(newCode(), CODE_RE)
  assert.strictEqual(newCode().length * 5, 100)
  assert.strictEqual(formatCode('K7QM2XVD9HTR4BWN6CPA'), 'K7QM-2XVD-9HTR-4BWN-6CPA')
  assert.strictEqual(normalizeCode(' k7qm-2xvd 9htr-4bwn-6cpa '), 'K7QM2XVD9HTR4BWN6CPA')
  assert.strictEqual(normalizeCode('oil0'), '0110')
  assert.doesNotMatch('K7QM2XVD9HTR4BWN6CPU', CODE_RE)
  assert.match(newToken(), TOKEN_RE)
})

test('claim: once, idempotent for the same token, refused for another, expired, unknown', { skip }, async () => {
  const fake = await startFakeBlossom()
  try {
    const { code } = await flip(fake, 'new-code', { workspace: 'Agency' })
    const token = newToken()
    const claim = { protocol: 1, pairing_code: code, farm_token: token, computer }
    let r = await call(fake, 'POST', '/api/farm/pair/claim', { body: claim })
    assert.strictEqual(r.status, 200)
    assert.strictEqual(r.json.state, 'installing')
    assert.strictEqual(r.json.workspace_name, 'Agency')
    assert.strictEqual(r.headers['cache-control'], 'no-store')
    assert.ok(!JSON.stringify(r.json).includes(token), 'the answer does not repeat the token')
    const first = r.json.pairing_id
    r = await call(fake, 'POST', '/api/farm/pair/claim', { body: claim })
    assert.strictEqual(r.status, 200, 'the same claim again is the same claim')
    assert.strictEqual(r.json.pairing_id, first)
    r = await call(fake, 'POST', '/api/farm/pair/claim', { body: Object.assign({}, claim, { farm_token: newToken() }) })
    assert.deepStrictEqual([r.status, r.json.code], [409, 'pairing_code_used'])
    assert.strictEqual(typeof r.json.error, 'string')

    const expired = (await flip(fake, 'new-code', { ttlSeconds: -1 })).code
    r = await call(fake, 'POST', '/api/farm/pair/claim', { body: Object.assign({}, claim, { pairing_code: expired, farm_token: newToken() }) })
    assert.deepStrictEqual([r.status, r.json.code], [410, 'pairing_code_expired'])
    r = await call(fake, 'POST', '/api/farm/pair/claim', { body: Object.assign({}, claim, { pairing_code: 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ', farm_token: newToken() }) })
    assert.deepStrictEqual([r.status, r.json.code], [404, 'pairing_code_unknown'])
    for (const bad of [{ protocol: 2 }, { farm_token: 'short' }, { pairing_code: 'nope' }, { computer: { label: '', platform: 'windows' } }, { computer: { label: 'x', platform: 'linux' } }]) {
      r = await call(fake, 'POST', '/api/farm/pair/claim', { body: Object.assign({}, claim, { pairing_code: (await flip(fake, 'new-code')).code, farm_token: newToken() }, bad) })
      assert.deepStrictEqual([r.status, r.json.code], [400, 'bad_request'], JSON.stringify(bad))
      assert.strictEqual(typeof r.json.field, 'string')
    }
    r = await call(fake, 'GET', '/api/farm/pair/claim')
    assert.strictEqual(r.status, 405)
  } finally { await fake.close() }
})

test('the farm token: its own site only, credentials at once, addresses after a confirmation', { skip }, async () => {
  const fake = await startFakeBlossom()
  try {
    const token = newToken()
    await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code')).code, farm_token: token, computer } })
    for (const [method, path] of [['GET', '/api/farm/pair/status'], ['PUT', '/api/farm/pair/site'], ['DELETE', '/api/farm/pair/token']]) {
      for (const bad of [undefined, 'bft_' + 'a'.repeat(43), 'not-a-token']) {
        const r = await call(fake, method, path, { token: bad, body: method === 'PUT' ? { protocol: 1, site } : undefined })
        assert.deepStrictEqual([r.status, r.json.code], [401, 'farm_token_invalid'], method + ' ' + path)
      }
    }
    let r = await call(fake, 'GET', '/api/farm/pair/status', { token })
    assert.strictEqual(r.json.state, 'installing')
    assert.strictEqual(r.json.check, null)

    const { hub_password: _p, ...withoutPassword } = site
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: withoutPassword } })
    assert.deepStrictEqual([r.status, r.json.code, r.json.field], [422, 'credentials_required', 'site.hub_password'])
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: Object.assign({}, site, { hub_url: 'http://farm-hub.agency.io' }) } })
    assert.deepStrictEqual([r.status, r.json.code, r.json.field], [422, 'site_address_refused', 'site.hub_url'])
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: Object.assign({}, site, { hub_url: 'https://farm-hub.agency.io/path' }) } })
    assert.strictEqual(r.json.code, 'site_address_refused')
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1 } })
    assert.deepStrictEqual([r.status, r.json.code], [400, 'bad_request'])

    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site, computer } })
    assert.deepStrictEqual([r.status, r.json.state, r.json.needs_confirmation, r.json.site_changed], [200, 'checking', true, true])
    assert.ok(!/pw-1|secret-1/.test(JSON.stringify(r.json)), 'the answer repeats no secret')
    await call(fake, 'GET', '/api/farm/pair/status', { token })
    r = await call(fake, 'GET', '/api/farm/pair/status', { token })
    assert.deepStrictEqual([r.json.state, r.json.needs_confirmation, r.json.check.ok], ['awaiting_confirmation', true, true])
    assert.ok(!/pw-1|secret-1/.test(JSON.stringify(r.json)))

    await flip(fake, 'confirm', { token, label: 'Milan' })
    r = await call(fake, 'GET', '/api/farm/pair/status', { token })
    assert.deepStrictEqual([r.json.state, r.json.site_label, r.json.needs_confirmation], ['active', 'Milan', false])

    // new credentials for the confirmed addresses: accepted at once
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: Object.assign({}, withoutPassword, { hub_password: 'pw-2', restart_secret: undefined }) } })
    assert.deepStrictEqual([r.status, r.json.needs_confirmation, r.json.site_changed], [200, false, true])
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: withoutPassword } })
    assert.deepStrictEqual([r.status, r.json.site_changed], [200, false], 'the same again changes nothing')
    // another hub: its password is required, and an admin has to look again
    const moved = Object.assign({}, withoutPassword, { hub_url: 'https://farm-hub.other.io' })
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: moved } })
    assert.strictEqual(r.json.code, 'credentials_required')
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: Object.assign({}, moved, { hub_password: 'pw-3' }) } })
    assert.deepStrictEqual([r.status, r.json.needs_confirmation], [200, true])
    assert.strictEqual((await flip(fake, 'state', { token })).pairing.confirmed, false)

    // the computer gives its token up; afterwards it is refused
    r = await call(fake, 'DELETE', '/api/farm/pair/token', { token })
    assert.deepStrictEqual([r.status, r.json], [200, { unpaired: true }])
    r = await call(fake, 'GET', '/api/farm/pair/status', { token })
    assert.deepStrictEqual([r.status, r.json.code], [401, 'farm_token_revoked'])
  } finally { await fake.close() }
})

test('declined, expired, too many wrong codes, and the plain port', { skip }, async () => {
  const fake = await startFakeBlossom()
  try {
    const token = newToken()
    await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code')).code, farm_token: token, computer } })
    await flip(fake, 'reject', { token })
    let r = await call(fake, 'GET', '/api/farm/pair/status', { token })
    assert.strictEqual(r.json.state, 'rejected')
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site } })
    assert.deepStrictEqual([r.status, r.json.code], [401, 'pairing_rejected'])

    const other = newToken()
    await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code')).code, farm_token: other, computer } })
    await flip(fake, 'expire-pairing', { token: other })
    r = await call(fake, 'GET', '/api/farm/pair/status', { token: other })
    assert.strictEqual(r.json.state, 'expired')
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token: other, body: { protocol: 1, site } })
    assert.deepStrictEqual([r.status, r.json.code], [401, 'pairing_expired'])

    await flip(fake, 'limits', { claimFailureLimit: 2 })
    const wrong = () => call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: newCode(), farm_token: newToken(), computer } })
    await wrong(); await wrong()
    r = await wrong()
    assert.deepStrictEqual([r.status, r.json.code, r.headers['retry-after']], [429, 'rate_limited', '1'])

    r = await call(fake, 'GET', '/api/farm/pair/status', { token, plain: true })
    assert.strictEqual(r.status, 400)
    assert.strictEqual((await flip(fake, 'state')).plainApiHits, 1, 'a call on the plain port is counted')
  } finally { await fake.close() }
})
