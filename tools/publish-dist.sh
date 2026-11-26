#!/usr/bin/env bash
# Puts the files tools/build-provider.sh made onto the branch "dist" of this
# repository: an orphan branch (no history in common with the kit) that holds
# nothing but the published programs, one folder per provider version:
#
#   gads-v6.0.0-drag.1/GADS-drag.exe
#   gads-v6.0.0-drag.1/GADS-drag-darwin-arm64
#   gads-v6.0.0-drag.1/GADS-drag-darwin-amd64
#   gads-v6.0.0-drag.1/SHA256SUMS, the source archive, the notices, ...
#   README.md
#
# The kit downloads the programs from that branch by COMMIT, never by the
# branch name: versions.json names
#   https://raw.githubusercontent.com/<owner>/<repository>/<commit of dist>/<folder>/<file>
# and pins the SHA-256 of each file. A commit cannot change, so the address
# keeps giving the same bytes; the SHA-256 proves it on every download.
#
#   tools/publish-dist.sh --from <folder made by build-provider.sh> [--one-file-per-commit]
#                         [--correct-papers] [--push]
#
#   --from                 the build output; it must match versions.json
#   --one-file-per-commit  commit each large program by itself (smaller pushes;
#                          for a connection or proxy that refuses one big push)
#   --correct-papers       the folder is published already and the three
#                          programs in --from are the published ones, byte for
#                          byte: replace what lies next to them (BUILD.md,
#                          MODIFICATIONS.md, the source archive, the notices,
#                          SHA256SUMS) in a new commit. For a mistake in the
#                          build instructions or the source archive.
#   --push                 also run "git push origin dist"
#
# It only creates commits on the local branch "dist" (made when missing, from
# origin/dist when that exists). It never rewrites the branch and never
# touches the working tree. A published PROGRAM is never replaced: a changed
# program needs a new provider version and gets a new folder. The papers next
# to a program can be corrected with --correct-papers; the commit before the
# correction stays in the branch and its addresses keep working.
# At the end it prints the commit and the three addresses for versions.json.
set -euo pipefail
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FROM=''; SPLIT=0; PUSH=0; CORRECT=0
while [ $# -gt 0 ]; do
    case $1 in
        --from) FROM=$2; shift ;;
        --one-file-per-commit) SPLIT=1 ;;
        --correct-papers) CORRECT=1 ;;
        --push) PUSH=1 ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$FROM" ] && [ -d "$FROM" ] || { echo 'usage: tools/publish-dist.sh --from <folder made by build-provider.sh> [--one-file-per-commit] [--correct-papers] [--push]' >&2; exit 2; }
FROM=$(cd "$FROM" && pwd)

pin() {
    local value
    value=$(LC_ALL=C awk -f "$KIT/lib/json.awk" < "$KIT/versions.json" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }')
    [ -n "$value" ] || { echo "versions.json has no value for $1." >&2; exit 1; }
    printf '%s' "$value"
}
RELEASE_TAG=$(pin gadsDrag.releaseTag)
VERSION=$(pin gadsDrag.version)
case $RELEASE_TAG in *[!A-Za-z0-9._-]* | .* | '') echo "gadsDrag.releaseTag ($RELEASE_TAG) cannot be a folder name." >&2; exit 1 ;; esac
if [ "$(pin gadsDrag.redistributeEmbeddedResources)" != true ]; then
    echo "Not published. Every GADS-drag program embeds upstream's 'resources' folder, which holds Apple's developer disk image and other pre-built files. Publishing it makes this repository a distributor of them. Read NOTICE, section 2b, and docs/RELEASING.md; if you decide to publish, set gadsDrag.redistributeEmbeddedResources to true in versions.json." >&2
    exit 1
fi

FILES="GADS-drag.exe GADS-drag-darwin-arm64 GADS-drag-darwin-amd64 GADS-drag-${VERSION}-source.tar.gz THIRD-PARTY-NOTICES.txt LICENSE-AGPL-3.0.txt BUILD.md MODIFICATIONS.md SHA256SUMS"
for f in $FILES; do
    [ -f "$FROM/$f" ] || { echo "$FROM lacks $f. Make it with tools/build-provider.sh." >&2; exit 1; }
    size=$(wc -c < "$FROM/$f" | tr -d ' ')
    if [ "$size" -ge 100000000 ]; then echo "$f is $size bytes: GitHub refuses files of 100 MB or more, and this branch never uses Git LFS." >&2; exit 1; fi
done
(cd "$FROM" && sha256sum -c --quiet SHA256SUMS) || { echo "The files in $FROM do not match their SHA256SUMS." >&2; exit 1; }
check() {
    local built
    built=$(sha256sum "$FROM/$1" | cut -d' ' -f1)
    [ "$built" = "$(pin "$2")" ] || { echo "$1 has SHA-256 $built, but versions.json pins $(pin "$2") ($2). Publish only what versions.json pins." >&2; exit 1; }
}
check GADS-drag.exe gadsDrag.sha256
check GADS-drag-darwin-arm64 macos.arm64.provider.sha256
check GADS-drag-darwin-amd64 macos.x86_64.provider.sha256

cd "$KIT"
ORIGIN=$(git remote get-url origin 2> /dev/null || true)
SLUG=$(printf '%s' "$ORIGIN" | sed -E 's|^.*github\.com[:/]||; s|\.git$||; s|/$||')
case $SLUG in */*) ;; *) SLUG='fyhcrew-art/blossom-farm-kit' ;; esac

PARENT=''
if git rev-parse -q --verify refs/heads/dist > /dev/null; then PARENT=$(git rev-parse refs/heads/dist)
elif git rev-parse -q --verify refs/remotes/origin/dist > /dev/null; then PARENT=$(git rev-parse refs/remotes/origin/dist); fi
if [ -n "$PARENT" ] && [ -n "$(git merge-base "$PARENT" HEAD 2> /dev/null || true)" ]; then
    echo 'The branch "dist" shares history with the kit. It must be an orphan branch that holds the published programs only.' >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GIT_INDEX_FILE="$WORK/index"
if [ -n "$PARENT" ]; then git read-tree "$PARENT"; else git read-tree --empty; fi

commit() {
    # commit <message>: one commit from the temporary index
    local tree new
    tree=$(git write-tree)
    if [ -n "$PARENT" ]; then new=$(git commit-tree "$tree" -p "$PARENT" -m "$1"); else new=$(git commit-tree "$tree" -m "$1"); fi
    PARENT=$new
}
add() { git update-index --add --cacheinfo "$3,$(git hash-object -w "$1"),$2"; }
add_all() {
    local f mode
    for f in $FILES; do
        mode=100644
        case $f in GADS-drag.exe | GADS-drag-darwin-*) mode=100755 ;; esac
        add "$FROM/$f" "$RELEASE_TAG/$f" "$mode"
    done
}
# shellcheck disable=SC2016  # the backticks are Markdown
{
    echo '# Published programs of the Blossom farm kit'
    echo
    echo 'This branch holds no source code of the kit. It holds the programs the'
    echo "kit's installers download, one folder per version of the patched GADS"
    echo 'provider (`GADS-drag`), each with its checksums, its complete source'
    echo 'archive, its build instructions and the licence texts. The kit itself is'
    echo "on the branch \`main\`: <https://github.com/$SLUG>."
    echo
    echo 'Nothing here is meant to be downloaded by hand. The installers fetch a'
    echo 'program by the address of one exact commit of this branch and compare'
    echo "its SHA-256 with the value pinned in the kit's \`versions.json\`."
    echo
    echo 'The programs are a modified version of [GADS](https://github.com/shamanec/GADS),'
    echo 'licensed under the GNU AGPL v3.0. They were built on a maintainer'"'"'s'
    echo 'computer with `tools/build-provider.sh` of the kit. The build is'
    echo 'reproducible: `BUILD.md` in each folder gives the commands, and anyone'
    echo 'who runs them gets files with the SHA-256 values of `SHA256SUMS`.'
    echo
    echo 'A program, once published, is never changed: a changed program gets a'
    echo 'new version and a new folder. What lies next to a program (the build'
    echo 'instructions, the source archive, the notices) can be corrected by a'
    echo 'later commit, which says so in its message; the programs and their'
    echo 'SHA-256 values stay as they are, and every earlier commit of this'
    echo 'branch keeps serving what it held.'
} > "$WORK/README.md"

if [ -n "$(git ls-files -- "$RELEASE_TAG/")" ]; then
    SAME=1; SAME_PROGRAMS=1
    for f in $FILES; do
        have=$(git ls-files -s -- "$RELEASE_TAG/$f" | awk '{ print $2 }')
        if [ -z "$have" ] || [ "$have" != "$(git hash-object "$FROM/$f")" ]; then
            SAME=0
            case $f in GADS-drag.exe | GADS-drag-darwin-*) SAME_PROGRAMS=0 ;; esac
        fi
    done
    if [ "$SAME" = 1 ]; then
        echo "The branch dist already holds exactly these files in $RELEASE_TAG/ (commit $PARENT). Nothing to do."
    elif [ "$SAME_PROGRAMS" = 1 ] && [ "$CORRECT" = 1 ]; then
        add "$WORK/README.md" README.md 100644
        add_all
        commit "GADS-drag $VERSION: corrected papers (build instructions, source archive, checksums of both); the three programs are unchanged"
        git update-ref refs/heads/dist "$PARENT"
        echo "Committed the corrected papers of $RELEASE_TAG/ to the local branch dist. The three programs are the published ones."
    elif [ "$SAME_PROGRAMS" = 1 ]; then
        echo "The branch dist already holds $RELEASE_TAG/ with these three programs; what lies next to them differs (BUILD.md, the source archive, ...). To publish that as a correction, run again with --correct-papers." >&2
        exit 1
    else
        echo "The branch dist already holds a folder $RELEASE_TAG/ with other programs. A published program is never replaced: installed kits pin its checksum, and the address by commit keeps serving the old one. Give the provider a new version (gadsDrag.releaseTag and gadsDrag.version in versions.json), build again and publish that." >&2
        exit 1
    fi
else
    add "$WORK/README.md" README.md 100644
    if [ "$SPLIT" = 1 ]; then
        for f in GADS-drag.exe GADS-drag-darwin-arm64 GADS-drag-darwin-amd64; do
            add "$FROM/$f" "$RELEASE_TAG/$f" 100755
            commit "GADS-drag $VERSION: $f"
        done
    fi
    add_all
    commit "GADS-drag $VERSION: the three programs, their checksums, source archive and notices"
    git update-ref refs/heads/dist "$PARENT"
    echo "Committed $RELEASE_TAG/ to the local branch dist."
fi
unset GIT_INDEX_FILE

if [ "$PUSH" = 1 ]; then git push origin dist; fi
echo
echo "dist is at commit $PARENT"
[ "$PUSH" = 1 ] || echo 'Push it with:   git push origin dist'
echo 'Then put these three addresses into versions.json (gadsDrag.url, macos.arm64.provider.url, macos.x86_64.provider.url):'
for f in GADS-drag.exe GADS-drag-darwin-arm64 GADS-drag-darwin-amd64; do
    echo "  https://raw.githubusercontent.com/$SLUG/$PARENT/$RELEASE_TAG/$f"
done
