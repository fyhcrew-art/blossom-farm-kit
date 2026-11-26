# Releasing (for maintainers of this repository)

This repository has no build service. Nothing is built or published by a
machine that somebody else runs: **a maintainer builds on their own
computer, and git carries the result.** What makes that safe to rely on is
not where a file was built, but that everything a customer's computer
downloads is fetched **by commit** and checked against a **pinned SHA-256**,
and that the build of the provider can be repeated by anybody, bit for bit.

| What | Where it lives | Made with |
|---|---|---|
| the patched provider: `GADS-drag.exe` (Windows x64), `GADS-drag-darwin-arm64`, `GADS-drag-darwin-amd64` (macOS), with `SHA256SUMS`, the source archive, `THIRD-PARTY-NOTICES.txt`, `LICENSE-AGPL-3.0.txt`, `BUILD.md`, `MODIFICATIONS.md` | the branch **`dist`**, one folder per provider version (`gads-v6.0.0-drag.1/`). An orphan branch: it shares no history with the kit and holds nothing else | `tools/build-provider.sh`, `tools/publish-dist.sh` |
| the kit | a commit on **`main`**. `versions.json` names each provider program by the address of one commit of `dist` and by its SHA-256 | `tools/release.sh kit` |
| which kit is the released one | `pairing.json` on `main`, in the commit after the kit's: the kit version, the kit commit, the SHA-256 of its two bootstrap files and of its `MANIFEST.sha256` | `tools/release.sh pairing` |

There are no tags and no GitHub Releases in this flow, and no Git LFS: every
published file is an ordinary file in a git commit, below GitHub's limit of
100 MB per file (the provider programs are about 80 MB each; the tools
refuse a larger file).

Who downloads what:

* the installers fetch the provider from
  `https://raw.githubusercontent.com/fyhcrew-art/blossom-farm-kit/<commit of dist>/<folder>/<file>`
  and compare its SHA-256 with `versions.json`;
* the command Blossom CRM shows fetches `bootstrap.ps1` or `bootstrap.sh`
  from `https://raw.githubusercontent.com/fyhcrew-art/blossom-farm-kit/<kit commit>/`
  and compares its SHA-256 with the value in the command; the bootstrap file
  fetches `https://github.com/fyhcrew-art/blossom-farm-kit/archive/<kit commit>.zip`
  (`.tar.gz` on macOS) and checks every file against `MANIFEST.sha256`;
* a customer without the command presses **Code → Download ZIP** on `main`;
* `update -Latest` reads `versions.json` and `pairing.json` from `main` and
  then fetches the archive of the commit `pairing.json` names.

An address with a commit in it cannot start giving other bytes: a commit
does not change. **Never delete the branch `dist`, never rewrite it (no
force-push), and never rewrite `main`:** a commit that no branch reaches any
more is removed by GitHub after a while, and every kit and every command
that names it would stop with a download error. Only ever add commits.

## Before the first provider publication: a decision only you can take

Every `GADS-drag` program embeds upstream's `resources` folder, as every GADS binary
does: Apple's developer disk image for iOS 17+, and pre-built helper files
(`NOTICE`, section 2b). Publishing the binary makes this repository a
distributor of those files. Upstream publishes the same files; that does not
settle whether you may. `tools/publish-dist.sh` therefore **publishes
nothing** until `versions.json` contains

```json
"redistributeEmbeddedResources": true
```

under `gadsDrag`. Setting it is the record of your decision (who set it and
when is in the git history). The value does not change the binary or its
checksum. If you decide against publishing, the alternative is in
`patch/README.md`: build the provider on the farm computer and install it
with `install.ps1 -ProviderExe <path>` or `install.sh --provider-binary
<path>`.

If a published `GADS-drag` file ever has to be taken down (the branch `dist`
removed): running farms are not affected (they have the file), and new
installs and updates stop at step 4 with "is not at its download address
(HTTP 404)" until a kit points somewhere else or the customer passes
`-ProviderExe` / `--provider-binary`.

## Checking the kit: `tools/check.sh`

```sh
bash tools/check.sh                # everything this computer has the tools for
bash tools/check.sh --require-all  # a check that cannot run, or a test that skips itself, counts as failed
bash tools/check.sh --upstream     # also: the patch applies to the pinned upstream commit (network)
```

It runs, where the tool is installed: the check that `MANIFEST.sha256` is up
to date; `bash -n` and shellcheck on every `.sh`; the bash tests
(`tests/farmkit.test.sh`, `tests/pairing.test.sh`, `tests/bootstrap.test.sh`,
the first two also in POSIX mode); the JSON reader with every awk at hand;
the Node tests; the rendered launchd property lists; on a Mac `pfctl -n` on
the packet filter rule; with `powershell` or `pwsh`, the parse and ASCII
check of every PowerShell file, PSScriptAnalyzer and the Pester tests. The
pairing, bootstrap and update tests talk https to `tests/fake-blossom.js`, a
stand-in for Blossom's pairing API and for the places a kit is fetched from;
they prove the client against the contract, not against Blossom itself (the
checklists below do that). `tests/bootstrap.test.sh` and
`tests/Bootstrap.Tests.ps1` also run `scripts/update.sh --latest` and
`scripts\update.ps1 -Latest` as whole scripts, from a copy of the kit, against
that stand-in: a newer kit that is taken, and every kind of kit that must be
refused with the installed kit left as it was.

**Read the end of the output.** The last line is "All ... checks passed;
nothing was skipped" only when that is true. When a tool is missing, or
tests skipped themselves inside a suite, they are listed under "Skipped" and
the last line says that the run is not complete. On Linux and macOS the
script makes a certificate for the stand-in server and hands it to
PowerShell, so that the Pester tests which fetch a kit do run there; if they
still skip themselves (no node, no openssl), the count is under "Skipped".

One computer does not have every tool. Before a kit release, run it on:

* **Linux**, with shellcheck 0.11.0, node, and PowerShell 7 with Pester
  5.7.1 and PSScriptAnalyzer 1.24.0 (`--require-all`);
* **a Mac**: `bash tools/check.sh`. This is where the shell scripts meet the
  bash 3.2, awk, sed, curl and tar of macOS before a farm does. Read the
  output, not only the last line;
* **Windows**, in an Administrator *Windows PowerShell* (5.1) window, for the
  PowerShell half. Either `bash tools/check.sh` from Git Bash, or by hand:

  ```powershell
  Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser
  Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Force -Scope CurrentUser
  Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
  $env:FARMKIT_REQUIRE_STAND_IN = '1'; Invoke-Pester .\tests
  node --test tests\restart-server.test.js tests\provider-gate.test.js tests\fake-blossom.test.js
  ```

## Publishing the provider programs

Do this once per provider version: the first time, and whenever the patch,
the upstream commit or the Go version changes ("A new patched provider"
below). On Linux x64, with git and Go installed (any recent Go: the pinned
version is downloaded by Go itself, and the script checks which one runs).

1. **Build.**

   ```sh
   bash tools/build-provider.sh --out /tmp/gads-drag
   ```

   It checks out upstream GADS at the commit pinned in `versions.json`
   (without the `hub-ui` submodule), applies `patch/provider-drag.patch`,
   generates the docs package with the pinned `swag`, builds the three
   programs with `CGO_ENABLED=0 -trimpath -buildvcs=false`, runs `go vet`
   and the provider's tests, makes the source archive, the notices and the
   licence text (`tools/make-source-archive.sh`), writes `SHA256SUMS`, and
   compares the three programs with the SHA-256 values pinned in
   `versions.json`. It must end with **"Reproduced the three pinned SHA-256
   values"**. If it reports a different value and nothing was changed on
   purpose, do not publish: find out why (the usual cause is another Go
   version; `versions.json` pins `goVersion`).
2. **Build again, somewhere else,** to see for yourself that the result does
   not depend on the folder or on what was cached: another `--out`, another
   `--work` folder, `GOCACHE` pointing at an empty folder. The two output
   folders must hold identical programs (`sha256sum` of both). The pinned
   values in `versions.json` were produced this way.
3. **Publish.**

   ```sh
   bash tools/publish-dist.sh --from /tmp/gads-drag --push
   ```

   It refuses anything that does not match `versions.json` or its own
   `SHA256SUMS`, any file of 100 MB or more, and any change to a program
   that is already on `dist`. It adds one commit to the local branch `dist`
   (created as an orphan branch the first time), never touches the working
   tree, pushes with `git push origin dist`, and prints the commit and the
   three addresses. If the push is refused for its size, run it again with
   `--one-file-per-commit` on a fresh `dist` (`git branch -D dist` first, if
   nothing was pushed).
4. **Put the three addresses into `versions.json`** (`gadsDrag.url`,
   `macos.arm64.provider.url`, `macos.x86_64.provider.url`). They all name
   the same commit of `dist`.
5. `bash tools/release.sh kit` (next section) downloads the three files from
   those addresses and compares them with the pinned values before it lets a
   kit be committed.

**Correcting the papers of a published version.** A program on `dist` is
never replaced. What lies next to it (`BUILD.md`, `MODIFICATIONS.md`, the
source archive, the notices, `SHA256SUMS`) can be: when the build
instructions or the source archive turn out to be wrong, fix
`tools/make-source-archive.sh`, build again (the three programs must come
out with the pinned SHA-256 values, twice), and publish with

```sh
bash tools/publish-dist.sh --from /tmp/gads-drag --correct-papers --push
```

which is refused unless the three programs are the published ones byte for
byte. It adds a commit to `dist`; the commit before it stays, and the
addresses that name it keep working. Put the new commit into the three
addresses of `versions.json` with the next kit release, so that the commit
a kit names holds the corrected papers. Then prove the correction: unpack
the published source archive, follow its `BUILD.md` to the letter, and
compare the three results with `SHA256SUMS`. (This was done once, for
`gads-v6.0.0-drag.1`: the first archive kept its note about Apple's
developer disk image inside `resources/`, a folder the program embeds, so a
rebuild that followed `BUILD.md` gave other checksums. The note is now at
the top of the tree, outside `resources/`.)

What is being claimed, and what is not: the programs are built on a
maintainer's computer, not on a neutral build service, so the fact that they
were built from the published source rests on that maintainer **unless
somebody checks**. Anybody can: the build is reproducible, the recipe
(`tools/build-provider.sh`, `BUILD.md` next to the programs) and the
checksums are public, and a rebuild that gives other checksums would show
that something is wrong. `patch/README.md` tells an outsider how.

## A kit release: two commits

A release is the commit that holds the kit, and one more commit that says
"that one is the released kit". They cannot be the same commit: a commit's
name is a checksum over its content, so a file cannot contain the name of
the commit it is in.

**Step 1: the kit commit.** Set `"kit"` in `versions.json` to the new version
(it must be higher than the last released one: installed kits refuse
anything else), then:

```sh
bash tools/release.sh kit
git add -A && git status        # look: nothing from a real farm, no binary
git commit -m 'Kit 1.0.0'
git push origin main
```

`release.sh kit` regenerates `MANIFEST.sha256` and writes its SHA-256 into
`bootstrap.sh` and `bootstrap.ps1` (`tools/make-manifest.sh`), downloads the
three provider programs from the addresses in `versions.json` and compares
them with the pinned SHA-256 values, and runs `tools/check.sh`. Call the
commit you pushed **K**.

**Step 2: `pairing.json`.** With K checked out, clean and pushed:

```sh
bash tools/release.sh pairing
git push origin main
```

It fetches `bootstrap.sh` and `bootstrap.ps1` of K from GitHub and compares
them with the files of the commit, runs the fetched `bootstrap.sh` with
`--verify-only` (the whole chain against GitHub: archive of K, list, every
file), and then writes and commits `pairing.json`:

```json
{
  "kitVersion": "1.0.0",
  "kitCommit": "<K>",
  "bootstrapShSha256": "<SHA-256 of bootstrap.sh in K>",
  "bootstrapPs1Sha256": "<SHA-256 of bootstrap.ps1 in K>",
  "manifestSha256": "<SHA-256 of MANIFEST.sha256 in K>"
}
```

That commit changes `pairing.json` and nothing else (the script checks).
`pairing.json` is not on the list of files, so K's `MANIFEST.sha256` stays
true for the commit after it.

**K must be a commit of `main`, under the name it has.** If the two commits
were made on another branch, bring them to `main` with a fast-forward
(`git checkout main && git merge --ff-only <branch> && git push origin
main`) or with a merge commit. **Never squash or rebase them:** that makes
new commits with new names, `pairing.json` would name a commit that is not
on `main`, and once the branch is deleted GitHub removes that commit and
every command stops with a download error. For the same reason, do not
delete a branch that holds a released commit before `main` holds it too.

**Step 3: prove it from the outside.**

```sh
bash tools/release.sh verify
```

downloads the three provider programs and checks their SHA-256, fetches the
bootstrap files of K and runs the chain with `--verify-only`, checks that a
kit with one changed line is refused, and says whether `main` on GitHub
already shows this release.

**Step 4: the acceptance checklists** below, on a Windows PC and on a Mac,
each with a phone, following the README as a customer would. For the pairing
points you need a Blossom that shows this release ("A kit release and
Blossom CRM"): a staging deployment, never production. The checklists come
after the push because the command needs the commit to be on GitHub. If a
checklist fails, fix the kit and make a new release with a higher version;
until then, set `pairing.json` on `main` back to the last good release
(a new commit with the previous content of the file), so that Blossom and
`update -Latest` stop offering the kit that failed.

### `MANIFEST.sha256` in daily work

Every commit to `main` that changes a file of the kit must carry an
up-to-date list: run `bash tools/make-manifest.sh` before committing.
`tools/check.sh` and `tests/bootstrap.test.sh` fail when it was forgotten
("MANIFEST.sha256 does not describe the files of the kit"). The list
describes the files as GitHub's archive of the commit holds them (tracked
files, line ends as `.gitattributes` gives them), which is why it is made
from git and not from the folder. `bootstrap.ps1` is kept with LF line ends
on purpose: it is fetched by itself and pinned by its SHA-256, and must be
the same bytes everywhere.

Commits to `main` between two releases are harmless to customers who use the
command: `pairing.json` keeps naming K until the next release. They are
**not** invisible to customers who press "Download ZIP": those get `main` as
it is that day. Keep `main` in a state you would hand to a customer, and do
unfinished work on a branch.

## A kit release and Blossom CRM

The command Blossom shows under *Connect a computer* carries the kit commit
and the SHA-256 of that commit's bootstrap file. Blossom's server reads both
from `pairing.json` on `main`
(`https://raw.githubusercontent.com/fyhcrew-art/blossom-farm-kit/main/pairing.json`)
and keeps them; nothing has to be handed over by hand, and a release reaches
Blossom when its cache of that file is next refreshed.

What follows from that:

* **`pairing.json` on `main` is the switch.** Pushing the second commit
  makes the release the one Blossom offers and `update -Latest` fetches.
  Until it is pushed, nothing changes for anybody.
* **Whoever can push to `main` can release.** Protect the account
  (two-factor sign-in) and the branch (in the repository's settings: no
  force-push to `main`, no deletion). `docs/security.md`, section 9, says
  this to customers in plain words; do not let the documentation claim more.
* **Never rewrite `main` or `dist`.** Every command Blossom has shown names
  a commit, and every installed kit names a commit of `dist`.
* To try a release before Blossom shows it, write the command by hand, with
  the values of `pairing.json`. Windows (in an Administrator PowerShell):

  ```powershell
  $f = "$env:TEMP\blossom-bootstrap.ps1"; [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/fyhcrew-art/blossom-farm-kit/<kitCommit>/bootstrap.ps1' -OutFile $f; if ((Get-FileHash $f -Algorithm SHA256).Hash -ne '<bootstrapPs1Sha256>') { Remove-Item $f; throw 'The downloaded file is not the one Blossom expects. Nothing was run.' }; powershell -NoProfile -ExecutionPolicy Bypass -File $f -KitCommit '<kitCommit>' -AppOrigin 'https://<staging Blossom>' -PairingCode '<code>'
  ```

  macOS (in Terminal):

  ```sh
  cd ~ && curl -fsSL --proto '=https' --tlsv1.2 -o blossom-bootstrap.sh 'https://raw.githubusercontent.com/fyhcrew-art/blossom-farm-kit/<kitCommit>/bootstrap.sh' && echo '<bootstrapShSha256>  blossom-bootstrap.sh' | shasum -a 256 -c - && sudo bash blossom-bootstrap.sh --kit-commit '<kitCommit>' --app-origin 'https://<staging Blossom>' --pairing-code '<code>'
  ```

  Without `-AppOrigin`/`-PairingCode` (`--app-origin`/`--pairing-code`) the
  same command installs without pairing; with `-VerifyOnly` /
  `--verify-only` appended (and without `sudo`) it only fetches and checks.
* The pairing tests run against a stand-in. The pairing points of the two
  checklists below are run against a real Blossom deployment (staging)
  before every kit release; when something differs there, correct the kit,
  the stand-in and the contract document together.
* The HTTP contract between the kit and Blossom is what `tests/fake-blossom.js`
  implements. When Blossom's side changes, change the stand-in first and let
  the tests of both systems say what the kit has to follow.

## Acceptance checklist for a kit release: Windows

On a spare Windows PC (or a virtual machine), never the production farm. Do
the points in this order.

1. **The kit folder.** Unpack the kit inside `Downloads` and run
   `install.ps1` there: it stops with "is not in a protected place" and
   changes nothing. Move the folder to `C:\blossom-farm-kit` and run it
   again: `icacls C:\blossom-farm-kit` and `icacls
   C:\blossom-farm-kit\lib\FarmKit.psm1` then show Administrators and SYSTEM
   with full control and Users with read only, and a standard user cannot
   save a change to a file in it.
2. `install.ps1` to the end, with a new Cloudflare tunnel and three new host
   names. Run it a second time: it must change nothing and ask only for the
   hub administrator password. During that second run `Get-Service
   GadsProvider, KeepAvailable` must stay *Running* the whole time; press
   Ctrl+C at the password prompt of a third run and check that all services
   are still running afterwards. `install.ps1 -Nickname Logs` stops at step 2
   with "a folder the kit itself uses".
3. `scripts\status.ps1` reports no problem; `scripts\self-test.ps1` asks for
   the password of `blossom` (the computer is not paired yet), passes, and
   lists thirteen steps, among them "Hub refuses reports from outside". With
   a wrong password it fails at Hub sign-in and names `-HubUser admin`.
   With a phone connected, `status.ps1` lists the provider's per-phone ports
   as "closed to other computers by the kit's firewall rule"; from a second
   computer on the same network, `Test-NetConnection <farm PC> -Port <one of
   those ports>` must fail, and the phone must still be live with picture in
   Blossom (the rule must not disturb the provider).
4. "Test connection" in Blossom is green; the Services panel shows every
   program and "Restart Provider" works.
5. One phone through `docs/phones.md`. In Blossom's Control page: picture,
   tap, swipe, typing; with the AI assistant: `drag`, `source`, `open_url`.
6. From another network, without signing in: `https://<provider host>/devices`
   and `https://<restart host>/status` answer 401;
   `https://<hub host>/device/x/appium/status`, the same address with
   `%61ppium`, `https://<hub host>/admin/provider/Provider1/info` and
   `https://<hub host>/provider-update` (GET and POST) answer 403 (`curl
   --path-as-is`). With a valid hub token,
   `https://<provider host>/%64ebug/pprof/heap` answers 404, and any answer
   of the provider host carries the header `X-Source-Code`. After a Control
   session, `C:\farm\logs\provider.log` shows the `ios-webrtc` line
   without `token=`.
7. Restart the PC and touch nothing, **without signing in to Windows**:
   everything comes back by itself, the phones included. (This is the check
   that Apple's USB support runs as a service; `docs/phones.md`, section 0.)
   In Blossom's Services panel, "Restart all" restarts the hub too:
   `C:\farm\logs\restart-server.log` shows `stop GadsHub -> 0` and no
   "could NOT be stopped". By hand: `Stop-Service GadsHub` is refused by
   PowerShell while its dependants run, `Restart-Service GadsHub -Force`
   restarts the hub, `GadsProvider` and `KeepAvailable`, as the README says.
8. `rotate-secrets.ps1 -All`; `update.ps1` and `update.ps1 -Rollback`;
   `export-farm.ps1`, then `import-farm.ps1` and `install.ps1` on a second
   machine; `uninstall.ps1 -RemoveData`. **Fetching a newer kit:**
   `update.ps1 -Check` says that this kit is the newest one. To see a fetch
   happen, lower `"kit"` in `C:\blossom-farm-kit\versions.json` by hand (for
   example to `0.0.1`), then `update.ps1 -Check` names the released kit and
   `update.ps1 -Latest` fetches it, reports every file checked, prints the
   commit and two lines with the versions of the kit, of GADS and of the
   provider (this kit, new kit) **before** the folder is replaced, keeps the
   old folder as `C:\blossom-farm-kit.previous` (`icacls` on the new folder
   as in point 1), and continues into the update. With the network cable
   pulled, `-Latest` stops with "could not be read" and changes nothing.
   While `-Latest` or the command from Blossom downloads, `dir C:\` shows a
   folder `blossom-farm-kit.new-` followed by 32 digits and letters; `icacls`
   on it shows Administrators and SYSTEM with full control and Users with
   read only, and nothing inherited; it is gone at the end, also after a
   refusal. As a standard user, create `C:\blossom-farm-kit.new` with a file
   in it beforehand: the run neither uses nor removes that folder.
9. With `install.ps1 -WithAppium`: the provider starts, and an Appium session
   opens through the provider host name. In the registry,
   `HKLM:\SYSTEM\CurrentControlSet\Services\GadsProvider\Parameters`,
   `AppEnvironmentExtra` holds three separate entries (`APPIUM_HOME`,
   `NPM_CONFIG_PREFIX`, `PATH`), and the provider log does not show it
   installing the GADS Appium plugin by itself.
10. As a standard (non-administrator) user create `C:\farm\bin` with a file in
    it on a clean PC, then run `install.ps1` as Administrator: it must stop at
    step 2 with "already exists and cannot be used".
11. **Pairing** (against a staging Blossom; if it does not show this release
    yet, with the command written by hand as in "A kit release and Blossom
    CRM"):
    * the command with `-VerifyOnly` appended, in a PowerShell window that
      is *not* Administrator: it reports every file checked and "nothing was
      installed", and `C:\blossom-farm-kit` does not exist afterwards;
    * on a clean PC the one command, pasted into an Administrator
      PowerShell, ends with "Blossom sees your farm"; the kit is in
      `C:\blossom-farm-kit`, and `icacls C:\blossom-farm-kit` shows
      Administrators and SYSTEM with full control and Users with read only;
    * Blossom showed "Computer connected" during the installation, then the
      computer's name, its country and the three addresses; after Confirm
      the site is green, and no password or secret appeared in the
      PowerShell window at any point;
    * the same command a second time: "this very code" is recognised,
      nothing is asked of Blossom twice, the site stays as it is;
    * change one character of the hash in the command: it stops with "not
      the one Blossom expects" and `C:\blossom-farm-kit` is untouched;
      change one character of the commit instead: it stops because GitHub
      has no such commit, and nothing is touched either;
    * a command with an expired code: the installation completes and prints
      the values for manual entry;
    * `rotate-secrets.ps1 -HubUser -RestartSecret` shows no value and Blossom
      keeps working (phone list, Services panel) without anybody typing;
    * `scripts\self-test.ps1` now says that it signs in as "admin", asks for
      the hub administrator's password, and passes;
    * `scripts\status.ps1` shows the pairing; after "Unpair computer" in
      Blossom it reports that Blossom no longer accepts this computer, and
      `rotate-secrets.ps1 -HubUser` then prints the new password;
    * `icacls C:\farm\config\pairing.json` shows Administrators and SYSTEM
      only, the file holds a `workspaceId`, and nothing in `C:\farm\logs`
      contains `bft_`;
    * behind a proxy that opens https (or with the PC's clock set a year
      back) the installer says that the certificate could not be verified
      and sends nothing;
    * `export-farm.ps1` / `import-farm.ps1` to a second PC: `rotate-secrets`
      there still reaches Blossom (the pairing moved);
    * `uninstall.ps1 -RemoveData`, answer `y` to the unpair question: Blossom
      shows the computer as unpaired.
12. **A command from another workspace** (a second workspace on the staging
    Blossom, given the same name as the first). On the paired PC:
    * a new command from the *first* workspace runs without a question;
    * the command of the second workspace shows both workspaces and asks for
      the word `replace`. Answer anything else: the installer stops with
      "The pairing of this computer was not changed", the site in the first
      workspace keeps working (phone list, `rotate-secrets.ps1 -HubUser`),
      and the second workspace shows no computer waiting;
    * the same command started without a keyboard (`powershell
      -NonInteractive`, or through a scheduled task) stops the same way;
    * a new command of the second workspace, with `replace` typed: the farm
      moves, and the first workspace shows the computer as unpaired;
      another one with `-ReplacePairing` appended moves it back without a
      question.
13. **What an admin confirms** (these are rules of Blossom; check them
    against the staging deployment):
    * with a computer waiting on the confirm card, run the installer again
      with another `-HubHost`: the card changes, says that the computer sent
      different addresses, and a Confirm pressed on the old card is refused;
    * on a confirmed, working site, run the installer with another
      `-HubHost`: the site stays *Connected* on its confirmed addresses, its
      card offers "Review", and Decline leaves everything as it was;
    * a second computer sends the hub address of a site that exists: Confirm
      without ticking "This replaces your site" is refused; ticked, with a
      failed check, it is refused; ticked, with a check that passed, the
      site is replaced and the first computer shows as unpaired.

## Acceptance checklist for a kit release: macOS

On a spare Mac with Apple Silicon and the macOS version named in
`versions.json` (`macos.arm64.minimumMacOS`), and on an Intel Mac for point
14. Most points need a real iPhone. Do the points in this order, and write
down every command that had to be changed.

Before anything else, `bash tools/check.sh` was run on this Mac, from a
checkout of the commit, and its last line was "All ... checks passed;
nothing was skipped" (it covers the scripts with the bash 3.2, awk and sed
of macOS, `plutil` and `pfctl -n`; nothing below). `tests/bootstrap.test.sh`
is the part that matters most there: it is where the comparison of a fetched
kit with its list, and `scripts/update.sh --latest` as a whole, meet the awk,
sort, comm, find and tar of macOS. If it reports a failure on the Mac and
not on Linux, the difference is a finding: do not release.

1. **The kit folder and the installer, first run.** Homebrew installed as
   the normal user. Unpack the kit to `~/blossom-farm-kit` and run `sudo
   bash install.sh` there: it says that the kit is copied to
   `/opt/blossom-farm-kit` and continues from there by itself; `ls -ld
   /opt/blossom-farm-kit /opt/blossom-farm-kit/lib/farmkit.sh` shows `root`
   and no write permission for group or others. Then to the end with a new
   tunnel and three new host names. `sudo bash install.sh --nickname
   Services` stops at step 2 with "a folder the kit itself uses". Check on
   the way:
   * step 2: `dscl . -read /Users/_blossomfarm` shows the account (hidden,
     shell `/usr/bin/false`, home `/var/empty`, a number between 300 and
     499), and it does not appear in the login window or in System Settings →
     Users & Groups; `ls -ld /opt/farm` is `drwxr-x--- root _blossomfarm`;
   * step 3: the three programs start at all: `/opt/farm/bin/node/bin/node
     --version`, `/opt/farm/bin/mongodb/bin/mongod --version`,
     `/opt/farm/bin/cloudflared --version` (no Gatekeeper dialog, no "killed");
     Homebrew ran as the normal user, not as root;
   * step 4: `/opt/farm/bin/GADS --help` and `/opt/farm/bin/GADS-drag --help`
     run (the provider is cross-built on Linux without a C compiler; a Mac
     is where that is confirmed);
   * step 9: the Cloudflare sign-in opens a browser although the installer
     runs as root, or prints the address; afterwards
     `/opt/farm/config/cloudflared/cert.pem` exists and nothing is left in
     `/opt/farm/var/login`;
   * step 11: `sudo pfctl -a com.apple/blossom-farm -s rules` prints the rule
     and `sudo pfctl -s info` says "Status: Enabled"; `sudo launchctl print
     system/blossom-farm.hub` says `state = running`, shows a line `pid =
     <number>` (the restart service and the scripts read exactly these two
     lines) and names `_blossomfarm` as its user; `ps -o command= -p
     <number>` shows `/opt/farm/bin/GADS hub ...` and not `farm-run.sh`;
     `pmset -g` shows `sleep 0`.
2. **Every service runs as the right account and can do its work.**
   `ps -axo user,command | grep /opt/farm`: only the restart service (node)
   is root. `ls -ld /opt/farm/logs-root` is `drwx------ root`, it holds
   `restart-server.log` and `firewall.log`, and nothing in `/opt/farm/logs`
   belongs to root. `/opt/farm/logs` fills; `mongodb.log` shows MongoDB writing to
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
   `/opt/farm/logs-root/restart-server.log` shows `stop blossom-farm.hub -> 0` and
   no "could NOT be stopped" (the launchctl controller: `bootout`, the wait
   until `print` fails, `bootstrap`, `kickstart`). Then **a service that
   only waits is not "running"**: `sudo launchctl bootout
   system/blossom-farm.mongodb` and restart the hub (`sudo launchctl
   kickstart -k system/blossom-farm.hub`). `status.sh` must say that the hub
   "waits for the service it needs", and the Services panel in Blossom must
   show the hub as not running. `sudo launchctl bootstrap system
   /Library/LaunchDaemons/blossom-farm.mongodb.plist`: within two minutes
   everything reads running again.
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
   (`/opt/farm/logs-root/firewall.log` says so).
7. **From another network**, without signing in: the same checks as point 6
   of the Windows list (401 on provider and restart, 403 on the four hub
   paths with `curl --path-as-is`, `X-Source-Code` on provider answers,
   `provider.log` without `token=`).
8. **Restart, unattended.** With FileVault off: restart the Mac and touch
   nothing, do not log in: within a few minutes the site is *Connected* and
   the phone live. `sudo pfctl -a com.apple/blossom-farm -s rules` shows the
   rule after the restart. Pull the power plug of a desktop Mac and put it
   back: it starts by itself. With FileVault on: confirm that the farm stays
   off until the password is typed, as the README says. On a MacBook: confirm
   the "Allow accessories to connect" behaviour described in `docs/phones.md`.
9. **Logs.** There is no `/etc/newsyslog.d/blossom-farm.conf`. Let
   `provider.log` grow past 10 MB (to see it sooner, start a second wrapper
   by hand as the service account: `sudo -u _blossomfarm /bin/bash
   /opt/farm/services/farm-run.sh --log /opt/farm/logs/try.log --log-max-kb
   64 --log-keep 2 -- /usr/bin/yes line` for a few seconds): the log is put
   aside as `<log>.1.gz`, at most the number named is kept, the files
   belong to `_blossomfarm`, the program was not restarted (same `pid`), and
   new lines arrive in the new log.
10. **Replacing the programs (Apple Silicon).** Note `ls -i /opt/farm/bin/GADS
    /opt/farm/bin/GADS-drag`. Run `sudo bash scripts/update.sh` (the same
    kit is enough: the script replaces both programs either way): both
    numbers have changed, the script ends with "Updated and running", the
    hub answers on port 10000, and neither `hub.log` nor `log show --last 5m
    --predicate 'eventMessage CONTAINS "Code Signature Invalid"'` shows a
    killed program. The same after `sudo bash scripts/update.sh --rollback`.
    **Fetching a newer kit:** `sudo bash scripts/update.sh --check` says
    that this kit is the newest one; with `"kit"` in
    `/opt/blossom-farm-kit/versions.json` lowered by hand (for example to
    `0.0.1`), `--check` names the released kit and `--latest` fetches it,
    reports every file checked, prints the commit and two lines with the
    versions of the kit, of GADS and of the provider (this kit, new kit)
    **before** the folder is replaced, keeps the old folder as
    `/opt/blossom-farm-kit.previous`, leaves the new one owned by root and
    not writable by anybody else, and continues into the update.
    With the provider program downloaded **in a browser** from its address in
    `versions.json` (`macos.arm64.provider.url`): delete `/opt/farm/bin/GADS-drag`, run `sudo bash install.sh
    --provider-binary ~/Downloads/GADS-drag-darwin-arm64`; `xattr
    /opt/farm/bin/GADS-drag` lists no `com.apple.quarantine`, and the
    provider starts.
11. `rotate-secrets.sh --all`;
    `uninstall.sh` then `install.sh` again (the farm comes back);
    `uninstall.sh --remove-data` (afterwards: no `/opt/farm`, no
    `_blossomfarm` in `dscl . -list /Users`, no `blossom-farm.*` in
    `/Library/LaunchDaemons`, no rule in the pf anchor).
12. **Moving a farm, all four ways**, each ending with a live phone and a
    green "Test connection" without touching Blossom: Mac → Mac, Windows →
    Mac, Mac → Windows, and (already in the Windows list) Windows → Windows.
    Note for each whether the phone asked "Trust This Computer?" again: the
    README says a phone that does not accept the provider's cached pairing
    asks once. For Windows → Mac, check that `import-farm.sh` unpacked an
    archive made by Windows PowerShell 5.1 (entry names with backslashes).
13. With `install.sh --with-appium`: Appium is installed as `_blossomfarm`
    under `/opt/farm/npm` and `/opt/farm/appium`, the provider starts, an
    Appium session opens through the provider host name, and the Appium port
    is inside the packet filter's range.
14. **Intel Mac**: points 1 to 5; signing in the hub page fails as the README
    says and signing with zsign outside the hub works. FFmpeg both ways:
    from Homebrew it is found in `/usr/local/bin`; without Homebrew's, a
    static FFmpeg downloaded in a browser to `~/Downloads` and named once
    with `--ffmpeg` is copied to `/opt/farm/bin/tools/ffmpeg` (`ls -l`:
    `root _blossomfarm`, mode 750, a file and not a link; `xattr` lists no
    `com.apple.quarantine`), the installer says "FFmpeg with the libx264
    encoder", Control shows a picture, and a later `sudo bash install.sh`
    without the option keeps that file and asks Homebrew for nothing.
15. **Pairing** (against a staging Blossom; if it does not show this release
    yet, with the command written by hand as in "A kit release and Blossom
    CRM"): the same points as numbers 11, 12 and 13 of the Windows list, with
    these differences. `--verify-only` is tried without `sudo`. The command is pasted into
    Terminal; `shasum -a 256 -c` prints "OK" before `sudo` asks for the
    password. The kit is in `/opt/blossom-farm-kit`, owned by root and not
    writable by anybody else (`ls -ld`). `/opt/farm/config/pairing.json` is
    `-rw------- root`. While the installer sends the farm, `ps axww | grep
    curl` in a second Terminal window shows no password, secret or token
    (they go to curl through its standard input). The curl of macOS refuses
    a certificate it cannot verify: check it with the clock set back. The
    question about another workspace is asked in the Terminal window
    although the installer was started through `sudo bash
    blossom-bootstrap.sh`; "without a keyboard" is `sudo bash
    /opt/blossom-farm-kit/install.sh --app-origin … --pairing-code … <
    /dev/null` started through `ssh -T` or `launchctl asuser`, where there
    is no terminal.

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
2. Give the provider a **new version**: `gadsDrag.version` (for example
   `v6.0.0-drag.2`) and `gadsDrag.releaseTag` (`gads-v6.0.0-drag.2`, the name
   of its folder on `dist`). A program that changed never keeps its version:
   installed kits refuse a kit that pins another file under a version they
   know, and `tools/publish-dist.sh` refuses to change a published folder.
   Take `goVersion` from the `go` line of upstream's `go.mod`.
3. Build once with `bash tools/build-provider.sh --out <folder>
   --no-pin-check`: it prints the three SHA-256 values. Put them into
   `gadsDrag.sha256`, `macos.arm64.provider.sha256` and
   `macos.x86_64.provider.sha256`.
4. Go on as in "Publishing the provider programs": build again without the
   option, in another folder (it must reproduce the values), publish, put
   the three new addresses into `versions.json`. Do all of this on a branch,
   and test on a farm with the kit of that branch (`scripts\update.ps1`
   without an option, from a folder you unpacked) before a kit release:
   customers get nothing of it until `main` moves. A newer GADS can also
   expect another version of its Appium plugin (`targetAppiumPluginVersion`
   in `provider/provider.go`): put it into `versions.json` →
   `npm.gadsPlugin`.

Never change or remove a folder that is on `dist`: installed kits pin the
checksum of its files and the commit they are fetched from.

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

On `main` and on every branch of the kit: no binary, no `.ipa`, no
certificate or key, nothing copied from a real farm:
no real host name, tunnel id, UDID, password, secret, pairing code or farm
token, and no address of a real Blossom deployment. Examples use
`yourdomain.com` and zero UUIDs; the tests make their certificate at run
time instead of carrying one. `.gitignore` blocks the usual file types;
it does not replace looking at the diff. The branch `dist` is the one
place for binaries, and it holds nothing but what `tools/publish-dist.sh`
puts there.

## Licence duties when publishing the `GADS-drag` programs

Read `NOTICE`, section 2. In short: the programs are AGPL-3.0, so every
release that carries them carries the licence text, their source archive
(with the module sources, the build instructions and the statement of
modifications) and the licence notices of the libraries compiled into them
(the union over the three programs); `tools/build-provider.sh` makes all of
them and `tools/publish-dist.sh` refuses to publish without them. The
programs must stay free of `hub-ui` (the build script
builds without the `ui` tag and checks that the submodule folder is empty).
The patch marks the files it changes as modified and makes the provider
announce where its source is (`X-Source-Code`, the address of the branch
`dist`); keep both when the patch changes. The question of the files
embedded from upstream's `resources/` directory is yours to decide, and
`tools/publish-dist.sh` waits for that decision ("Before the first provider
publication" above).
