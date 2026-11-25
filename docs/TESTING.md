# What was tested, and what was not

Version 1.0.0 of the kit was written and checked on Linux, without a Windows
PC, a phone, a Cloudflare account or a GitHub repository to run workflows in.
This page is the honest list. It will be updated as the kit is run on real
farms.

## Tested

| What | How | Result |
|---|---|---|
| The patch applies to upstream `v6.0.0` (and to `v6.1.0`) | `git apply --check` on fresh clones of `github.com/shamanec/GADS` | applies cleanly, no offsets |
| The patched tree builds for Windows x64 | upstream's steps without the UI: `swag init` (swag v1.16.4), then `go build` with Go 1.26.0, `CGO_ENABLED=0 GOOS=windows GOARCH=amd64`, on Linux x64 | builds; 81,252,864 bytes |
| The build is reproducible | built twice from two separate checkouts in different folders | identical SHA-256 (the one pinned in `versions.json`) |
| `go vet ./provider/router/` and `go test ./provider/...` on the patched tree | on Linux | pass |
| The upstream hub download | downloaded `gads-win.zip` of `v6.0.0` from the publisher's release, hashed it and the `GADS.exe` inside | pinned in `versions.json`; the exe has the same size as the one on the reference farm |
| `services/restart-server.js` | 19 automated tests (`tests/restart-server.test.js`), Node 22 on Linux, with a stand-in for `sc.exe`: authentication on every route, constant-time comparison, refusal to start without a secret (also as a real process), each endpoint and its order of service calls, 409 while busy, bind address, no CORS headers, unknown paths, oversized bodies | pass |
| `services/provider-gate.js` | 10 automated tests (`tests/provider-gate.test.js`) against a stand-in hub and provider: refusal without or with a wrong token, pass-through with header and with `?token=`, blocked paths, cache, hub down (503), provider down (502), WebSocket upgrade refused and passed through both ways, no connection left behind | pass |
| The winget package ids and versions in `versions.json` | read from the manifests in `microsoft/winget-pkgs` | exist, with the installer types assumed by the scripts |
| The GitHub workflows | YAML parses; action versions resolved to commit ids from the actions' own tags | not executed |
| GADS behaviour the kit depends on | read in the `v6.0.0` source: flags of `hub` and `provider`, default administrator, `/authenticate`, `/change-password`, `/admin/user`, `/admin/providers/add`, `/admin/workspaces`, `/workspaces`, `/available-devices`, `/user-info`, provider start conditions, the absence of provider authentication | as described in the docs |

## Not tested

Everything below needs equipment that was not available. None of it has run
even once.

**On a Windows PC**

* Every PowerShell file: `install.ps1`, `lib/FarmKit.psm1`, everything in
  `scripts/`, `services/keep-available.ps1`. They were written for Windows
  PowerShell 5.1 and reviewed by eye, but **not parsed by PowerShell, not
  analysed with PSScriptAnalyzer and not executed**; the Pester tests in
  `tests/FarmKit.Tests.ps1` have not been run either. The CI workflow does
  all four on its first run on GitHub.
* winget installing the pinned packages, where each installer puts its
  program, and whether the MongoDB installer creates the `MongoDB` service
  with MongoDB bound to `127.0.0.1` (expected from its installer defaults).
* NSSM: every setting the installer applies, log rotation, service
  dependencies, start order after a restart of the PC.
* `icacls` with well-known SIDs on a non-English Windows.
* The restart service driving the real `sc.exe`, including on a non-English
  Windows (the status check was written to be language independent, from
  what `sc.exe` is known to print).
* `scripts/update.ps1`, `export-farm.ps1`, `import-farm.ps1`,
  `uninstall.ps1`, `rotate-secrets.ps1`.

**With a GADS hub running**

* The installer's calls to the hub: changing the default password, creating
  users and the provider. The endpoints and JSON fields were taken from the
  source, not from a running hub.
* The upstream hub (`v6.0.0`) together with a provider built from the same
  tag without the UI. The reference farm runs this combination, built
  slightly differently (on Windows, with a different version string).
* `keep-available.ps1` against a real hub: that a subscription by a
  plain-role user keeps devices available, and that it survives hub restarts.
* The provider gate with a real provider and a real browser: the WebRTC
  handshake over WebSocket, large responses such as screenshots, and uploads.
  **This is the piece to test first**, because it sits in the path of the
  live video and is new.
* A provider created with iOS switched off, then switched on in the hub page
  after uploading WebDriverAgent.

**With phones**

* Everything in `docs/phones.md`: signing in the hub page, Developer Mode on
  Windows, pairing, the pair cache, which video method Blossom's Control page
  needs (section 5 of that page is an open question).

**With Cloudflare**

* `cloudflared tunnel login/create/route dns/ingress validate` as the
  installer calls them, in particular `--credentials-file` on `create`, the
  `TUNNEL_ORIGIN_CERT` variable, the wording of error messages the installer
  looks for ("already exists"), and that cloudflared accepts the two `path`
  rules in the generated configuration.
* Whether the `path` rule for "appium" is matched against the decoded path
  (it is an extra layer either way; see `docs/security.md`).
* The self-test against real public host names.

**With Blossom CRM**

* "Test connection" and the Control page against a farm installed by this
  kit. The contract was read from the product's code
  (`src/lib/farm/probe.ts`, `restartService.ts`, `net.ts`,
  `src/app/api/gads/services`), and the restart service and self-test were
  written to it.

**With GitHub**

* Both workflows have never run. `build-gads.yml` is expected to reproduce
  the pinned SHA-256 because the same commands did so twice locally; a
  different result must be investigated, not overridden.
* actionlint was not available to check the workflow files.

## A suggested first test on a real farm

1. A spare Windows PC (or a virtual machine), not the production farm.
2. `install.ps1` to the end; note every place it stops.
3. `scripts\status.ps1`, `scripts\self-test.ps1`.
4. "Test connection" in Blossom.
5. One phone through `docs/phones.md`; open it in Blossom's Control page:
   picture, tap, swipe, typing; the AI assistant if you use it (`drag`,
   `source`, `open_url`).
6. From another network, without signing in: open
   `https://<provider host>/devices` and `https://<restart host>/status` in a
   browser. Both must answer 401.
7. Restart the PC; everything must come back by itself.
8. `rotate-secrets.ps1 -All`, `export-farm.ps1`, `import-farm.ps1` on a second
   machine, `uninstall.ps1 -RemoveData`.
