# Releasing (for maintainers of this repository)

Two kinds of release live in this repository:

| Tag | What | Made by |
|---|---|---|
| `gads-v<upstream>-drag.<n>` | `GADS-drag.exe`, `SHA256SUMS`, the source archive | `.github/workflows/build-gads.yml` |
| `kit-v<x.y.z>` | the kit itself; customers download its "Source code (zip)" | a normal GitHub release, by hand |

`install.ps1` downloads `GADS-drag.exe` from the address in `versions.json`.
**Until the `gads-…` release named there exists, the installer stops at step
4 with a download error.** Publish it before the first `kit-…` release.

## First release

1. Push `main`. Wait for the CI workflow to be green: it parses every script
   with Windows PowerShell 5.1, runs PSScriptAnalyzer and the Pester tests on
   Windows, and the Node tests on Windows and Linux.
2. Run the *Build GADS-drag* workflow by hand (Actions → Build GADS-drag →
   Run workflow, "publish" off). It must end with "Reproduced the pinned
   SHA-256". If it reports a different hash, do not publish: find out why
   (the usual cause is a different Go patch version; `versions.json` pins
   `goVersion`).
3. Tag the same commit: `git tag gads-v6.0.0-drag.1 && git push origin gads-v6.0.0-drag.1`.
   The workflow builds again and creates the release with the three files.
4. Run the acceptance checklist below on a Windows PC with a phone, following
   the README as a customer would.
5. Create the release `kit-v1.0.0` from that commit.

## Acceptance checklist for a kit release

On a spare Windows PC (or a virtual machine), never the production farm:

1. `install.ps1` to the end, with a new Cloudflare tunnel and three new host
   names. Run it a second time: it must change nothing and ask only for the
   hub administrator password.
2. `scripts\status.ps1` reports no problem; `scripts\self-test.ps1` passes.
3. "Test connection" in Blossom is green; the Services panel shows every
   program and "Restart Provider" works.
4. One phone through `docs/phones.md`. In Blossom's Control page: picture,
   tap, swipe, typing; with the AI assistant: `drag`, `source`, `open_url`.
5. From another network, without signing in: `https://<provider host>/devices`
   and `https://<restart host>/status` answer 401;
   `https://<hub host>/device/x/appium/status` and the same address with
   `%61ppium` answer 403 (`curl --path-as-is`).
6. Restart the PC and touch nothing: everything comes back by itself.
7. `rotate-secrets.ps1 -All`; `update.ps1` and `update.ps1 -Rollback`;
   `export-farm.ps1`, then `import-farm.ps1` and `install.ps1` on a second
   machine; `uninstall.ps1 -RemoveData`.
8. With `install.ps1 -WithAppium`: the provider starts, and an Appium session
   opens through the provider host name.

## A new patched provider (patch changed, or a newer GADS)

1. Change `patch/provider-drag.patch` and/or `gads.version`, `gads.commit` in
   `versions.json`. A newer GADS also means a new hub: update `hubZipUrl`,
   `hubZipSha256` (SHA-256 of upstream's `gads-win.zip`) and `hubExeSha256`
   (SHA-256 of the `GADS.exe` inside it). Upstream publishes no checksums, so
   these are recorded by us: download the file twice, from two networks, and
   compare before pinning.
2. Set `gadsDrag.releaseTag`, `gadsDrag.version` and `gadsDrag.url` to the new
   tag. Take `goVersion` from the `go` line of upstream's `go.mod`.
3. Build locally with the commands in `patch/README.md` and put the SHA-256
   into `gadsDrag.sha256`. (Or run the workflow by hand once: it prints the
   hash it built before failing the comparison.)
4. Commit, wait for CI, tag `gads-…`, check the release, then test on a farm
   with `scripts\update.ps1` before a `kit-…` release.

Never move or re-create a published `gads-…` tag or replace its files:
installed kits pin its checksum.

## Pinned versions of the other programs

`versions.json → winget` pins exact versions. winget removes old versions of
some packages over time; when a pin is no longer offered, the installer says
so and the README tells the customer what to do. Refresh the pins with each
kit release: check the newest versions in
<https://github.com/microsoft/winget-pkgs/tree/master/manifests> and test
them on a farm first (MongoDB and cloudflared are the ones that matter).

## What must never be committed

No binary, no `.ipa`, no certificate or key, nothing copied from a real farm:
no real host name, tunnel id, UDID, password or secret. Examples use
`yourdomain.com` and zero UUIDs. `.gitignore` blocks the usual file types;
it does not replace looking at the diff.

## Licence duties when publishing `GADS-drag.exe`

Read `NOTICE`, section 2. In short: the binary is AGPL-3.0, so every release
that carries it must carry its complete source (the workflow attaches it);
the binary must stay free of `hub-ui` (the workflow builds without the `ui`
tag and checks that the submodule folder is empty); and the question of the
files embedded from upstream's `resources/` directory is open and yours to
decide.
