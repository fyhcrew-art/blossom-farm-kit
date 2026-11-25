'use strict'
// A stand-in for the part of Blossom CRM that a farm computer talks to: the
// pairing API. It keeps everything in memory and follows the contract the
// kit's pairing client is written against:
//
//   POST   /api/farm/pair/claim    pairing code + the computer's farm token
//   PUT    /api/farm/pair/site     (farm token) the site description, or the computer's versions
//   GET    /api/farm/pair/status   (farm token)
//   DELETE /api/farm/pair/token    (farm token) the computer unpairs itself
//
// It also holds to the rules of the admin's side that decide what a farm
// token can bring about (the contract, sections 3.3 and 5):
//   * a confirmed site stays in use, on its confirmed addresses, while new
//     addresses sent by its computer wait for an admin;
//   * a confirmation names the revision of the description the admin read,
//     and is refused when the computer sent another one in the meantime;
//   * a site that exists is only replaced when the admin names it, and only
//     by a computer whose check passed (it proved it has the hub's login).
//
// The API is served over https only, with a certificate made for this run
// (the openssl program is needed for that). A second, plain http port carries
// the switches the tests use (/__test/...): making a code, confirming a
// pairing as the admin would in Blossom, injecting failures, reading what
// arrived. The plain port answers every /api path with 400 and counts the
// call: the kit must never send anything there.
//
// Used three ways:
//   const { startFakeBlossom } = require('./fake-blossom')        (Node tests)
//   node tests/fake-blossom.js --dir <folder> [--static <folder>] [--cert-dir <folder>]
//       (bash and Pester tests) writes <folder>/cert.pem and <folder>/ports.json,
//       then serves until killed. With --static, files of that folder are
//       served under /static/ (a stand-in for the places the kit is fetched
//       from). A file "<name>.cut" next to a file, holding a number, makes
//       the answer for <name> announce the whole length and break off after
//       that many bytes. With --cert-dir, the certificate of that folder is
//       used instead of a new one.
//   node tests/fake-blossom.js --make-cert <folder>
//       only makes key.pem and cert.pem there (for a program that must be told
//       which certificate to trust before it starts).
const http = require('node:http')
const https = require('node:https')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
const CODE_RE = /^[0-9A-HJKMNP-TV-Z]{20}$/
const TOKEN_RE = /^bft_[A-Za-z0-9_-]{43}$/
const NICKNAME_RE = /^[A-Za-z0-9._-]{1,64}$/
const CODE_TTL_MS = 30 * 60 * 1000
const UNCONFIRMED_TTL_MS = 24 * 60 * 60 * 1000

const sha256 = text => crypto.createHash('sha256').update(text).digest('hex')

function findOpenssl() {
  const candidates = ['openssl']
  if (process.platform === 'win32') {
    for (const base of [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], 'C:\\Program Files']) {
      if (!base) continue
      candidates.push(path.join(base, 'Git', 'usr', 'bin', 'openssl.exe'), path.join(base, 'OpenSSL', 'bin', 'openssl.exe'), path.join(base, 'OpenSSL-Win64', 'bin', 'openssl.exe'))
    }
  }
  for (const c of candidates) {
    try { execFileSync(c, ['version'], { stdio: 'ignore' }); return c } catch (_) { /* next */ }
  }
  return null
}

/** A key and a self-signed certificate for localhost and 127.0.0.1, valid for two days. */
function makeCertificate(dir) {
  const openssl = findOpenssl()
  if (!openssl) throw new Error('The openssl program was not found; the stand-in for Blossom needs it to make a certificate.')
  const conf = path.join(dir, 'openssl.cnf')
  const keyFile = path.join(dir, 'key.pem')
  const certFile = path.join(dir, 'cert.pem')
  fs.writeFileSync(conf, [
    '[req]', 'distinguished_name = dn', 'x509_extensions = ext', 'prompt = no',
    '[dn]', 'CN = localhost',
    '[ext]', 'basicConstraints = critical, CA:TRUE', 'keyUsage = critical, digitalSignature, keyCertSign',
    'extendedKeyUsage = serverAuth', 'subjectAltName = DNS:localhost, IP:127.0.0.1', ''
  ].join('\n'))
  execFileSync(openssl, ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2', '-config', conf, '-keyout', keyFile, '-out', certFile], { stdio: 'ignore' })
  return { key: fs.readFileSync(keyFile), cert: fs.readFileSync(certFile), certFile }
}

function normalizeCode(text) {
  return String(text == null ? '' : text).replace(/[\s-]/g, '').toUpperCase().replace(/O/g, '0').replace(/[IL]/g, '1')
}

function newCode() {
  const bytes = crypto.randomBytes(20)
  let out = ''
  for (const b of bytes) out += CODE_ALPHABET[b & 31]
  return out
}

const formatCode = code => code.match(/.{4}/g).join('-')

/** The address rules of the product, as far as the kit depends on them. Returns the reason, or null. */
function addressProblem(raw, kind) {
  if (typeof raw !== 'string' || !raw || raw.length > 300) return 'is missing or too long'
  let u
  try { u = new URL(raw) } catch (_) { return 'is not an address' }
  if (u.protocol !== 'https:') return 'must start with https://'
  if (u.username || u.password || u.search || u.hash) return 'must be the bare address'
  if (kind !== 'restart' && u.pathname !== '/' && u.pathname !== '') return 'must have nothing after the host name'
  if (/^(localhost|.*\.(local|internal|lan))$/i.test(u.hostname) || /^(10|127|192\.168)\./.test(u.hostname)) return 'only works inside a private network'
  return null
}

const hostOf = raw => { try { return new URL(raw).host.toLowerCase() } catch (_) { return '' } }

/** True when two descriptions name the same three hosts. */
const sameHosts = (a, b) => !!a && !!b && hostOf(a.hub_url) === hostOf(b.hub_url) && hostOf(a.provider_url) === hostOf(b.provider_url) && hostOf(a.restart_url || '') === hostOf(b.restart_url || '')

/** A workspace has an identifier nobody chooses; two workspaces may carry the same name. */
const workspaceIdOf = name => { const h = sha256('workspace ' + name); return [h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20, 32)].join('-') }

/** What a confirmation must name: changes with every description the computer sends. */
const revisionOf = p => (p.pending ? sha256(p.id + ' ' + p.revision + ' ' + JSON.stringify(p.pending)).slice(0, 32) : null)

function createState() {
  return {
    codes: new Map(),      // sha256(code) -> { id, workspace, workspaceId, expiresAt, tokenHash, cancelled }
    pairings: new Map(),   // sha256(token) -> pairing
    sites: [],             // the sites of the workspaces: { id, workspaceId, label, hubUrl }
    hits: [],              // every API call that arrived: { secure, method, path, bearer, body }
    plainApiHits: 0,       // API calls that arrived on the plain http port (must stay 0)
    redirectHits: 0,       // calls that arrived at the place a redirect points to (must stay 0)
    failNext: [],          // answers to give instead of the real ones, first in first out
    redirect: false,
    claimFailures: new Map(),
    claimFailureLimit: 10,
    check: { ok: true, devices: 0, failed_step: null, detail: null },
    autoCheck: true
  }
}

function publicStatus(p, state) {
  const now = Date.now()
  let s = p.state
  if ((s === 'installing' || s === 'checking' || s === 'awaiting_confirmation') && !p.siteId && now > p.expiresAt) s = 'expired'
  if (s === 'checking' && state.autoCheck) {
    // the first read after a site arrived still says "checking"; the next one has the result
    if (p.checkReads > 0) { finishCheck(p, state); s = p.state }
    p.checkReads++
  }
  return {
    state: s,
    needs_confirmation: s === 'awaiting_confirmation',
    workspace_name: p.workspace,
    workspace_id: p.workspaceId,
    site_label: p.siteLabel || null,
    check: (s === 'awaiting_confirmation' || s === 'active') ? (p.check || null) : null,
    poll_after_seconds: state.pollAfter || 1
  }
}

/** The check of what the computer sent ends: with something waiting for an admin, or back on the confirmed site. */
function finishCheck(p, state) {
  p.state = p.pending ? 'awaiting_confirmation' : 'active'
  p.check = Object.assign({ checked_at: new Date().toISOString() }, state.check)
}

function handleApi(state, req, res, body, secure) {
  const send = (status, json, headers) => {
    res.writeHead(status, Object.assign({ 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, headers || {}))
    res.end(JSON.stringify(json))
  }
  const fail = (status, code, error, extra) => send(status, Object.assign({ error, code }, extra || {}), extra && extra.retry_after_seconds ? { 'Retry-After': String(extra.retry_after_seconds) } : undefined)
  const url = new URL(req.url, 'https://fake')
  const auth = req.headers.authorization || ''
  const bearer = auth.startsWith('Bearer ') ? auth.slice(7) : ''
  let json = null
  if (body) { try { json = JSON.parse(body) } catch (_) { json = undefined } }
  state.hits.push({ secure, method: req.method, path: url.pathname, bearer, body: json, userAgent: req.headers['user-agent'] || '' })

  if (!secure) { state.plainApiHits++; return fail(400, 'insecure', 'Blossom is only reachable over https.') }
  if (url.pathname.startsWith('/redirected/')) { state.redirectHits++; return fail(404, 'not_found', 'Nothing here.') }
  if (state.redirect) {
    res.writeHead(307, { Location: 'https://' + req.headers.host + '/redirected' + url.pathname })
    return res.end()
  }
  if (state.failNext.length) {
    const f = state.failNext.shift()
    if (f.html) { res.writeHead(f.status || 200, { 'Content-Type': 'text/html' }); return res.end('<!doctype html><html><body>Sign in</body></html>') }
    return fail(f.status, f.code || 'unavailable', f.error || 'Try again shortly.', f.retryAfter ? { retry_after_seconds: f.retryAfter } : undefined)
  }
  if (json === undefined) return fail(400, 'bad_request', 'The request is not JSON.')

  // ---- claim: the only call without a farm token
  if (url.pathname === '/api/farm/pair/claim') {
    if (req.method !== 'POST') return fail(405, 'method_not_allowed', 'Use POST.')
    const ip = req.socket.remoteAddress || 'x'
    if ((state.claimFailures.get(ip) || 0) >= state.claimFailureLimit) return fail(429, 'rate_limited', 'Too many pairing attempts. Wait a minute.', { retry_after_seconds: 1 })
    const refuse = (status, code, error, extra) => { state.claimFailures.set(ip, (state.claimFailures.get(ip) || 0) + 1); return fail(status, code, error, extra) }
    if (!json || json.protocol !== 1) return fail(400, 'bad_request', 'Unknown protocol version.', { field: 'protocol' })
    const code = normalizeCode(json.pairing_code)
    if (!CODE_RE.test(code)) return refuse(400, 'bad_request', 'That is not a pairing code.', { field: 'pairing_code' })
    if (typeof json.farm_token !== 'string' || !TOKEN_RE.test(json.farm_token)) return fail(400, 'bad_request', 'That is not a farm token.', { field: 'farm_token' })
    const c = json.computer || {}
    if (typeof c.label !== 'string' || !c.label || c.label.length > 64) return fail(400, 'bad_request', 'The computer has no name.', { field: 'computer.label' })
    if (c.platform !== 'windows' && c.platform !== 'macos') return fail(400, 'bad_request', 'Unknown platform.', { field: 'computer.platform' })
    const entry = state.codes.get(sha256(code))
    if (!entry || entry.cancelled) return refuse(404, 'pairing_code_unknown', 'This pairing code is not known.')
    const tokenHash = sha256(json.farm_token)
    if (entry.tokenHash) {
      // a repeat of the claim that succeeded (the answer was lost on the way) is answered again; anybody else is refused
      if (entry.tokenHash !== tokenHash) return refuse(409, 'pairing_code_used', 'This pairing code was already used.')
      const again = state.pairings.get(tokenHash)
      return send(200, { pairing_id: again.id, state: publicStatus(again, state).state, workspace_name: again.workspace, workspace_id: again.workspaceId, expires_at: new Date(again.expiresAt).toISOString(), poll_after_seconds: 1 })
    }
    if (Date.now() > entry.expiresAt) return refuse(410, 'pairing_code_expired', 'This pairing code has expired.')
    if (state.pairings.has(tokenHash)) return fail(409, 'farm_token_in_use', 'This farm token is already registered.')
    entry.tokenHash = tokenHash
    const pairing = {
      id: crypto.randomUUID(), workspace: entry.workspace, workspaceId: entry.workspaceId, state: 'installing', expiresAt: Date.now() + UNCONFIRMED_TTL_MS,
      computer: { label: c.label, platform: c.platform, os_version: String(c.os_version || ''), kit_version: String(c.kit_version || '') },
      // pending: what the computer sent and no admin has confirmed; confirmedSite: what Blossom uses
      pending: null, pendingSecrets: null, revision: 0, confirmedSite: null, confirmedSecrets: null,
      siteId: null, siteLabel: null, check: null, checkReads: 0, revoked: null, revokedReason: null, reports: 0
    }
    state.pairings.set(tokenHash, pairing)
    return send(200, { pairing_id: pairing.id, state: 'installing', workspace_name: pairing.workspace, workspace_id: pairing.workspaceId, expires_at: new Date(pairing.expiresAt).toISOString(), poll_after_seconds: 1 })
  }

  // ---- everything else needs the farm token
  if (!['/api/farm/pair/site', '/api/farm/pair/status', '/api/farm/pair/token'].includes(url.pathname)) return fail(404, 'not_found', 'Nothing here.')
  if (!TOKEN_RE.test(bearer)) return fail(401, 'farm_token_invalid', 'This computer is not paired.')
  const p = state.pairings.get(sha256(bearer))
  if (!p) return fail(401, 'farm_token_invalid', 'This computer is not paired.')
  if (p.revoked === 'revoked') return fail(401, 'farm_token_revoked', 'This computer was unpaired in Blossom.')

  if (url.pathname === '/api/farm/pair/status') {
    if (req.method !== 'GET') return fail(405, 'method_not_allowed', 'Use GET.')
    return send(200, publicStatus(p, state))
  }

  if (url.pathname === '/api/farm/pair/token') {
    if (req.method !== 'DELETE') return fail(405, 'method_not_allowed', 'Use DELETE.')
    p.revoked = 'revoked'; p.revokedReason = 'computer'
    p.unpairedByComputer = true
    return send(200, { unpaired: true })
  }

  // PUT /api/farm/pair/site
  if (req.method !== 'PUT') return fail(405, 'method_not_allowed', 'Use PUT.')
  const current = publicStatus(p, state).state
  if (current === 'rejected') return fail(401, 'pairing_rejected', 'This pairing was declined in Blossom.')
  if (current === 'expired') return fail(401, 'pairing_expired', 'This pairing was not confirmed in time.')
  if (!json || json.protocol !== 1) return fail(400, 'bad_request', 'Unknown protocol version.', { field: 'protocol' })
  if (!json.site && !json.computer) return fail(400, 'bad_request', 'Nothing to change.', { field: 'site' })
  if (json.computer) {
    const c = json.computer
    for (const k of ['label', 'platform', 'os_version', 'kit_version', 'gads_version', 'provider_version']) {
      if (c[k] !== undefined && (typeof c[k] !== 'string' || c[k].length > 64)) return fail(400, 'bad_request', 'A value about the computer is not text.', { field: 'computer.' + k })
    }
    Object.assign(p.computer, c)
    p.reports++
  }
  let siteChanged = false
  if (json.site) {
    const s = json.site
    for (const [field, kind] of [['hub_url', 'hub'], ['provider_url', 'provider']]) {
      const why = addressProblem(s[field], kind)
      if (why) return fail(422, 'site_address_refused', 'The ' + kind + ' address ' + why + '.', { field: 'site.' + field })
    }
    if (s.restart_url !== undefined && s.restart_url !== '') {
      const why = addressProblem(s.restart_url, 'restart')
      if (why) return fail(422, 'site_address_refused', 'The restart service address ' + why + '.', { field: 'site.restart_url' })
    }
    if (typeof s.provider_nickname !== 'string' || !NICKNAME_RE.test(s.provider_nickname)) return fail(400, 'bad_request', 'The provider nickname is not usable.', { field: 'site.provider_nickname' })
    if (typeof s.hub_user !== 'string' || !s.hub_user || s.hub_user.length > 200) return fail(400, 'bad_request', 'The hub user is missing.', { field: 'site.hub_user' })
    for (const k of ['hub_password', 'restart_secret']) {
      if (s[k] !== undefined && (typeof s[k] !== 'string' || s[k].length > 500)) return fail(400, 'bad_request', 'A secret is not text.', { field: 'site.' + k })
    }
    const next = { hub_url: s.hub_url, provider_url: s.provider_url, provider_nickname: s.provider_nickname, hub_user: s.hub_user, restart_url: s.restart_url || '' }
    // Which stored description this one continues: the confirmed site when
    // the three hosts are its hosts, otherwise the one that waits for an admin.
    const onConfirmed = sameHosts(p.confirmedSite, next)
    const before = onConfirmed ? p.confirmedSite : p.pending
    const stored = onConfirmed ? p.confirmedSecrets : p.pendingSecrets
    // A stored secret is only reused for the hosts and the user it was stored
    // for. It is looked for in what waits for an admin first, then in what
    // is confirmed: new hub addresses with the restart address that was
    // confirmed keep the confirmed restart secret.
    const held = [[p.pending, p.pendingSecrets], [p.confirmedSite, p.confirmedSecrets]].filter(x => x[0] && x[1])
    const sameHub = x => hostOf(x[0].hub_url) === hostOf(s.hub_url) && hostOf(x[0].provider_url) === hostOf(s.provider_url) && x[0].hub_user === s.hub_user && x[1].hub_password
    const sameRestart = x => hostOf(x[0].restart_url || '') === hostOf(s.restart_url || '') && x[1].restart_secret
    const secrets = {}
    const hubSource = held.find(sameHub)
    const restartSource = held.find(sameRestart)
    if (s.hub_password) secrets.hub_password = s.hub_password
    else if (hubSource) secrets.hub_password = hubSource[1].hub_password
    else return fail(422, 'credentials_required', 'Send the hub password: Blossom has none for this hub address and user.', { field: 'site.hub_password' })
    if (s.restart_url) {
      if (s.restart_secret) secrets.restart_secret = s.restart_secret
      else if (restartSource) secrets.restart_secret = restartSource[1].restart_secret
      else return fail(422, 'credentials_required', 'Send the restart secret: Blossom has none for this restart service address.', { field: 'site.restart_secret' })
    }
    const differs = JSON.stringify(before) !== JSON.stringify(next) || JSON.stringify(stored) !== JSON.stringify(secrets)
    if (onConfirmed) {
      // The confirmed addresses: applied at once, no new confirmation. A
      // description for other addresses that was still waiting is dropped:
      // the computer is back where the admin confirmed it.
      siteChanged = differs || !!p.pending
      p.confirmedSite = next; p.confirmedSecrets = secrets
      p.pending = null; p.pendingSecrets = null
      if (siteChanged) { p.state = 'checking'; p.checkReads = 0 }
    } else if (differs) {
      // Other addresses (or the first description): they wait for an admin.
      // What is confirmed is NOT touched: the site stays enabled, on its
      // confirmed addresses and with its confirmed credentials, meanwhile.
      siteChanged = true
      p.pending = next; p.pendingSecrets = secrets; p.revision++
      p.state = 'checking'; p.checkReads = 0; p.check = null
    }
  }
  const out = publicStatus(Object.assign({}, p, { checkReads: 0 }), Object.assign({}, state, { autoCheck: false }))
  return send(200, { state: out.state, needs_confirmation: !!p.pending, site_changed: siteChanged, poll_after_seconds: state.pollAfter || 1 })
}

function handleTest(state, req, res, body) {
  const send = (status, json) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(json)) }
  const url = new URL(req.url, 'http://fake')
  let json = {}
  if (body) { try { json = JSON.parse(body) } catch (_) { return send(400, { error: 'not JSON' }) } }
  const latest = () => Array.from(state.pairings.values()).pop()
  const pick = () => (json.token ? state.pairings.get(sha256(json.token)) : latest())
  switch (url.pathname) {
    case '/__test/new-code': {
      const code = newCode()
      const ttl = typeof json.ttlSeconds === 'number' ? json.ttlSeconds * 1000 : CODE_TTL_MS
      const workspace = json.workspace || 'Test Agency'
      state.codes.set(sha256(code), { id: crypto.randomUUID(), workspace, workspaceId: json.workspaceId || workspaceIdOf(workspace), expiresAt: Date.now() + ttl, tokenHash: null, cancelled: false })
      return send(200, { code: formatCode(code) })
    }
    case '/__test/cancel-code': {
      const entry = state.codes.get(sha256(normalizeCode(json.code)))
      if (entry) entry.cancelled = true
      return send(200, { ok: !!entry })
    }
    case '/__test/add-site': {
      // a site of the workspace that exists already (entered by hand, or paired earlier)
      const workspace = json.workspace || 'Test Agency'
      const site = { id: crypto.randomUUID(), workspaceId: json.workspaceId || workspaceIdOf(workspace), label: json.label || 'Site', hubUrl: json.hubUrl }
      state.sites.push(site)
      return send(200, { ok: true, site_id: site.id })
    }
    case '/__test/pending': {
      // what the admin's page reads before it shows the confirm card (contract, section 5)
      const p = pick()
      if (!p) return send(404, { error: 'no pairing' })
      if (p.state === 'checking') finishCheck(p, state)
      const same = p.pending ? state.sites.find(x => x.workspaceId === p.workspaceId && x.id !== p.siteId && hostOf(x.hubUrl) === hostOf(p.pending.hub_url)) : null
      return send(200, { state: p.state, pendingRevision: revisionOf(p), pending: p.pending, current: p.confirmedSite, computer: p.computer, check: p.check, replaces: same ? { id: same.id, label: same.label } : null })
    }
    case '/__test/confirm': {
      // The admin presses Confirm: { label, replaceSiteId?, revision }. A test
      // that sends no revision confirms what is there now, as an admin does
      // who has just loaded the page.
      const p = pick()
      if (!p || !p.pending) return send(409, { error: 'no site to confirm', code: 'nothing_pending' })
      if (p.state === 'checking') finishCheck(p, state)
      if (p.state !== 'awaiting_confirmation') return send(409, { error: 'the pairing does not wait for a confirmation', code: 'not_awaiting_confirmation' })
      if (json.revision !== undefined && json.revision !== revisionOf(p)) {
        return send(409, { error: 'The computer sent different addresses. Read them again.', code: 'pending_changed' })
      }
      let target = p.siteId ? state.sites.find(x => x.id === p.siteId) : null
      if (!p.siteId && json.replaceSiteId) {
        target = state.sites.find(x => x.id === json.replaceSiteId && x.workspaceId === p.workspaceId)
        if (!target) return send(404, { error: 'no such site', code: 'site_unknown' })
      }
      if (!target && state.sites.some(x => x.workspaceId === p.workspaceId && hostOf(x.hubUrl) === hostOf(p.pending.hub_url))) {
        // the server never picks the site to replace by itself
        return send(409, { error: 'A site of yours already uses this hub address. Tick "This replaces your site", or decline.', code: 'hub_address_in_use' })
      }
      if (target && !(p.check && p.check.ok)) {
        // a site that exists is only changed by a computer that proved it has the hub's login
        return send(409, { error: 'The check of these addresses did not pass. A site that exists is only changed when it does.', code: 'check_required' })
      }
      if (target) {
        for (const other of state.pairings.values()) {
          if (other !== p && other.siteId === target.id && !other.revoked) { other.revoked = 'revoked'; other.revokedReason = 'replaced' }
        }
        target.hubUrl = p.pending.hub_url
        if (json.label) target.label = json.label
      } else {
        target = { id: crypto.randomUUID(), workspaceId: p.workspaceId, label: json.label || p.computer.label, hubUrl: p.pending.hub_url }
        state.sites.push(target)
      }
      p.siteId = target.id; p.siteLabel = json.label || target.label
      p.confirmedSite = p.pending; p.confirmedSecrets = p.pendingSecrets
      p.pending = null; p.pendingSecrets = null
      p.state = 'active'; p.check = Object.assign({ checked_at: new Date().toISOString() }, state.check)
      return send(200, { ok: true, site_id: p.siteId })
    }
    case '/__test/reject': {
      // The admin declines. A computer that was never confirmed is refused
      // for good; for a confirmed site only the new addresses are dropped.
      const p = pick()
      if (p) { p.pending = null; p.pendingSecrets = null; p.state = p.confirmedSite ? 'active' : 'rejected' }
      return send(200, { ok: !!p })
    }
    case '/__test/recheck': {
      // Blossom checks a confirmed site again (as "Test connection" does)
      const p = pick()
      if (p && p.confirmedSite && !p.pending) p.check = Object.assign({ checked_at: new Date().toISOString() }, state.check)
      return send(200, { ok: !!p })
    }
    case '/__test/revoke': { const p = pick(); if (p) { p.revoked = 'revoked'; p.revokedReason = 'admin' } return send(200, { ok: !!p }) }
    case '/__test/expire-pairing': { const p = pick(); if (p) { p.expiresAt = Date.now() - 1000 } return send(200, { ok: !!p }) }
    case '/__test/set-check': state.check = Object.assign({ ok: true, devices: 0, failed_step: null, detail: null }, json); return send(200, { ok: true })
    case '/__test/fail-next': {
      for (let i = 0; i < (json.count || 1); i++) state.failNext.push({ status: json.status || 503, code: json.code, error: json.error, retryAfter: json.retryAfter, html: json.html })
      return send(200, { ok: true })
    }
    case '/__test/redirect': state.redirect = !!json.on; return send(200, { ok: true })
    case '/__test/limits': if (typeof json.claimFailureLimit === 'number') state.claimFailureLimit = json.claimFailureLimit; state.claimFailures.clear(); return send(200, { ok: true })
    case '/__test/reset-hits': state.hits.length = 0; state.plainApiHits = 0; state.redirectHits = 0; state.failNext.length = 0; state.redirect = false; return send(200, { ok: true })
    case '/__test/state': {
      const p = pick()
      return send(200, {
        hits: state.hits, plainApiHits: state.plainApiHits, redirectHits: state.redirectHits,
        pairings: state.pairings.size,
        // site and secrets: what the computer sent last. confirmedSite: what Blossom uses
        // (null until an admin confirmed). awaiting: a description waits for an admin.
        pairing: p ? {
          id: p.id, state: p.state, confirmed: !!p.confirmedSite, awaiting: !!p.pending, revision: revisionOf(p),
          revoked: p.revoked, revokedReason: p.revokedReason, unpairedByComputer: !!p.unpairedByComputer,
          site: p.pending || p.confirmedSite, secrets: p.pendingSecrets || p.confirmedSecrets,
          confirmedSite: p.confirmedSite, confirmedSecrets: p.confirmedSecrets,
          siteId: p.siteId, workspaceId: p.workspaceId, computer: p.computer, reports: p.reports
        } : null
      })
    }
    default: return send(404, { error: 'unknown switch' })
  }
}

const MIME = { '.zip': 'application/zip', '.gz': 'application/gzip', '.sh': 'text/x-shellscript', '.ps1': 'text/plain', '.json': 'application/json' }

/**
 * Starts the stand-in. Options: dir (where the certificate is made; a
 * temporary folder when left out), staticDir (served under /static/).
 * Resolves to { origin, controlUrl, certFile, state, close() }.
 */
async function startFakeBlossom(options = {}) {
  const dir = options.dir || fs.mkdtempSync(path.join(os.tmpdir(), 'fake-blossom-'))
  fs.mkdirSync(dir, { recursive: true })
  let made
  if (options.certDir && fs.existsSync(path.join(options.certDir, 'key.pem'))) {
    made = { key: fs.readFileSync(path.join(options.certDir, 'key.pem')), cert: fs.readFileSync(path.join(options.certDir, 'cert.pem')), certFile: path.join(dir, 'cert.pem') }
    fs.writeFileSync(made.certFile, made.cert)
  } else {
    made = makeCertificate(dir)
  }
  const { key, cert, certFile } = made
  const state = createState()
  const collect = (req, then) => {
    let body = ''
    let size = 0
    req.on('data', d => { size += d.length; if (size <= 65536) body += d })
    req.on('end', () => then(size > 65536 ? '{"too":"large"' : body))
  }
  const serveStatic = (req, res) => {
    const rel = decodeURIComponent(new URL(req.url, 'https://fake').pathname.slice('/static/'.length))
    const file = path.join(options.staticDir || '', rel)
    if (!options.staticDir || rel.includes('..') || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); return res.end('not found') }
    const type = MIME[path.extname(file)] || 'application/octet-stream'
    if (fs.existsSync(file + '.cut')) {
      // a download that is cut short: the whole length is announced, part of it is sent
      const body = fs.readFileSync(file)
      const keep = Math.min(body.length, Number(fs.readFileSync(file + '.cut', 'utf8')) || 0)
      res.writeHead(200, { 'Content-Type': type, 'Content-Length': body.length })
      res.write(body.subarray(0, keep), () => res.socket.destroy())
      return
    }
    res.writeHead(200, { 'Content-Type': type })
    fs.createReadStream(file).pipe(res)
  }
  const secure = https.createServer({ key, cert }, (req, res) => {
    if (req.url.startsWith('/static/')) return serveStatic(req, res)
    collect(req, body => handleApi(state, req, res, body, true))
  })
  const plain = http.createServer((req, res) => {
    collect(req, body => (req.url.startsWith('/__test/') ? handleTest(state, req, res, body) : handleApi(state, req, res, body, false)))
  })
  await new Promise((resolve, reject) => secure.once('error', reject).listen(0, '127.0.0.1', resolve))
  await new Promise((resolve, reject) => plain.once('error', reject).listen(0, '127.0.0.1', resolve))
  const ports = { https: secure.address().port, http: plain.address().port }
  fs.writeFileSync(path.join(dir, 'ports.json'), JSON.stringify(ports))
  return {
    origin: 'https://127.0.0.1:' + ports.https,
    controlUrl: 'http://127.0.0.1:' + ports.http,
    certFile, dir, state, ports,
    close: () => new Promise(resolve => {
      secure.closeAllConnections(); plain.closeAllConnections()
      secure.close(() => plain.close(() => resolve()))
    })
  }
}

module.exports = { startFakeBlossom, normalizeCode, formatCode, newCode, CODE_RE, TOKEN_RE }

if (require.main === module) {
  const args = process.argv.slice(2)
  const value = name => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined }
  if (value('--make-cert')) {
    fs.mkdirSync(value('--make-cert'), { recursive: true })
    makeCertificate(value('--make-cert'))
    process.exit(0)
  }
  const dir = value('--dir')
  if (!dir) { console.error('usage: node fake-blossom.js --dir <folder> [--static <folder>] [--cert-dir <folder>]'); process.exit(2) }
  startFakeBlossom({ dir, staticDir: value('--static'), certDir: value('--cert-dir') }).then(fake => {
    console.log('ready ' + fake.origin + ' ' + fake.controlUrl)
    const stop = () => fake.close().then(() => process.exit(0))
    process.on('SIGTERM', stop); process.on('SIGINT', stop)
  }).catch(e => { console.error(e.message); process.exit(1) })
}
