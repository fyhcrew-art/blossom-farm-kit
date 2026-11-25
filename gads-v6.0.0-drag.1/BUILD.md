# How the GADS-drag programs v6.0.0-drag.1 were built

On Linux x64, with Go 1.26.0, on a maintainer's computer, with the kit's
`tools/build-provider.sh` (the commands below are what it runs). From this
tree:

1. Put Apple's developer disk image back (`resources/ios-ddi/NOT-INCLUDED.txt`
   says where to get the files and gives their checksums). The program embeds
   that folder and does not compile without it.
2. Build (the same command three times; only the target system differs):

```sh
build() { CGO_ENABLED=0 GOOS=$1 GOARCH=$2 GOFLAGS= \
  go build -mod=mod -trimpath -buildvcs=false -ldflags="-X main.AppVersion=v6.0.0-drag.1" -o $3 .; }
build windows amd64 GADS-drag.exe            # Windows x64
build darwin  arm64 GADS-drag-darwin-arm64   # macOS, Apple Silicon
build darwin  amd64 GADS-drag-darwin-amd64   # macOS, Intel
```

No C compiler is involved (`CGO_ENABLED=0`), so the macOS programs are built
on Linux as well. `-mod=mod` makes Go take the modules from the module cache
(downloading them, checked against `go.sum`), which is how the published
files were built; their SHA-256 values are in `SHA256SUMS` next to them
(branch `dist` of the kit repository) and in the kit's `versions.json`. Without `-mod=mod` Go uses `vendor/` (no
download needed); the programs are the same, but the files are not identical
byte for byte, because source paths are recorded differently.

No `-tags ui`: the hub's web interface (`hub-ui`, proprietary) is not part
of this build.

To start from upstream instead of this archive:

```sh
git clone https://github.com/shamanec/GADS.git && cd GADS
git checkout 2cf741ce93173a38c3e8ef4a57f8ecbdd03b13ca            # v6.0.0; do not fetch the hub-ui submodule
git apply provider-drag.patch            # from this archive or from the kit repository
go install github.com/swaggo/swag/cmd/swag@v1.16.4
swag init -g hub/hub.go -o docs          # generates the docs package the program imports
```

then the build command above.
