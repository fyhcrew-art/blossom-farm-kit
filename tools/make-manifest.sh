#!/bin/bash
# Writes MANIFEST.sha256: the SHA-256 of every file of the kit, and writes the
# SHA-256 of that list into bootstrap.sh and bootstrap.ps1.
#
# Why: the one-command setup downloads the kit as an archive that GitHub makes
# for a commit. GitHub does not promise that such an archive is the same
# bytes every time, so its checksum cannot be pinned. What is pinned instead
# is what is inside it: the bootstrap file carries the SHA-256 of this list,
# and checks every unpacked file against the list (docs/security.md, section 9).
#
#   tools/make-manifest.sh                 regenerate, in the git checkout
#   tools/make-manifest.sh --check         change nothing; status 1 when the
#                                          list or a bootstrap file is stale
#   tools/make-manifest.sh --tree FOLDER [--check]
#                                          the same for a folder that is not a
#                                          git checkout (used by the tests)
#
# In a git checkout the list describes the files as GitHub's archive of the
# commit will hold them: every tracked file, with the line ends that
# .gitattributes gives it. Changes that are not staged yet are taken into
# account; a new file counts once it is added (git add).
#
# Not in the list, because they cannot be: MANIFEST.sha256 itself; the two
# bootstrap files (they carry the list's checksum; Blossom pins each of them
# by its own SHA-256); pairing.json (it names the commit that came before
# it). The bootstrap removes these from the kit it unpacks.
#
# Run it before every commit that changes a file of the kit; tools/check.sh
# and the tests fail when it was forgotten. Written for bash 3.2.
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK=0; TREE=''
while [ $# -gt 0 ]; do
    case $1 in
        --check) CHECK=1 ;;
        --tree) [ $# -ge 2 ] || { echo '--tree needs a folder.' >&2; exit 2; }; TREE=$2; shift ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
    else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/farmkit-manifest.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

if [ -n "$TREE" ]; then
    [ -d "$TREE" ] || { echo "$TREE is not a folder." >&2; exit 1; }
    ROOT=$(cd "$TREE" && pwd)
    CONTENT=$ROOT
else
    ROOT=$KIT
    git -C "$KIT" rev-parse --is-inside-work-tree > /dev/null 2>&1 || { echo "$KIT is not a git checkout; use --tree." >&2; exit 1; }
    # The tracked files as they are now (staged or not), through a copy of
    # the index, as an archive of the resulting tree: the same conversion of
    # line ends that GitHub applies when it makes the archive of a commit.
    INDEX=$(git -C "$KIT" rev-parse --git-path index)
    case $INDEX in /*) ;; *) INDEX=$KIT/$INDEX ;; esac
    cp "$INDEX" "$WORK/index" || exit 1
    tree=$(cd "$KIT" && GIT_INDEX_FILE="$WORK/index" git -c core.safecrlf=false add -u > /dev/null 2>&1 && GIT_INDEX_FILE="$WORK/index" git write-tree) || { echo 'git could not read the working tree.' >&2; exit 1; }
    mkdir "$WORK/content"
    git -C "$KIT" archive --format=tar "$tree" | tar -xf - -C "$WORK/content" || { echo 'git archive failed.' >&2; exit 1; }
    CONTENT=$WORK/content
fi

if [ -n "$(cd "$CONTENT" && find . ! -type f ! -type d -print | LC_ALL=C grep -v -E '^\./(\.[^/]+|node_modules)/' | head -n 1)" ]; then
    echo 'The kit holds something that is neither a file nor a folder (a link?); the list cannot describe it.' >&2
    exit 1
fi
(cd "$CONTENT" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort) > "$WORK/files"
if [ -n "$TREE" ]; then
    # a plain folder: leave out what is not the kit (hidden folders at the
    # top, such as .git; the kit has none of its own)
    LC_ALL=C grep -v -E '^(\.[^/]+|node_modules)/' "$WORK/files" > "$WORK/files.kept"; mv "$WORK/files.kept" "$WORK/files"
fi
if LC_ALL=C grep -q '[^A-Za-z0-9._/-]' "$WORK/files"; then
    echo 'A file name has a character other than letters, digits, dot, underscore and hyphen:' >&2
    LC_ALL=C grep '[^A-Za-z0-9._/-]' "$WORK/files" >&2
    exit 1
fi
: > "$WORK/manifest"
while IFS= read -r f; do
    case $f in MANIFEST.sha256 | bootstrap.sh | bootstrap.ps1 | pairing.json) continue ;; esac
    printf '%s  %s\n' "$(sha256_of "$CONTENT/$f")" "$f" >> "$WORK/manifest"
done < "$WORK/files"
[ -s "$WORK/manifest" ] || { echo 'No files found.' >&2; exit 1; }
SUM=$(sha256_of "$WORK/manifest")

set_pin() {
    # set_pin <file> <begin of the line> <end of the line>: prints the file with the pin written into it
    awk -v begin="$2" -v end="$3" -v sum="$SUM" '
        index($0, begin) == 1 { n++; cr = ""; if ($0 ~ /\r$/) cr = "\r"; print begin sum end cr; next }
        { print }
        END { if (n != 1) exit 3 }' "$1"
}

STALE=0
if [ ! -f "$CONTENT/MANIFEST.sha256" ] || ! cmp -s "$WORK/manifest" "$CONTENT/MANIFEST.sha256"; then
    STALE=1
    [ "$CHECK" = 1 ] && echo 'MANIFEST.sha256 does not describe the files of the kit.' >&2
fi
for f in bootstrap.sh bootstrap.ps1; do
    [ -f "$CONTENT/$f" ] || continue
    # shellcheck disable=SC2016  # the PowerShell variable is text here
    case $f in
        bootstrap.sh) begin="KIT_MANIFEST_SHA256='" ;;
        *) begin='$KitManifestSha256 = '"'" ;;
    esac
    if ! set_pin "$CONTENT/$f" "$begin" "'" > "$WORK/$f"; then
        echo "$f: expected exactly one line that starts with $begin" >&2
        exit 1
    fi
    if ! cmp -s "$WORK/$f" "$CONTENT/$f"; then
        STALE=1
        [ "$CHECK" = 1 ] && echo "$f does not carry the SHA-256 of MANIFEST.sha256." >&2
    fi
done

if [ "$CHECK" = 1 ]; then
    if [ "$STALE" = 1 ]; then
        echo 'Run   bash tools/make-manifest.sh   and commit the result.' >&2
        exit 1
    fi
    echo "MANIFEST.sha256 is up to date ($(wc -l < "$WORK/manifest" | tr -d ' ') files, SHA-256 $SUM)."
    exit 0
fi

cp "$WORK/manifest" "$ROOT/MANIFEST.sha256" || exit 1
for f in bootstrap.sh bootstrap.ps1; do
    [ -f "$ROOT/$f" ] || continue
    # shellcheck disable=SC2016
    case $f in
        bootstrap.sh) begin="KIT_MANIFEST_SHA256='" ;;
        *) begin='$KitManifestSha256 = '"'" ;;
    esac
    set_pin "$ROOT/$f" "$begin" "'" > "$WORK/$f.new" || { echo "$f: expected exactly one line that starts with $begin" >&2; exit 1; }
    cmp -s "$WORK/$f.new" "$ROOT/$f" || cat "$WORK/$f.new" > "$ROOT/$f"
done
echo "MANIFEST.sha256: $(wc -l < "$WORK/manifest" | tr -d ' ') files, SHA-256 $SUM (written into bootstrap.sh and bootstrap.ps1)."
