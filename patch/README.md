# The provider patch

`provider-drag.patch` adds three custom actions to the GADS provider. Blossom
CRM uses them when they are there and works without them when they are not.

| Action | What it does | Without the patch |
|---|---|---|
| `drag` | Press, hold still, then move in small steps and lift, sent to WebDriverAgent as W3C pointer actions. Apps such as Instagram read a plain swipe as a flick; a held, gradual drag moves a story sticker the way a finger does. | Blossom falls back to a swipe. |
| `source` | Returns WebDriverAgent's element tree of the screen as JSON. The AI assistant reads it to know what is on screen. | The assistant works from screenshots. |
| `open_url` | Opens a web address or a deep link on the phone through WebDriverAgent. | The assistant reports it as unavailable. |

All three are reached through the provider's existing
`POST /device/<udid>/custom-action` endpoint; the patch adds no new route.
`drag` and `open_url` open a WebDriverAgent session when none is open (no app
is launched). On Android `drag` falls back to a swipe and `open_url` answers
with an error.

The patch changes two files:

* `provider/router/control.go`: the three actions.
* `provider/router/handler.go`: every answer of the provider carries the
  header `X-Source-Code: https://github.com/fyhcrew-art/blossom-farm-kit/tree/dist`,
  the branch where the programs are published with their source archive.
  This is the offer of source that the AGPL (section 13) asks a modified
  program to make to the people who use it over a network.

Both files carry a notice at the top that they were modified, by whom and
when, as the AGPL (section 5a) asks.

## Upstream base

* The patch was written against GADS `main` at commit
  `d8abfc32e282d872a08484cd6a1e4a535c0cebe9`. That commit **is** the upstream
  tag `v6.1.0`. It is *not* `v6.0.0`.
* The kit builds it on **`v6.0.0`** (commit
  `2cf741ce93173a38c3e8ef4a57f8ecbdd03b13ca`), the version the reference farm
  runs and the version of the hub the installer downloads. `git apply --check`
  passes on `v6.0.0` and on `v6.1.0` without offsets or fuzz;
  `bash tools/check.sh --upstream` repeats the check for the pinned commit.
* It needs the GADS author's WebDriverAgent fork on the phones, as GADS itself
  does.

## How the published binary is built

There is no build service behind this repository. A maintainer runs
`tools/build-provider.sh` on their own computer (Linux x64), and
`tools/publish-dist.sh` puts the result on the branch `dist`
(`docs/RELEASING.md`). The build script does this, and nothing else:

```sh
git fetch --depth 1 https://github.com/shamanec/GADS.git 2cf741ce93173a38c3e8ef4a57f8ecbdd03b13ca
git checkout FETCH_HEAD                      # v6.0.0; the hub-ui submodule is NOT fetched
git apply patch/provider-drag.patch
go install github.com/swaggo/swag/cmd/swag@v1.16.4
swag init -g hub/hub.go -o docs              # generates the docs package the code imports
build() { CGO_ENABLED=0 GOOS=$1 GOARCH=$2 \
  go build -trimpath -buildvcs=false -ldflags="-X main.AppVersion=v6.0.0-drag.1" -o $3 .; }
build windows amd64 GADS-drag.exe             # Windows x64
build darwin  arm64 GADS-drag-darwin-arm64    # macOS, Apple Silicon
build darwin  amd64 GADS-drag-darwin-amd64    # macOS, Intel
```

The three programs come from the same patched tree. GADS and the modules it
uses need no C compiler on any of the three systems (`CGO_ENABLED=0`), so the
macOS programs are built on Linux as well, by the same script, and are
reproducible in the same way.

Differences from upstream's own release build
(`.github/workflows/main.yml` in GADS), all on purpose:

* **No `-tags ui`.** Upstream's releases embed the hub's web interface, built
  from the `hub-ui` submodule. That submodule is a private repository under a
  proprietary licence that forbids redistribution. This build does not contain
  it and could not: the source is not available to us. `GADS-drag.exe` is
  therefore used **as the provider only**; the hub on a farm is the
  publisher's own program (`GADS.exe`, or `GADS` on macOS).
* **The macOS programs are built on Linux, without cgo.** Upstream builds its
  macOS programs on a Mac, where Go links the Apple Silicon one with the
  system's C library through cgo; this build sets `CGO_ENABLED=0` for all
  three targets, which is what lets one Linux computer build and reproduce them.
  `docs/RELEASING.md` lists what is confirmed on a Mac before a kit release.
* **`swag init` is needed**, exactly as in upstream's workflow: the hub
  package imports `GADS/docs`, which is generated and not committed. Upstream
  installs `swag@latest`; this build pins `v1.16.4`.
* `-trimpath -buildvcs=false` and a fixed Go version make the build
  **reproducible**: the same inputs give the same file, bit for bit. The
  three SHA-256 values are pinned in `versions.json` (`gadsDrag.sha256`,
  `macos.arm64.provider.sha256`, `macos.x86_64.provider.sha256`), and the
  script fails if what it built differs.

**To check a published file yourself**, you do not have to trust the
computer it was built on. Either run the commands above with Go 1.26.0 on
Linux, or simply

```sh
bash tools/build-provider.sh --out /tmp/gads-drag
```

in a checkout of this repository (it fetches upstream, lets Go download the
pinned Go version, builds, and ends with "Reproduced the three pinned
SHA-256 values" or names the file that differs). Then compare with what is
published: `SHA256SUMS` in the folder of the version on the branch `dist`,
and the files the addresses in `versions.json` serve.

After the build and its tests the script runs
`tools/make-source-archive.sh`, which makes the files published next to the
binary: the source archive (with `vendor/`, `BUILD.md` and
`MODIFICATIONS.md`), `THIRD-PARTY-NOTICES.txt`, the AGPL text, and
`BUILD.md` and `MODIFICATIONS.md` once more as plain files.

## Licence

The patch modifies files of GADS that are licensed under the GNU Affero
General Public License v3.0, and is distributed under the same licence (text:
`../LICENSE-AGPL-3.0`; details: `../NOTICE`). The binary built from it is
published in the same folder of the branch `dist` as
`GADS-drag-<version>-source.tar.gz`: the
patched tree, the sources of the Go modules it is built from, the build
instructions and a statement of what was modified. Apple's developer disk
image, which the build embeds, is not in that archive; the archive says where
to fetch it and gives its checksums (`../NOTICE`, section 2b).
