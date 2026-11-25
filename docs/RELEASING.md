# Releasing (for maintainers of this repository)

Two kinds of release live in this repository:

| Tag | What | Made by |
|---|---|---|
| `gads-v<upstream>-drag.<n>` | `GADS-drag.exe`, `SHA256SUMS`, the source archive, `THIRD-PARTY-NOTICES.txt`, `LICENSE-AGPL-3.0.txt`. Never marked "Latest". | `.github/workflows/build-gads.yml` |
| `kit-v<x.y.z>` | the kit itself; customers download its "Source code (zip)". Always marked "Latest". | a normal GitHub release, by hand |

`install.ps1` downloads `GADS-drag.exe` from the address in `versions.json`.
**Until the `gads-…` release named there exists, the installer stops at step
4 with a download error.** Publish it before the first `kit-…` release.

## Before the first gads release: a decision only you can take

`GADS-drag.exe` embeds upstream's `resources` folder, as every GADS binary
does: Apple's developer disk image for iOS 17+, and pre-built helper files
(`NOTICE`, section 2b). Publishing the binary makes this repository a
distributor of those files. Upstream publishes the same files; that does not
settle whether you may. The workflow therefore **builds on every tag but
publishes nothing** until the commit you tag contains

```json
"redistributeEmbeddedResources": true
```

under `gadsDrag` in `versions.json`. Setting it is the record of your
decision (who set it and when is in the git history). The value does not
change the binary or its checksum. If you decide against publishing, the
alternative is in `patch/README.md`: build the provider on the farm PC and
install it with `install.ps1 -ProviderExe <path>`.

If a published `GADS-drag.exe` ever has to be taken down: running farms are
not affected (they have the file), and new installs and updates stop at step
4 with "is not at its download address (HTTP 404)" until a kit points
somewhere else or the customer passes `-ProviderExe`.

## First release

1. Push `main`. Wait for the CI workflow to be green: it parses every script
   with Windows PowerShell 5.1, runs PSScriptAnalyzer and the Pester tests on
   Windows, and the Node tests on Windows and Linux.
2. Run the *Build GADS-drag* workflow by hand (Actions → Build GADS-drag →
   Run workflow, "publish" off). It must end with "Reproduced the pinned
   SHA-256". If it reports a different hash, do not publish: find out why
   (the usual cause is a different Go patch version; `versions.json` pins
   `goVersion`).
   The pinned SHA-256 in `versions.json` was produced on a developer machine
   with the commands of `patch/README.md` (twice, in different folders, same
   result); the workflow run is what proves it for the published build.
3. Take the decision of the previous section and, if it is yes, commit
   `"redistributeEmbeddedResources": true`. Then tag that commit:
   `git tag gads-v6.0.0-drag.1 && git push origin gads-v6.0.0-drag.1`.
   The workflow builds again and creates the release with the five files. It
   is created with `--latest=false`: check on the releases page that it does
   **not** carry the "Latest" badge.
4. Check that the address in `versions.json` (`gadsDrag.url`) answers 200.
5. Run the acceptance checklist below on a Windows PC with a phone, following
   the README as a customer would.
6. Create the release `kit-v1.0.0` from that commit, with "Set as the latest
   release" ticked. The README sends customers to `/releases/latest`.

## Acceptance checklist for a kit release

On a spare Windows PC (or a virtual machine), never the production farm:

1. `install.ps1` to the end, with a new Cloudflare tunnel and three new host
   names. Run it a second time: it must change nothing and ask only for the
   hub administrator password. During that second run `Get-Service
   GadsProvider, KeepAvailable` must stay *Running* the whole time; press
   Ctrl+C at the password prompt of a third run and check that all services
   are still running afterwards.
2. `scripts\status.ps1` reports no problem; `scripts\self-test.ps1` passes.
   With a phone connected, `status.ps1` lists the provider's per-phone ports
   as "closed to other computers by the kit's firewall rule"; from a second
   computer on the same network, `Test-NetConnection <farm PC> -Port <one of
   those ports>` must fail, and the phone must still be live with picture in
   Blossom (the rule must not disturb the provider).
3. "Test connection" in Blossom is green; the Services panel shows every
   program and "Restart Provider" works.
4. One phone through `docs/phones.md`. In Blossom's Control page: picture,
   tap, swipe, typing; with the AI assistant: `drag`, `source`, `open_url`.
5. From another network, without signing in: `https://<provider host>/devices`
   and `https://<restart host>/status` answer 401;
   `https://<hub host>/device/x/appium/status`, the same address with
   `%61ppium`, and `https://<hub host>/admin/provider/Provider1/info` answer
   403 (`curl --path-as-is`). With a valid hub token,
   `https://<provider host>/%64ebug/pprof/heap` answers 404, and any answer
   of the provider host carries the header `X-Source-Code`. After a Control
   session, `C:\farm\logs\provider.log` shows the `ios-webrtc` line
   without `token=`.
6. Restart the PC and touch nothing, **without signing in to Windows**:
   everything comes back by itself, the phones included. (This is the check
   that Apple's USB support runs as a service; `docs/phones.md`, section 0.)
   In Blossom's Services panel, "Restart all" restarts the hub too:
   `C:\farm\logs\restart-server.log` shows `stop GadsHub -> 0` and no
   "could NOT be stopped".
7. `rotate-secrets.ps1 -All`; `update.ps1` and `update.ps1 -Rollback`;
   `export-farm.ps1`, then `import-farm.ps1` and `install.ps1` on a second
   machine; `uninstall.ps1 -RemoveData`.
8. With `install.ps1 -WithAppium`: the provider starts, and an Appium session
   opens through the provider host name. In the registry,
   `HKLM:\SYSTEM\CurrentControlSet\Services\GadsProvider\Parameters`,
   `AppEnvironmentExtra` holds three separate entries (`APPIUM_HOME`,
   `NPM_CONFIG_PREFIX`, `PATH`), and the provider log does not show it
   installing the GADS Appium plugin by itself.
9. As a standard (non-administrator) user create `C:\farm\bin` with a file in
   it on a clean PC, then run `install.ps1` as Administrator: it must stop at
   step 2 with "already exists and cannot be used".

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
   with `scripts\update.ps1` before a `kit-…` release. The `gads-…` release
   is not marked "Latest", so customers who follow the README keep getting
   the last tested kit in the meantime. A newer GADS can also expect another
   version of its Appium plugin (`targetAppiumPluginVersion` in
   `provider/provider.go`): put it into `versions.json` → `npm.gadsPlugin`.

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
that carries it carries the licence text, its source archive (with the module
sources, the build instructions and the statement of modifications) and the
licence notices of the libraries compiled into it; the workflow makes and
attaches all of them. The binary must stay free of `hub-ui` (the workflow
builds without the `ui` tag and checks that the submodule folder is empty).
The patch marks the files it changes as modified and makes the provider
announce where its source is (`X-Source-Code`); keep both when the patch
changes. The question of the files embedded from upstream's `resources/`
directory is yours to decide, and the workflow waits for that decision
("Before the first gads release" above).
