# Releasing (for maintainers of this repository)

Two kinds of release live in this repository:

| Tag | What | Made by |
|---|---|---|
| `gads-v<upstream>-drag.<n>` | the patched provider, three times from the same source (`GADS-drag.exe` for Windows x64, `GADS-drag-darwin-arm64` and `GADS-drag-darwin-amd64` for macOS), `SHA256SUMS`, the source archive, `THIRD-PARTY-NOTICES.txt`, `LICENSE-AGPL-3.0.txt`. Never marked "Latest". | `.github/workflows/build-gads.yml` |
| `kit-v<x.y.z>` | the kit itself; customers download its "Source code (zip)". Always marked "Latest". | a normal GitHub release, by hand |

`install.ps1` downloads `GADS-drag.exe`, and `install.sh` the
`GADS-drag-darwin-…` file for its processor, from the addresses in
`versions.json`. **Until the `gads-…` release named there exists and carries
all three files, the installers stop at step 4 with a download error.**
Publish it before the first `kit-…` release. The three files belong to one
release: tag only a commit whose workflow builds all three (a release made
from an older commit has the Windows file alone, and a published release is
never changed afterwards, so macOS would then need a new `…-drag.<n+1>`).

## Before the first gads release: a decision only you can take

Every `GADS-drag` program embeds upstream's `resources` folder, as every GADS binary
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
alternative is in `patch/README.md`: build the provider on the farm computer
and install it with `install.ps1 -ProviderExe <path>` or
`install.sh --provider-binary <path>`.

If a published `GADS-drag` file ever has to be taken down: running farms are
not affected (they have the file), and new installs and updates stop at step
4 with "is not at its download address (HTTP 404)" until a kit points
somewhere else or the customer passes `-ProviderExe` / `--provider-binary`.

## First release

1. Push `main`. Wait for the CI workflow to be green. What it runs:
   * Windows: every `.ps1` parsed with Windows PowerShell 5.1,
     PSScriptAnalyzer, the Pester tests;
   * Linux: shellcheck on every `.sh`, the bash tests (`tests/farmkit.test.sh`,
     also in POSIX mode), the JSON reader with several awks, the launchd
     property lists against Apple's DTD;
   * macOS (`macos-15`, the job named "macOS scripts on macOS"): the same
     bash tests with the bash 3.2, awk and sed that macOS ships, `plutil
     -lint` on the property lists, `pfctl -n` on the packet filter rule,
     `newsyslog -n` on the log rotation file;
   * the Node tests on Windows, Linux and macOS.

   **The macOS job has never run before the first push that contains it.**
   Read its log on that first run: it is the only place where the shell
   scripts meet the real tools of macOS before a Mac does.
2. Run the *Build GADS-drag* workflow by hand (Actions → Build GADS-drag →
   Run workflow, "publish" off). It must end with "Reproduced the three
   pinned SHA-256 values". If it reports a different hash, do not publish:
   find out why (the usual cause is a different Go patch version;
   `versions.json` pins `goVersion`).
   The pinned SHA-256 values in `versions.json` were produced on a developer
   machine with the commands of `patch/README.md` (each twice, in different
   folders, same result); the workflow run is what proves it for the
   published build.
3. Take the decision of the previous section and, if it is yes, commit
   `"redistributeEmbeddedResources": true`. Then tag that commit:
   `git tag gads-v6.0.0-drag.1 && git push origin gads-v6.0.0-drag.1`.
   The workflow builds again and creates the release with the seven files. It
   is created with `--latest=false`: check on the releases page that it does
   **not** carry the "Latest" badge.
4. Check that the three addresses in `versions.json` (`gadsDrag.url`,
   `macos.arm64.provider.url`, `macos.x86_64.provider.url`) answer 200.
5. Run both acceptance checklists below, on a Windows PC and on a Mac, each
   with a phone, following the README as a customer would.
6. Create the release `kit-v1.0.0` from that commit, with "Set as the latest
   release" ticked. The README sends customers to `/releases/latest`.

## Acceptance checklist for a kit release: Windows

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

## Acceptance checklist for a kit release: macOS

The macOS track was written and checked without a Mac: shellcheck, the test
suite under bash 3.2.57, the property lists against Apple's DTD, and a run
of every script against stand-ins for `launchctl`, `dscl`, `pfctl`, the hub
and the downloads. **Everything below is what only a real Mac, and for most
points a real iPhone, can confirm. Until a release has passed it, no
statement about macOS in the README is proven.** Do it on a spare Mac with
Apple Silicon and the macOS version named in `versions.json`
(`macos.arm64.minimumMacOS`), and once on an Intel Mac if Intel is to stay
supported. Write down every command that had to be changed.

*Before anything else, the CI job "macOS scripts on macOS" is green* (it
proves bash 3.2, awk, sed, `plutil`, `pfctl -n`, `newsyslog -n`; nothing
below).

1. **Installer, first run.** Homebrew installed as the normal user; then
   `sudo bash install.sh` to the end with a new tunnel and three new host
   names. Check on the way:
   * step 2: `dscl . -read /Users/_blossomfarm` shows the account (hidden,
     shell `/usr/bin/false`, home `/var/empty`, a number between 300 and
     499), and it does not appear in the login window or in System Settings →
     Users & Groups; `ls -ld /opt/farm` is `drwxr-x--- root _blossomfarm`;
   * step 3: the three programs start at all: `/opt/farm/bin/node/bin/node
     --version`, `/opt/farm/bin/mongodb/bin/mongod --version`,
     `/opt/farm/bin/cloudflared --version` (no Gatekeeper dialog, no "killed");
     Homebrew ran as the normal user, not as root;
   * step 4: `/opt/farm/bin/GADS --help` and `/opt/farm/bin/GADS-drag --help`
     run (the provider is cross-built on Linux without a C compiler: this is
     the first time it runs on a Mac);
   * step 9: the Cloudflare sign-in opens a browser although the installer
     runs as root, or prints the address; afterwards
     `/opt/farm/config/cloudflared/cert.pem` exists and nothing is left in
     `/opt/farm/var/login`;
   * step 11: `sudo pfctl -a com.apple/blossom-farm -s rules` prints the rule
     and `sudo pfctl -s info` says "Status: Enabled"; `sudo launchctl print
     system/blossom-farm.hub` says `state = running` (the restart service and
     the scripts read exactly that line) and names `_blossomfarm` as its user;
     `pmset -g` shows `sleep 0`.
2. **Every service runs as the right account and can do its work.**
   `ps -axo user,command | grep /opt/farm`: only the restart service (node)
   is root. `/opt/farm/logs` fills; `mongodb.log` shows MongoDB writing to
   `/opt/farm/data/mongodb`; `hub.log` shows the resource files unpacked into
   `/opt/farm/var/hub-files`; `keep-available.log` says "subscribed" and
   stays that way for an hour (one planned re-subscription every 15 minutes,
   no "a stream ended").
3. **Second run and interruption.** `sudo bash install.sh` again: it asks for
   the hub administrator password and offers the three host names (Enter
   keeps them); `launchctl print` shows the same `pid` for hub, provider,
   gate, restart and tunnel before and after. A third run, Ctrl+C at the
   password prompt: all services still running.
4. `sudo bash scripts/status.sh` reports no problem; `scripts/self-test.sh`
   passes; "Test connection" in Blossom is green; the Services panel shows
   every program; "Restart Provider" and "Restart all" work, and
   `/opt/farm/logs/restart-server.log` shows `stop blossom-farm.hub -> 0` and
   no "could NOT be stopped". (This is the first real use of the launchctl
   controller: `bootout`, the wait until `print` fails, `bootstrap`,
   `kickstart`.)
5. **One phone through `docs/phones.md`**, with the provider running as
   `_blossomfarm` and not as root: the phone asks "Trust This Computer?"
   once; WebDriverAgent is signed in the hub page (Apple Silicon: this needs
   Homebrew's `openssl@3`; note the exact error text when it is missing and
   correct the README row if it differs) and installed by the provider; the
   phone becomes live. In Blossom's Control page: picture (FFmpeg from
   Homebrew, found through `/opt/farm/bin/tools/ffmpeg`), tap, swipe,
   typing; with the AI assistant: `drag`, `source`, `open_url`. Unplug and
   replug the phone: no second Trust question
   (`/opt/farm/<nickname>/pair_records` holds a file).
6. **The packet filter rule.** With the phone live, `status.sh` lists the
   provider's per-phone ports as "closed to other computers by the kit's
   packet filter rule", and every one of them lies in the range of the rule.
   From a second computer on the same network `nc -vz <farm Mac> <one of
   those ports>` must fail, while `nc -vz 127.0.0.1 <port>` on the Mac
   succeeds, the phone stays live and the picture in Control keeps running
   (WebRTC is UDP and must not be touched). Outgoing connections from the Mac
   still work (`curl https://example.org`). Then `sudo pfctl -F all` (remove
   every rule) and wait five minutes: the rule is back
   (`/opt/farm/logs/firewall.log` says so).
7. **From another network**, without signing in: the same checks as point 5
   of the Windows list (401 on provider and restart, 403 on the three hub
   paths with `curl --path-as-is`, `X-Source-Code` on provider answers,
   `provider.log` without `token=`).
8. **Restart, unattended.** With FileVault off: restart the Mac and touch
   nothing, do not log in: within a few minutes the site is *Connected* and
   the phone live. `sudo pfctl -a com.apple/blossom-farm -s rules` shows the
   rule after the restart. Pull the power plug of a desktop Mac and put it
   back: it starts by itself. With FileVault on: confirm that the farm stays
   off until the password is typed, as the README says. On a MacBook: confirm
   the "Allow accessories to connect" behaviour described in `docs/phones.md`.
9. **Logs.** Let `provider.log` grow past 10 MB (or lower the size in
   `/etc/newsyslog.d/blossom-farm.conf` for the test) and run `sudo newsyslog
   -v`: the file is rotated and compressed, the provider was not restarted,
   and new lines arrive in the new `provider.log` with owner `_blossomfarm`.
10. `rotate-secrets.sh --all`; `update.sh` and `update.sh --rollback`;
    `uninstall.sh` then `install.sh` again (the farm comes back);
    `uninstall.sh --remove-data` (afterwards: no `/opt/farm`, no
    `_blossomfarm` in `dscl . -list /Users`, no `blossom-farm.*` in
    `/Library/LaunchDaemons`, no rule in the pf anchor).
11. **Moving a farm, all four ways**, each ending with a live phone and a
    green "Test connection" without touching Blossom: Mac → Mac, Windows →
    Mac, Mac → Windows, and (already in the Windows list) Windows → Windows.
    Note for each whether the phone asked "Trust This Computer?" again: the
    README says a phone that does not accept the provider's cached pairing
    asks once. For Windows → Mac, check that `import-farm.sh` unpacked an
    archive made by Windows PowerShell 5.1 (entry names with backslashes).
12. With `install.sh --with-appium`: Appium is installed as `_blossomfarm`
    under `/opt/farm/npm` and `/opt/farm/appium`, the provider starts, an
    Appium session opens through the provider host name, and the Appium port
    is inside the packet filter's range.
13. **Intel Mac** (if Intel stays supported): points 1 to 5; signing in the
    hub page fails as the README says and signing with zsign outside the hub
    works; FFmpeg from Homebrew is found in `/usr/local/bin`.

## A new patched provider (patch changed, or a newer GADS)

1. Change `patch/provider-drag.patch` and/or `gads.version`, `gads.commit` in
   `versions.json`. A newer GADS also means a new hub: update `hubZipUrl`,
   `hubZipSha256` (SHA-256 of upstream's `gads-win.zip`) and `hubExeSha256`
   (SHA-256 of the `GADS.exe` inside it), and the same three values under
   `macos.arm64.hub` and `macos.x86_64.hub` (`gads-mac-arm64.zip`,
   `gads-mac-amd64.zip` and the `GADS` inside each). Upstream publishes no
   checksums, so these are recorded by us: download the file twice, from two
   networks, and compare before pinning. Look at the macOS hub programs
   before pinning them: the version of macOS they were built for sets
   `minimumMacOS` (the v6.0.0 hub for Apple Silicon asks for macOS 26), and
   the signing helper inside them decides what `docs/phones.md` says about
   signing in the hub page (in v6.0.0 `resources/zsign-mac` is for Apple
   Silicon only and loads Homebrew's `openssl@3`).
2. Set `gadsDrag.releaseTag`, `gadsDrag.version`, `gadsDrag.url` and the two
   `macos.*.provider.url` to the new tag. Take `goVersion` from the `go` line
   of upstream's `go.mod`.
3. Build locally with the commands in `patch/README.md` and put the three
   SHA-256 values into `gadsDrag.sha256`, `macos.arm64.provider.sha256` and
   `macos.x86_64.provider.sha256`. (Or run the workflow by hand once: it
   prints the hashes it built before failing the comparison.)
4. Commit, wait for CI, tag `gads-…`, check the release, then test on a farm
   with `scripts\update.ps1` before a `kit-…` release. The `gads-…` release
   is not marked "Latest", so customers who follow the README keep getting
   the last tested kit in the meantime. A newer GADS can also expect another
   version of its Appium plugin (`targetAppiumPluginVersion` in
   `provider/provider.go`): put it into `versions.json` → `npm.gadsPlugin`.

Never move or re-create a published `gads-…` tag or replace its files:
installed kits pin its checksum.

## Pinned versions of the other programs

**macOS.** `versions.json → macos` pins, for each processor, the publisher's
archive of Node.js, MongoDB, the MongoDB Database Tools and cloudflared with
its SHA-256, at the same versions as the winget pins. Where the hashes come
from: Node.js publishes `SHASUMS256.txt` next to its archives; MongoDB
publishes `<archive>.sha256` for the server; Cloudflare lists, in the release
notes, the SHA-256 of the program *inside* its `.tgz` (that is
`cloudflared.exeSha256`; the hash of the `.tgz` itself is recorded by us);
the MongoDB Database Tools come without a published hash and are recorded by
us (download twice, compare). `minimumMacOS` is the highest "built for
macOS" value among the pinned programs for that processor. FFmpeg and
OpenSSL come from Homebrew at whatever version Homebrew has that day:
Homebrew verifies its own packages, and the kit pins nothing there.

**Windows.** `versions.json → winget` pins exact versions. winget removes old versions of
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

## Licence duties when publishing the `GADS-drag` programs

Read `NOTICE`, section 2. In short: the programs are AGPL-3.0, so every
release that carries them carries the licence text, their source archive
(with the module sources, the build instructions and the statement of
modifications) and the licence notices of the libraries compiled into them
(the union over the three programs); the workflow makes and attaches all of
them. The programs must stay free of `hub-ui` (the workflow
builds without the `ui` tag and checks that the submodule folder is empty).
The patch marks the files it changes as modified and makes the provider
announce where its source is (`X-Source-Code`); keep both when the patch
changes. The question of the files embedded from upstream's `resources/`
directory is yours to decide, and the workflow waits for that decision
("Before the first gads release" above).
