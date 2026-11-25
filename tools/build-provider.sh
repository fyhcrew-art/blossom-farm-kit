#!/usr/bin/env bash
# Builds the patched provider exactly as it is published: upstream GADS at the
# commit pinned in versions.json + patch/provider-drag.patch, WITHOUT the hub
# web interface (hub-ui is proprietary and is not part of this build; the kit
# uses this program as the provider only). Three programs from the same
# patched source, all cross-built on Linux with CGO_ENABLED=0:
#
#   GADS-drag.exe            Windows x64
#   GADS-drag-darwin-arm64   macOS, Apple Silicon
#   GADS-drag-darwin-amd64   macOS, Intel
#
# and what is published next to them: SHA256SUMS, the source archive,
# THIRD-PARTY-NOTICES.txt, LICENSE-AGPL-3.0.txt, BUILD.md, MODIFICATIONS.md.
#
#   tools/build-provider.sh --out <folder> [--work <folder>] [--upstream <address or folder>]
#                           [--no-pin-check]
#
#   --out        where the nine files are written (created; must be empty)
#   --work       where upstream is checked out and built (default: a new
#                temporary folder, removed at the end; a folder you name is kept)
#   --upstream   the git address of GADS (default https://github.com/shamanec/GADS.git);
#                a local clone works too. The commit is checked either way.
#   --no-pin-check   do not fail when a program's SHA-256 differs from
#                versions.json. For the first build after the patch, the
#                upstream commit or the Go version changed: it prints the
#                three values to put into versions.json.
#
# The build is reproducible: the same inputs give the same three files, bit
# for bit, in any folder. Without --no-pin-check the script fails unless each
# program has the SHA-256 pinned for it in versions.json. Anyone can run it
# and compare (docs/RELEASING.md, patch/README.md).
#
# Needs Linux x64 with git, Go (any recent version: the pinned Go toolchain is
# downloaded by Go itself and its version is checked), GNU tar, gzip.
# Publishes nothing: tools/publish-dist.sh does that.
set -euo pipefail
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=''; WORK=''; UPSTREAM='https://github.com/shamanec/GADS.git'; PIN_CHECK=1
while [ $# -gt 0 ]; do
    case $1 in
        --out) OUT=$2; shift ;;
        --work) WORK=$2; shift ;;
        --upstream) UPSTREAM=$2; shift ;;
        --no-pin-check) PIN_CHECK=0 ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$OUT" ] || { echo 'usage: tools/build-provider.sh --out <folder> [--work <folder>] [--upstream <address or folder>] [--no-pin-check]' >&2; exit 2; }
for tool in git go tar gzip sha256sum; do
    command -v "$tool" > /dev/null 2>&1 || { echo "The program $tool was not found." >&2; exit 1; }
done

pin() {
    # pin <path in versions.json>: prints the value, fails when it is missing
    local value
    value=$(LC_ALL=C awk -f "$KIT/lib/json.awk" < "$KIT/versions.json" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }')
    [ -n "$value" ] || { echo "versions.json has no value for $1." >&2; exit 1; }
    printf '%s' "$value"
}
UPSTREAM_COMMIT=$(pin gads.commit)
UPSTREAM_TAG=$(pin gads.version)
RELEASE_TAG=$(pin gadsDrag.releaseTag)
VERSION=$(pin gadsDrag.version)
GO_VERSION=$(pin gadsDrag.goVersion)
SWAG_VERSION=$(pin gadsDrag.swagVersion)
PINNED_WINDOWS=$(pin gadsDrag.sha256)
PINNED_DARWIN_ARM64=$(pin macos.arm64.provider.sha256)
PINNED_DARWIN_AMD64=$(pin macos.x86_64.provider.sha256)
export UPSTREAM_COMMIT UPSTREAM_TAG VERSION GO_VERSION SWAG_VERSION

mkdir -p "$OUT"
if [ -n "$(find "$OUT" -mindepth 1 -maxdepth 1 -print | head -n 1)" ]; then echo "$OUT is not empty." >&2; exit 1; fi
OUT=$(cd "$OUT" && pwd)
KEEP_WORK=1
if [ -z "$WORK" ]; then WORK=$(mktemp -d); KEEP_WORK=0; fi
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
if [ -e "$WORK/gads" ]; then echo "$WORK/gads exists already; name an empty --work folder." >&2; exit 1; fi
cleanup() { if [ "$KEEP_WORK" = 0 ]; then chmod -R u+w "$WORK" 2> /dev/null || true; rm -rf "$WORK"; fi; }
trap cleanup EXIT

# The pinned Go, whatever Go is installed; nothing of the caller's Go settings
# that could change the result.
export GOTOOLCHAIN="go$GO_VERSION" GOFLAGS='' CGO_ENABLED=0 GOWORK=off
unset GOOS GOARCH GOEXPERIMENT GOAMD64 GOARM64 || true
if [ "$(go env GOVERSION)" != "go$GO_VERSION" ]; then
    echo "Go $GO_VERSION is pinned in versions.json, but 'go' runs $(go env GOVERSION). Install Go $GO_VERSION or let Go download it (GOTOOLCHAIN)." >&2
    exit 1
fi
echo "== $RELEASE_TAG: GADS $UPSTREAM_TAG ($UPSTREAM_COMMIT) + patch/provider-drag.patch, Go $GO_VERSION, swag $SWAG_VERSION"

echo '== Upstream GADS at the pinned commit'
SRC=$WORK/gads
git init -q "$SRC"
git -C "$SRC" -c protocol.version=2 fetch -q --depth 1 --no-tags "$UPSTREAM" "$UPSTREAM_COMMIT"
git -C "$SRC" -c advice.detachedHead=false checkout -q FETCH_HEAD
test "$(git -C "$SRC" rev-parse HEAD)" = "$UPSTREAM_COMMIT"
# hub-ui is a private, proprietary submodule: it is not fetched and not built.
test -z "$(ls -A "$SRC/hub-ui" 2> /dev/null)"

echo '== The patch'
git -C "$SRC" apply --check "$KIT/patch/provider-drag.patch"
git -C "$SRC" apply "$KIT/patch/provider-drag.patch"
git -C "$SRC" status --short

echo '== The API docs package (needed to compile, as upstream does)'
(cd "$SRC" && GOBIN="$WORK/bin" go install "github.com/swaggo/swag/cmd/swag@$SWAG_VERSION" && "$WORK/bin/swag" init -g hub/hub.go -o docs > "$WORK/swag.log" 2>&1) || { cat "$WORK/swag.log" >&2; exit 1; }

echo '== Build for Windows x64, macOS arm64 and macOS x64'
# No "-tags ui": the proprietary web interface is not embedded.
build() { (cd "$SRC" && GOOS="$1" GOARCH="$2" go build -trimpath -buildvcs=false -ldflags="-X main.AppVersion=${VERSION}" -o "$OUT/$3" .); }
build windows amd64 GADS-drag.exe
build darwin arm64 GADS-drag-darwin-arm64
build darwin amd64 GADS-drag-darwin-amd64

echo '== Vet and test the provider packages (the patch only touches provider/router)'
(
    cd "$SRC"
    go vet ./provider/router/
    GOOS=windows GOARCH=amd64 go vet ./provider/router/
    GOOS=darwin GOARCH=arm64 go vet ./provider/router/
    go test ./provider/...
)

# After the build and its tests on purpose: the script adds vendor/ to the
# tree, and the published programs are built in module mode, without it.
echo '== Source archive, licence texts of the linked modules, the AGPL text'
DIST=$OUT
export KIT SRC DIST
bash "$KIT/tools/make-source-archive.sh" > "$WORK/source-archive.log" 2>&1 || { cat "$WORK/source-archive.log" >&2; exit 1; }
grep -E '^(Third-party notices|WARNING)' "$WORK/source-archive.log" || true

echo '== Checksums'
(
    cd "$OUT"
    # GitHub refuses a file of 100 MB or more in a git push; the dist branch never uses Git LFS.
    for f in *; do
        size=$(wc -c < "$f" | tr -d ' ')
        if [ "$size" -ge 100000000 ]; then echo "$f is $size bytes: too large for a git branch on GitHub (limit 100 MB per file)." >&2; exit 1; fi
    done
    sha256sum GADS-drag.exe GADS-drag-darwin-arm64 GADS-drag-darwin-amd64 "GADS-drag-${VERSION}-source.tar.gz" THIRD-PARTY-NOTICES.txt LICENSE-AGPL-3.0.txt BUILD.md MODIFICATIONS.md | tee SHA256SUMS
)

FAILED=0
check() {
    local built
    built=$(sha256sum "$OUT/$1" | cut -d' ' -f1)
    if [ "$built" = "$2" ]; then return 0; fi
    FAILED=1
    echo "DIFFERENT: $1 has SHA-256 $built but versions.json pins $2 ($3)." >&2
}
check GADS-drag.exe "$PINNED_WINDOWS" gadsDrag.sha256
check GADS-drag-darwin-arm64 "$PINNED_DARWIN_ARM64" macos.arm64.provider.sha256
check GADS-drag-darwin-amd64 "$PINNED_DARWIN_AMD64" macos.x86_64.provider.sha256
if [ "$FAILED" -ne 0 ]; then
    if [ "$PIN_CHECK" = 1 ]; then
        echo 'If the patch, the upstream commit, the Go version or the swag version changed, build once with --no-pin-check, put the three values into versions.json and build again. If nothing changed, do not publish: find out why the build differs.' >&2
        exit 1
    fi
    echo 'The pins of versions.json were not compared (--no-pin-check). Put the three values above into versions.json, then build again without the option, in another folder: the second build must reproduce them.'
else
    echo 'Reproduced the three pinned SHA-256 values.'
fi
echo "The files of $RELEASE_TAG are in $OUT"
