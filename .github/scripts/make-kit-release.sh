#!/bin/bash
# Makes the files of a kit release (docs/RELEASING.md):
#
#   blossom-farm-kit-<version>.zip   the kit, in a folder of the same name
#   SHA256SUMS                       the SHA-256 of that archive
#   bootstrap.sh, bootstrap.ps1      the first file of the one-command setup,
#                                    with the release tag, its download
#                                    address and the SHA-256 of SHA256SUMS
#                                    written into them
#   bootstrap-hashes.json            the SHA-256 of the two bootstrap files:
#                                    what Blossom CRM puts into the command it
#                                    shows (this file is for the people who
#                                    maintain Blossom; nothing downloads it)
#
# The chain a customer's computer follows: the command from Blossom pins a
# bootstrap file; the bootstrap file pins SHA256SUMS; SHA256SUMS pins the
# archive.
#
#   .github/scripts/make-kit-release.sh --out <folder> [--tag kit-v<version>]
#                                       [--base-url <address>] [--source <folder>]
#
#   --out        where the five files are written (created; must be empty)
#   --tag        must be kit-v<the "kit" value of versions.json>; the default
#   --base-url   where the release's files will be downloaded from (default:
#                this repository's GitHub release for the tag)
#   --source     pack this folder instead of the commit that is checked out
#                (used by tests/bootstrap.test.sh)

set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=''; TAG=''; BASE_URL=''; SOURCE=''
while [ $# -gt 0 ]; do
    case $1 in
        --out) OUT=$2; shift ;;
        --tag) TAG=$2; shift ;;
        --base-url) BASE_URL=$2; shift ;;
        --source) SOURCE=$2; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$OUT" ] || { echo 'usage: make-kit-release.sh --out <folder> [--tag kit-v<version>] [--base-url <address>] [--source <folder>]' >&2; exit 2; }

sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
    else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}

VERSIONS=${SOURCE:-$REPO}/versions.json
VERSION=$(LC_ALL=C awk -f "$REPO/lib/json.awk" < "$VERSIONS" | awk -F '\t' '$1 == "kit" { print $2; exit }')
case $VERSION in '' | *[!0-9A-Za-z.+-]*) echo "versions.json has no usable \"kit\" version." >&2; exit 1 ;; esac
[ -n "$TAG" ] || TAG="kit-v$VERSION"
if [ "$TAG" != "kit-v$VERSION" ]; then
    echo "The tag $TAG does not match versions.json, which says kit $VERSION (the tag would be kit-v$VERSION)." >&2
    exit 1
fi
[ -n "$BASE_URL" ] || BASE_URL="https://github.com/fyhcrew-art/blossom-farm-kit/releases/download/$TAG"
case $BASE_URL in https://*) ;; *) echo 'The download address must be https.' >&2; exit 1 ;; esac
case $BASE_URL in *[\'\"\\\&\|[:space:]]*) echo 'The download address contains a character that cannot be written into the bootstrap files.' >&2; exit 1 ;; esac
BASE_URL=${BASE_URL%/}

mkdir -p "$OUT"
if [ -n "$(find "$OUT" -mindepth 1 -maxdepth 1 -print | head -n 1)" ]; then echo "$OUT is not empty." >&2; exit 1; fi
OUT=$(cd "$OUT" && pwd)
NAME="blossom-farm-kit-$VERSION"
ARCHIVE="$NAME.zip"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -n "$SOURCE" ]; then
    mkdir "$WORK/$NAME"
    cp -R "$SOURCE"/. "$WORK/$NAME/"
    (cd "$WORK" && zip -q -r -X "$OUT/$ARCHIVE" "$NAME")
else
    # git archive applies .gitattributes (line ends) and gives the same bytes
    # for the same commit every time.
    if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
        echo 'The working tree has changes that are not committed; a release is made from a commit.' >&2
        exit 1
    fi
    git -C "$REPO" archive --format=zip --prefix="$NAME/" -o "$OUT/$ARCHIVE" HEAD
fi

(cd "$OUT" && printf '%s  %s\n' "$(sha256_of "$ARCHIVE")" "$ARCHIVE" > SHA256SUMS)
SUMS_SHA256=$(sha256_of "$OUT/SHA256SUMS")

# The bootstrap files are taken from the archive itself, so that they are
# exactly what the commit holds, and the four values are written into them.
for f in bootstrap.sh bootstrap.ps1; do
    unzip -p "$OUT/$ARCHIVE" "$NAME/$f" > "$WORK/$f"
    for placeholder in @KIT_TAG@ @KIT_BASE_URL@ @KIT_ARCHIVE@ @KIT_SUMS_SHA256@; do
        if [ "$(grep -c "'$placeholder'" "$WORK/$f" | tr -d '[:space:]')" != 1 ]; then
            echo "$f: expected exactly one line that sets $placeholder." >&2
            exit 1
        fi
    done
    sed -e "s|'@KIT_TAG@'|'$TAG'|" -e "s|'@KIT_BASE_URL@'|'$BASE_URL'|" -e "s|'@KIT_ARCHIVE@'|'$ARCHIVE'|" -e "s|'@KIT_SUMS_SHA256@'|'$SUMS_SHA256'|" "$WORK/$f" > "$OUT/$f"
    if grep -q '@KIT_[A-Z0-9_]*@' "$OUT/$f"; then echo "$f: a value was not filled in." >&2; exit 1; fi
done
bash -n "$OUT/bootstrap.sh"

cat > "$OUT/bootstrap-hashes.json" <<JSON
{
  "release": "$TAG",
  "kit": "$VERSION",
  "baseUrl": "$BASE_URL",
  "bootstrapShSha256": "$(sha256_of "$OUT/bootstrap.sh")",
  "bootstrapPs1Sha256": "$(sha256_of "$OUT/bootstrap.ps1")",
  "sha256sumsSha256": "$SUMS_SHA256"
}
JSON

echo "Kit release $TAG in $OUT:"
(cd "$OUT" && ls -l)
echo
cat "$OUT/bootstrap-hashes.json"
