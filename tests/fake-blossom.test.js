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
    assert.match(r.json.workspace_id, /^[0-9a-f-]{36}$/, 'the workspace is named by an identifier nobody chooses')
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
    // ... and until an admin has, the site stays in use on the addresses that were confirmed:
    // a farm token cannot take its site out of service
    let held = (await flip(fake, 'state', { token })).pairing
    assert.deepStrictEqual([held.confirmed, held.awaiting], [true, true])
    assert.strictEqual(held.confirmedSite.hub_url, site.hub_url, 'the confirmed addresses are untouched')
    assert.strictEqual(held.confirmedSecrets.hub_password, 'pw-2', 'and so are the confirmed credentials')
    assert.strictEqual(held.site.hub_url, 'https://farm-hub.other.io', 'the new ones wait')
    await call(fake, 'GET', '/api/farm/pair/status', { token })
    r = await call(fake, 'GET', '/api/farm/pair/status', { token })
    assert.deepStrictEqual([r.json.state, r.json.needs_confirmation], ['awaiting_confirmation', true])
    // the admin declines the new addresses: the site goes on as it was, the computer stays paired
    await flip(fake, 'reject', { token })
    r = await call(fake, 'GET', '/api/farm/pair/status', { token })
    assert.deepStrictEqual([r.status, r.json.state, r.json.needs_confirmation], [200, 'active', false])
    held = (await flip(fake, 'state', { token })).pairing
    assert.deepStrictEqual([held.confirmed, held.awaiting, held.confirmedSite.hub_url], [true, false, site.hub_url])
    // new addresses again, then the computer goes back to the confirmed ones: nothing is left waiting
    await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: Object.assign({}, moved, { hub_password: 'pw-3' }) } })
    r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: withoutPassword } })
    assert.deepStrictEqual([r.status, r.json.needs_confirmation, r.json.site_changed], [200, false, true])
    held = (await flip(fake, 'state', { token })).pairing
    assert.deepStrictEqual([held.awaiting, held.confirmedSecrets.hub_password], [false, 'pw-2'], 'the password of the confirmed addresses was kept for them')

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

test('a confirmation is bound to the description the admin read', { skip }, async () => {
  const fake = await startFakeBlossom()
  try {
    const token = newToken()
    await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code')).code, farm_token: token, computer } })
    // whoever holds the token sends addresses the admin will recognise ...
    await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site } })
    const shown = await flip(fake, 'pending', { token })
    assert.strictEqual(shown.state, 'awaiting_confirmation')
    assert.strictEqual(shown.pending.hub_url, site.hub_url)
    assert.match(shown.pendingRevision, /^[0-9a-f]{32}$/)
    // ... and swaps them while the admin types the name of the site
    const swapped = Object.assign({}, site, { hub_url: 'https://hub.attacker.example', provider_url: 'https://provider.attacker.example', restart_url: 'https://restart.attacker.example', hub_password: 'his-own', restart_secret: 'his-own' })
    let r = await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: swapped } })
    assert.strictEqual(r.status, 200)
    await call(fake, 'GET', '/api/farm/pair/status', { token })
    r = await call(fake, 'GET', '/api/farm/pair/status', { token })
    assert.strictEqual(r.json.state, 'awaiting_confirmation', 'the state reads the same as when the card was shown')
    // the admin presses Confirm on the card that was read
    r = await call(fake, 'POST', '/__test/confirm', { plain: true, body: { token, label: 'Milan', revision: shown.pendingRevision } })
    assert.deepStrictEqual([r.status, r.json.code], [409, 'pending_changed'])
    let held = (await flip(fake, 'state', { token })).pairing
    assert.deepStrictEqual([held.confirmed, held.state], [false, 'awaiting_confirmation'], 'nothing was confirmed')
    // a change of credentials alone is another revision as well
    const now = await flip(fake, 'pending', { token })
    assert.notStrictEqual(now.pendingRevision, shown.pendingRevision)
    await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: Object.assign({}, swapped, { hub_password: 'another' }) } })
    r = await call(fake, 'POST', '/__test/confirm', { plain: true, body: { token, revision: now.pendingRevision } })
    assert.deepStrictEqual([r.status, r.json.code], [409, 'pending_changed'])
    // sending the same description again is not a change
    const again = await flip(fake, 'pending', { token })
    await call(fake, 'PUT', '/api/farm/pair/site', { token, body: { protocol: 1, site: Object.assign({}, swapped, { hub_password: 'another' }) } })
    assert.strictEqual((await flip(fake, 'pending', { token })).pendingRevision, again.pendingRevision)
    // the revision of what is shown now is accepted
    r = await call(fake, 'POST', '/__test/confirm', { plain: true, body: { token, label: 'Milan', revision: again.pendingRevision } })
    assert.strictEqual(r.status, 200)
    held = (await flip(fake, 'state', { token })).pairing
    assert.deepStrictEqual([held.confirmed, held.confirmedSite.hub_url], [true, 'https://hub.attacker.example'])
  } finally { await fake.close() }
})

test('a site that exists is replaced only when the admin names it, and only after a check that passed', { skip }, async () => {
  const fake = await startFakeBlossom()
  try {
    // the agency has a working, paired site
    const first = newToken()
    await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code')).code, farm_token: first, computer } })
    await call(fake, 'PUT', '/api/farm/pair/site', { token: first, body: { protocol: 1, site } })
    const siteId = (await flip(fake, 'confirm', { token: first, label: 'Milan' })).site_id
    // a new command leaks; a stranger claims it and sends the agency's own host names with a password that is not the hub's
    const stranger = newToken()
    await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code')).code, farm_token: stranger, computer: Object.assign({}, computer, { label: 'FARM-PC' }) } })
    await flip(fake, 'set-check', { ok: false, failed_step: 'signin', detail: 'Hub sign-in: the hub refused the user name or password.' })
    await call(fake, 'PUT', '/api/farm/pair/site', { token: stranger, body: { protocol: 1, site: Object.assign({}, site, { hub_password: 'garbage', restart_secret: 'garbage' }) } })
    const shown = await flip(fake, 'pending', { token: stranger })
    assert.deepStrictEqual(shown.replaces, { id: siteId, label: 'Milan' }, 'the page is told which site has the same hub address')
    assert.strictEqual(shown.check.ok, false)
    // Confirm without naming the site: the server does not pick it by itself
    let r = await call(fake, 'POST', '/__test/confirm', { plain: true, body: { token: stranger, revision: shown.pendingRevision } })
    assert.deepStrictEqual([r.status, r.json.code], [409, 'hub_address_in_use'])
    // Confirm naming the site, with a check that failed: refused
    r = await call(fake, 'POST', '/__test/confirm', { plain: true, body: { token: stranger, revision: shown.pendingRevision, replaceSiteId: siteId } })
    assert.deepStrictEqual([r.status, r.json.code], [409, 'check_required'])
    // the working site and its computer are untouched
    r = await call(fake, 'GET', '/api/farm/pair/status', { token: first })
    assert.deepStrictEqual([r.status, r.json.state], [200, 'active'])
    let held = (await flip(fake, 'state', { token: first })).pairing
    assert.deepStrictEqual([held.revoked, held.confirmedSecrets.hub_password], [null, 'pw-1'])
    // the legitimate case: the owner's new computer, with the hub's real login, and the box ticked
    await flip(fake, 'set-check', { ok: true, devices: 3 })
    const mine = newToken()
    await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code')).code, farm_token: mine, computer } })
    await call(fake, 'PUT', '/api/farm/pair/site', { token: mine, body: { protocol: 1, site: Object.assign({}, site, { hub_password: 'pw-new' }) } })
    const card = await flip(fake, 'pending', { token: mine })
    r = await call(fake, 'POST', '/__test/confirm', { plain: true, body: { token: mine, revision: card.pendingRevision, replaceSiteId: 'not-a-site' } })
    assert.strictEqual(r.status, 404)
    r = await call(fake, 'POST', '/__test/confirm', { plain: true, body: { token: mine, revision: card.pendingRevision, replaceSiteId: siteId } })
    assert.deepStrictEqual([r.status, r.json.site_id], [200, siteId], 'the same site row is kept')
    held = (await flip(fake, 'state', { token: first })).pairing
    assert.deepStrictEqual([held.revoked, held.revokedReason], ['revoked', 'replaced'], 'only now is the earlier computer unpaired')
    r = await call(fake, 'GET', '/api/farm/pair/status', { token: first })
    assert.deepStrictEqual([r.status, r.json.code], [401, 'farm_token_revoked'])
    // a site of another workspace is never offered and cannot be named
    const foreign = (await flip(fake, 'add-site', { workspace: 'Somebody Else', hubUrl: 'https://farm-hub.elsewhere.io' })).site_id
    const t4 = newToken()
    await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code')).code, farm_token: t4, computer } })
    await call(fake, 'PUT', '/api/farm/pair/site', { token: t4, body: { protocol: 1, site: Object.assign({}, site, { hub_url: 'https://farm-hub.elsewhere.io' }) } })
    assert.strictEqual((await flip(fake, 'pending', { token: t4 })).replaces, null)
    r = await call(fake, 'POST', '/__test/confirm', { plain: true, body: { token: t4, replaceSiteId: foreign } })
    assert.strictEqual(r.status, 404)
  } finally { await fake.close() }
})

test('two workspaces with the same name are still two workspaces', { skip }, async () => {
  const fake = await startFakeBlossom()
  try {
    const a = newToken(); const b = newToken()
    let r = await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code', { workspace: 'Agency' })).code, farm_token: a, computer } })
    const real = r.json.workspace_id
    r = await call(fake, 'POST', '/api/farm/pair/claim', { body: { protocol: 1, pairing_code: (await flip(fake, 'new-code', { workspace: 'Agency', workspaceId: '11111111-2222-3333-4444-555555555555' })).code, farm_token: b, computer } })
    assert.deepStrictEqual([r.json.workspace_name, r.json.workspace_id], ['Agency', '11111111-2222-3333-4444-555555555555'])
    assert.notStrictEqual(r.json.workspace_id, real)
    r = await call(fake, 'GET', '/api/farm/pair/status', { token: a })
    assert.strictEqual(r.json.workspace_id, real)
  } finally { await fake.close() }
})
