#!/usr/bin/env bash
# Builds what is published next to the GADS-drag programs (GADS-drag.exe,
# GADS-drag-darwin-arm64, GADS-drag-darwin-amd64):
#   dist/THIRD-PARTY-NOTICES.txt       licence texts of the Go modules compiled into them
#   dist/LICENSE-AGPL-3.0.txt          their licence (upstream's LICENSE file)
#   dist/GADS-drag-<version>-source.tar.gz
#       the patched GADS tree + the generated docs package + the module sources
#       (vendor/) + the patch + BUILD.md + MODIFICATIONS.md, WITHOUT Apple's
#       developer disk image (resources/ios-ddi), which is listed with
#       checksums and fetched from upstream by whoever rebuilds.
#
# Run from the folder that holds  kit/  gads/  dist/  after the build and its
# tests (vendor/ must not exist while the programs are built: the published
# ones are built in module mode). Used by .github/workflows/build-gads.yml.
set -euo pipefail

: "${VERSION:?}" "${UPSTREAM_COMMIT:?}" "${UPSTREAM_TAG:?}" "${GO_VERSION:?}" "${SWAG_VERSION:?}"
KIT=kit
SRC=gads
DIST=dist
PROGRAMS="GADS-drag.exe GADS-drag-darwin-arm64 GADS-drag-darwin-amd64"
for PROGRAM in $PROGRAMS; do test -f "$DIST/$PROGRAM"; done
test -f "$SRC/LICENSE"
BUILD_DATE="$(date -u +%Y-%m-%d)"

# 1. The sources of every module the program is built from.
(cd "$SRC" && go mod vendor)

# 2. Licence texts of the modules that are actually linked into the programs.
#    The three do not link exactly the same set (some modules are for one
#    system only), so the list is the union.
NOTICES="$DIST/THIRD-PARTY-NOTICES.txt"
MODULES="$(for PROGRAM in $PROGRAMS; do go version -m "$DIST/$PROGRAM" | awk '$1 == "dep" { print $2 " " $3 }'; done | LC_ALL=C sort -u)"
test -n "$MODULES"
MISSING=0
{
  echo "GADS-drag $VERSION - third-party software compiled into these programs"
  echo "======================================================================"
  echo
  echo "GADS-drag is GADS (https://github.com/shamanec/GADS, GNU AGPL v3.0) with"
  echo "the Blossom patch, published as GADS-drag.exe (Windows x64),"
  echo "GADS-drag-darwin-arm64 and GADS-drag-darwin-amd64 (macOS). Each is"
  echo "statically linked with Go modules from the list below (the union of what"
  echo "'go version -m' reports for the three; a few modules are linked on one"
  echo "system only) and with the Go standard library and runtime"
  echo "(https://go.dev/LICENSE, BSD 3-Clause). The licence, notice and"
  echo "copyright files of each module follow, copied from the module's own"
  echo "source at the version named."
  echo
  while read -r LINE; do echo "  $LINE"; done <<< "$MODULES"
  echo
  while read -r MOD VER; do
    echo "----------------------------------------------------------------------"
    echo "$MOD $VER"
    echo "----------------------------------------------------------------------"
    DIR="$SRC/vendor/$MOD"
    FILES=""
    if [ -d "$DIR" ]; then
      FILES="$(find "$DIR" -maxdepth 1 -type f \( -iname 'LICEN[SC]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'COPYRIGHT*' -o -iname 'PATENTS*' -o -iname 'UNLICEN[SC]E*' \) | LC_ALL=C sort)"
      if [ -z "$FILES" ]; then
        FILES="$(find "$DIR" -type f \( -iname 'LICEN[SC]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'COPYRIGHT*' -o -iname 'UNLICEN[SC]E*' \) | LC_ALL=C sort)"
      fi
    fi
    if [ -z "$FILES" ]; then
      echo "(no licence file found in this module's source; see https://pkg.go.dev/$MOD?tab=licenses)"
      echo
      MISSING=$((MISSING + 1))
      continue
    fi
    while read -r F; do
      echo "[${F#"$SRC"/vendor/}]"
      echo
      cat "$F"
      echo
    done <<< "$FILES"
  done <<< "$MODULES"
} > "$NOTICES"
echo "Third-party notices: $(echo "$MODULES" | wc -l) modules, $MISSING without a licence file."
if [ "$MISSING" -gt 0 ]; then
  echo "::warning::$MISSING module(s) have no licence file in their source; they are named in THIRD-PARTY-NOTICES.txt. Look at them before publishing."
fi

cp "$SRC/LICENSE" "$DIST/LICENSE-AGPL-3.0.txt"

# 3. What makes the tree a complete, honest source of the exe.
cp "$KIT/patch/provider-drag.patch" "$SRC/provider-drag.patch"
cp "$NOTICES" "$SRC/THIRD-PARTY-NOTICES.txt"

DDI_FILES="$(cd "$SRC" && find resources/ios-ddi -type f | LC_ALL=C sort)"
test -n "$DDI_FILES"
{
  echo "The files of this folder are NOT in this archive."
  echo
  echo "They are Apple's developer disk image for iOS 17 and later, with its"
  echo "manifest and trust cache, exactly as the GADS repository carries them."
  echo "GADS embeds them into the program (main.go: go:embed resources), so they"
  echo "are needed to build it. Fetch them, unchanged, from upstream GADS at the"
  echo "commit this archive was made from, and check them against the SHA-256"
  echo "values below:"
  echo
  echo "  git clone https://github.com/shamanec/GADS.git && cd GADS"
  echo "  git checkout $UPSTREAM_COMMIT"
  echo "  (then copy resources/ios-ddi/ over this folder)"
  echo
  echo "or file by file:"
  echo "  https://github.com/shamanec/GADS/raw/$UPSTREAM_COMMIT/<path below>"
  echo
  (cd "$SRC" && echo "$DDI_FILES" | xargs -d '\n' sha256sum)
} > "$DIST/.ddi-not-included.txt"

cat > "$SRC/MODIFICATIONS.md" <<TEXT
# This is a MODIFIED copy of GADS

* Original work: GADS, https://github.com/shamanec/GADS, tag \`$UPSTREAM_TAG\`,
  commit \`$UPSTREAM_COMMIT\`. Licence: GNU AGPL v3.0 (file \`LICENSE\`);
  \`hub-ui\` is proprietary, is not part of this archive and is not built.
* Modified by: Blossom CRM, https://github.com/fyhcrew-art/blossom-farm-kit
* Date of this build: $BUILD_DATE. Version string of the program: \`$VERSION\`.

What differs from the upstream tree at that commit:

| Path | Change |
|---|---|
| \`provider/router/control.go\` | modified: custom actions \`drag\`, \`source\`, \`open_url\` added |
| \`provider/router/handler.go\` | modified: every answer of the provider carries the header \`X-Source-Code\` |
| \`provider-drag.patch\` | added: the two modifications above as a patch against upstream |
| \`docs/docs.go\`, \`docs/swagger.json\`, \`docs/swagger.yaml\` | added: generated with \`swag init\` (the program imports this package) |
| \`vendor/\` | added: the sources of the Go modules the program is built from (\`go mod vendor\`) |
| \`THIRD-PARTY-NOTICES.txt\` | added: licence texts of the modules linked into the programs |
| \`BUILD.md\`, \`MODIFICATIONS.md\` | added |
| \`resources/ios-ddi/*\` | removed: Apple's developer disk image; see \`resources/ios-ddi/NOT-INCLUDED.txt\` |

Everything else is upstream's, unchanged. That includes the pre-built files
upstream keeps in \`resources/\` (\`gads-broadcast.ipa\`, \`gads-settings.apk\`,
\`zsign-linux\`, \`zsign-mac\`, \`zsign-win.exe\`): they are in this archive as
upstream ships them, without their source. zsign: https://github.com/zhlynn/zsign.

The modified files are licensed under the GNU AGPL v3.0, like the originals.
TEXT

cat > "$SRC/BUILD.md" <<TEXT
# How the GADS-drag programs $VERSION were built

On Linux x64, with Go $GO_VERSION, from this tree:

1. Put Apple's developer disk image back (\`resources/ios-ddi/NOT-INCLUDED.txt\`
   says where to get the files and gives their checksums). The program embeds
   that folder and does not compile without it.
2. Build (the same command three times; only the target system differs):

\`\`\`sh
build() { CGO_ENABLED=0 GOOS=\$1 GOARCH=\$2 GOFLAGS= \\
  go build -mod=mod -trimpath -buildvcs=false -ldflags="-X main.AppVersion=$VERSION" -o \$3 .; }
build windows amd64 GADS-drag.exe            # Windows x64
build darwin  arm64 GADS-drag-darwin-arm64   # macOS, Apple Silicon
build darwin  amd64 GADS-drag-darwin-amd64   # macOS, Intel
\`\`\`

No C compiler is involved (\`CGO_ENABLED=0\`), so the macOS programs are built
on Linux as well. \`-mod=mod\` makes Go take the modules from the module cache
(downloading them, checked against \`go.sum\`), which is how the published
files were built; their SHA-256 values are in \`SHA256SUMS\` on the release and
in the kit's \`versions.json\`. Without \`-mod=mod\` Go uses \`vendor/\` (no
download needed); the programs are the same, but the files are not identical
byte for byte, because source paths are recorded differently.

No \`-tags ui\`: the hub's web interface (\`hub-ui\`, proprietary) is not part
of this build.

To start from upstream instead of this archive:

\`\`\`sh
git clone https://github.com/shamanec/GADS.git && cd GADS
git checkout $UPSTREAM_COMMIT            # $UPSTREAM_TAG; do not fetch the hub-ui submodule
git apply provider-drag.patch            # from this archive or from the kit repository
go install github.com/swaggo/swag/cmd/swag@$SWAG_VERSION
swag init -g hub/hub.go -o docs          # generates the docs package the program imports
\`\`\`

then the build command above.
TEXT

# 4. The archive. Apple's files are left out; a note takes their place.
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/gads/resources/ios-ddi"
cp "$DIST/.ddi-not-included.txt" "$STAGE/gads/resources/ios-ddi/NOT-INCLUDED.txt"
rm -f "$DIST/.ddi-not-included.txt"
TAR_OPTS=(--sort=name --owner=0 --group=0 --numeric-owner --mtime='2020-01-01 00:00:00Z')
tar "${TAR_OPTS[@]}" --exclude=.git --exclude='gads/resources/ios-ddi/*' -cf "$DIST/source.tar" gads
tar "${TAR_OPTS[@]}" -C "$STAGE" -rf "$DIST/source.tar" gads/resources/ios-ddi/NOT-INCLUDED.txt
gzip -n -9 "$DIST/source.tar"
mv "$DIST/source.tar.gz" "$DIST/GADS-drag-${VERSION}-source.tar.gz"
rm -rf "$STAGE"

# The archive must not carry Apple's image, and must carry what it promises.
LIST="$(tar -tzf "$DIST/GADS-drag-${VERSION}-source.tar.gz")"
LEFT="$(grep -E '^gads/resources/ios-ddi/.*[^/]$' <<< "$LIST" | grep -v 'NOT-INCLUDED.txt$' || true)"
if [ -n "$LEFT" ]; then
  echo "::error::The source archive still contains files of resources/ios-ddi."; exit 1
fi
for NEEDED in gads/LICENSE gads/MODIFICATIONS.md gads/BUILD.md gads/provider-drag.patch gads/THIRD-PARTY-NOTICES.txt gads/vendor/modules.txt gads/docs/docs.go gads/resources/ios-ddi/NOT-INCLUDED.txt gads/go.sum; do
  grep -qx "$NEEDED" <<< "$LIST" || { echo "::error::The source archive lacks $NEEDED."; exit 1; }
done
ls -l "$DIST"
