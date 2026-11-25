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
  header `X-Source-Code: https://github.com/fyhcrew-art/blossom-farm-kit/releases`.
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
  passes on `v6.0.0` and on `v6.1.0` without offsets or fuzz; CI repeats the
  check on every change (`.github/workflows/ci.yml`).
* It needs the GADS author's WebDriverAgent fork on the phones, as GADS itself
  does.

## How the published binary is built

`.github/workflows/build-gads.yml` does this, and nothing else:

```sh
git fetch --depth 1 https://github.com/shamanec/GADS.git 2cf741ce93173a38c3e8ef4a57f8ecbdd03b13ca
git checkout FETCH_HEAD                      # v6.0.0; the hub-ui submodule is NOT fetched
git apply patch/provider-drag.patch
go install github.com/swaggo/swag/cmd/swag@v1.16.4
swag init -g hub/hub.go -o docs              # generates the docs package the code imports
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
  go build -trimpath -buildvcs=false -ldflags="-X main.AppVersion=v6.0.0-drag.1" -o GADS-drag.exe .
```

Differences from upstream's own release build
(`.github/workflows/main.yml` in GADS), all on purpose:

* **No `-tags ui`.** Upstream's releases embed the hub's web interface, built
  from the `hub-ui` submodule. That submodule is a private repository under a
  proprietary licence that forbids redistribution. This build does not contain
  it and could not: the source is not available to us. `GADS-drag.exe` is
  therefore used **as the provider only**; the hub on a farm is the
  publisher's own `GADS.exe`.
* **`swag init` is needed**, exactly as in upstream's workflow: the hub
  package imports `GADS/docs`, which is generated and not committed. Upstream
  installs `swag@latest`; this build pins `v1.16.4`.
* `-trimpath -buildvcs=false` and a fixed Go version make the build
  **reproducible**: the same inputs give the same file, bit for bit. The
  SHA-256 is pinned in `versions.json`, and the workflow fails if what it
  built differs.

To check the published file yourself, run the commands above with Go 1.26.0
on Linux and compare `sha256sum GADS-drag.exe` with `versions.json`.

After the build and its tests the workflow runs
`.github/scripts/make-source-archive.sh`, which makes the files published
next to the binary: the source archive (with `vendor/`, `BUILD.md` and
`MODIFICATIONS.md`), `THIRD-PARTY-NOTICES.txt` and the AGPL text.

## Licence

The patch modifies files of GADS that are licensed under the GNU Affero
General Public License v3.0, and is distributed under the same licence (text:
`../LICENSE-AGPL-3.0`; details: `../NOTICE`). The binary built from it is
published on the same release as `GADS-drag-<version>-source.tar.gz`: the
patched tree, the sources of the Go modules it is built from, the build
instructions and a statement of what was modified. Apple's developer disk
image, which the build embeds, is not in that archive; the archive says where
to fetch it and gives its checksums (`../NOTICE`, section 2b).
