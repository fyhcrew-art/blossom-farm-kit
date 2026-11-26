# This is a MODIFIED copy of GADS

* Original work: GADS, https://github.com/shamanec/GADS, tag `v6.0.0`,
  commit `2cf741ce93173a38c3e8ef4a57f8ecbdd03b13ca`. Licence: GNU AGPL v3.0 (file `LICENSE`);
  `hub-ui` is proprietary, is not part of this archive and is not built.
* Modified by: Blossom CRM, https://github.com/fyhcrew-art/blossom-farm-kit
* Date of this build: 2026-11-25. Version string of the program: `v6.0.0-drag.1`.

What differs from the upstream tree at that commit:

| Path | Change |
|---|---|
| `provider/router/control.go` | modified: custom actions `drag`, `source`, `open_url` added |
| `provider/router/handler.go` | modified: every answer of the provider carries the header `X-Source-Code` |
| `provider-drag.patch` | added: the two modifications above as a patch against upstream |
| `docs/docs.go`, `docs/swagger.json`, `docs/swagger.yaml` | added: generated with `swag init` (the program imports this package) |
| `vendor/` | added: the sources of the Go modules the program is built from (`go mod vendor`) |
| `THIRD-PARTY-NOTICES.txt` | added: licence texts of the modules linked into the programs |
| `BUILD.md`, `MODIFICATIONS.md`, `IOS-DDI-NOT-INCLUDED.txt` | added |
| `resources/ios-ddi/*` | removed: Apple's developer disk image; see `IOS-DDI-NOT-INCLUDED.txt` |

Everything else is upstream's, unchanged. That includes the pre-built files
upstream keeps in `resources/` (`gads-broadcast.ipa`, `gads-settings.apk`,
`zsign-linux`, `zsign-mac`, `zsign-win.exe`): they are in this archive as
upstream ships them, without their source. zsign: https://github.com/zhlynn/zsign.

The modified files are licensed under the GNU AGPL v3.0, like the originals.
