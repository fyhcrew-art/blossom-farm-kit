#!/bin/bash
# Releases the kit. There is no build server: a release is two commits on
# main, made on a maintainer's computer, and everything a customer's computer
# later downloads is fetched by commit and checked against a pinned SHA-256
# (docs/RELEASING.md has the whole procedure; docs/security.md, section 9,
# the chain of checks).
#
#   bash tools/release.sh kit [--offline]
#       Step 1, before the commit that IS the kit. Regenerates MANIFEST.sha256
#       and the value in the bootstrap files, checks that the three provider
#       programs versions.json names can be downloaded and have the pinned
#       SHA-256 (not with --offline), and runs tools/check.sh. Then you
#       commit and push.
#
#   bash tools/release.sh pairing [--offline] [--no-commit]
#       Step 2, with the kit commit checked out, clean and pushed. Writes
#       pairing.json, which names that commit, its kit version, the SHA-256 of
#       its two bootstrap files and of its MANIFEST.sha256, and commits it. A
#       commit cannot name itself, so this is a second commit, and it changes
#       pairing.json only. Before writing, the chain is run against GitHub:
#       bootstrap.sh is fetched by that commit, compared, and run with
#       --verify-only (not with --offline). Then you push.
#
#   bash tools/release.sh verify
#       Proves a release from the outside, with real downloads: the three
#       programs, the bootstrap files of the commit pairing.json names, the
#       whole chain with --verify-only, a kit that was tampered with (which
#       must fail), and whether the branch main already shows this release.
#
# Needs git, curl, tar, and for "kit" what tools/check.sh needs.
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$KIT" || exit 1
REPOSITORY='fyhcrew-art/blossom-farm-kit'
RAW="https://raw.githubusercontent.com/$REPOSITORY"

STEP=${1:-}
[ $# -gt 0 ] && shift
OFFLINE=0; COMMIT=1
while [ $# -gt 0 ]; do
    case $1 in
        --offline) OFFLINE=1 ;;
        --no-commit) COMMIT=0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { printf '\nSTOPPED: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }
sha256_of() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'; else shasum -a 256 "$1" | awk '{ print $1 }'; fi; }
pin() { LC_ALL=C awk -f "$KIT/lib/json.awk" < "${2:-$KIT/versions.json}" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'; }
fetch() {
    # fetch <address> <out file>: a complete answer 200, or status 1
    local code
    code=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 -sS -L --max-redirs 5 --connect-timeout 30 --max-time 1800 -o "$2" -w '%{http_code}' "$1") || { rm -f "$2"; return 1; }
    [ "$code" = 200 ] || { rm -f "$2"; echo "   HTTP $code: $1" >&2; return 1; }
}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/farmkit-release.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

check_provider_pins() {
    # The three addresses: this repository, one commit, the folder of the version.
    local tag commit key url want got
    tag=$(pin gadsDrag.releaseTag)
    commit=$(pin gadsDrag.url | cut -d/ -f6)
    for key in gadsDrag macos.arm64.provider macos.x86_64.provider; do
        url=$(pin "$key.url"); want=$(pin "$key.sha256")
        printf '%s\n' "$url" | LC_ALL=C grep -Eq "^$RAW/[0-9a-f]{40}/$tag/GADS-drag[A-Za-z0-9.-]*\$" || die "$key.url is not an address of the form $RAW/<commit of the branch dist>/$tag/<file>: $url"
        [ "$(printf '%s' "$url" | cut -d/ -f6)" = "$commit" ] || die "The three provider addresses in versions.json name different commits."
        if [ "$OFFLINE" = 1 ]; then continue; fi
        say "   downloading $url"
        fetch "$url" "$TMP/program" || die "$url cannot be downloaded. Publish the programs first: tools/build-provider.sh, then tools/publish-dist.sh --push."
        got=$(sha256_of "$TMP/program")
        [ "$got" = "$want" ] || die "$url has SHA-256 $got, but versions.json pins $want ($key.sha256)."
        say "   [ok] $(wc -c < "$TMP/program" | tr -d ' ') bytes, SHA-256 $got"
    done
    rm -f "$TMP/program"
}

verify_chain() {
    # verify_chain <commit> <expected SHA-256 of bootstrap.sh> <expected SHA-256 of bootstrap.ps1>
    # What a customer's computer does, against GitHub, without installing.
    local commit=$1 out
    fetch "$RAW/$commit/bootstrap.sh" "$TMP/blossom-bootstrap.sh" || die "bootstrap.sh of commit $commit cannot be fetched from GitHub. Is the commit pushed?"
    fetch "$RAW/$commit/bootstrap.ps1" "$TMP/blossom-bootstrap.ps1" || die "bootstrap.ps1 of commit $commit cannot be fetched from GitHub."
    [ "$(sha256_of "$TMP/blossom-bootstrap.sh")" = "$2" ] || die "bootstrap.sh as GitHub serves it for $commit has SHA-256 $(sha256_of "$TMP/blossom-bootstrap.sh"), not $2."
    [ "$(sha256_of "$TMP/blossom-bootstrap.ps1")" = "$3" ] || die "bootstrap.ps1 as GitHub serves it for $commit has SHA-256 $(sha256_of "$TMP/blossom-bootstrap.ps1"), not $3."
    say "   [ok] bootstrap.sh and bootstrap.ps1 of $commit, fetched from GitHub, have the expected SHA-256"
    out=$(bash "$TMP/blossom-bootstrap.sh" --kit-commit "$commit" --verify-only 2>&1) || { printf '%s\n' "$out" >&2; die 'The bootstrap file, run with --verify-only against GitHub, did not accept the kit.'; }
    printf '%s\n' "$out" | sed -n 's/^   \[ok\]/   [ok]/p'
    if command -v pwsh > /dev/null 2>&1 || command -v powershell > /dev/null 2>&1; then
        local ps=pwsh
        command -v pwsh > /dev/null 2>&1 || ps=powershell
        out=$("$ps" -NoProfile -ExecutionPolicy Bypass -File "$TMP/blossom-bootstrap.ps1" -KitCommit "$commit" -VerifyOnly 2>&1) || { printf '%s\n' "$out" >&2; die 'bootstrap.ps1, run with -VerifyOnly against GitHub, did not accept the kit.'; }
        say "   [ok] bootstrap.ps1 -VerifyOnly ($ps) accepted the same kit from its .zip archive"
    fi
}

case $STEP in
kit)
    say '== The list of files'
    bash tools/make-manifest.sh || die 'tools/make-manifest.sh failed.'
    say '== The provider programs versions.json names'
    [ "$(pin gadsDrag.redistributeEmbeddedResources)" = true ] || die 'versions.json does not record the decision to publish the provider programs (gadsDrag.redistributeEmbeddedResources). Read docs/RELEASING.md.'
    check_provider_pins
    say '== tools/check.sh'
    bash tools/check.sh || die 'A check failed. Nothing is released from a kit that does not pass.'
    say ''
    say "Kit $(pin kit) is ready to be committed. Next:"
    say '   git add -A      (look at "git status" first: nothing from a real farm, no binary)'
    say "   git commit -m 'Kit $(pin kit)'"
    say '   git push origin main'
    say '   bash tools/release.sh pairing'
    ;;
pairing)
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die 'The working tree has changes that are not committed. pairing.json names a commit: commit the kit first (tools/release.sh kit).'
    bash tools/make-manifest.sh --check > /dev/null 2>&1 || die 'MANIFEST.sha256 of this commit is stale. Run tools/release.sh kit, commit, and start again.'
    K=$(git rev-parse HEAD)
    if [ -f pairing.json ]; then
        WAS=$(pin kitCommit pairing.json)
        if [ "$WAS" != "$K" ] && git cat-file -e "$WAS^{commit}" 2> /dev/null && ! git diff --name-only "$WAS" HEAD | grep -q -v '^pairing\.json$'; then
            die "This commit differs from the released kit commit $WAS in pairing.json only: that release is already made. A new release needs a new kit commit."
        fi
    fi
    VERSION=$(pin kit)
    for f in bootstrap.sh bootstrap.ps1 MANIFEST.sha256; do
        git show "$K:$f" > "$TMP/$f" 2> /dev/null || die "This commit lacks $f."
    done
    SH=$(sha256_of "$TMP/bootstrap.sh"); PS1=$(sha256_of "$TMP/bootstrap.ps1"); LIST=$(sha256_of "$TMP/MANIFEST.sha256")
    if ! grep -q "'$LIST'" "$TMP/bootstrap.sh" || ! grep -q "'$LIST'" "$TMP/bootstrap.ps1"; then
        die 'The bootstrap files of this commit do not carry the SHA-256 of its MANIFEST.sha256.'
    fi
    say "== Kit $VERSION, commit $K"
    if [ "$OFFLINE" = 0 ]; then
        say '== The chain, against GitHub'
        verify_chain "$K" "$SH" "$PS1"
    fi
    cat > pairing.json << JSON
{
  "kitVersion": "$VERSION",
  "kitCommit": "$K",
  "bootstrapShSha256": "$SH",
  "bootstrapPs1Sha256": "$PS1",
  "manifestSha256": "$LIST"
}
JSON
    say '== pairing.json'
    cat pairing.json
    if [ "$COMMIT" = 1 ]; then
        if ! git add pairing.json || ! git commit -q -m "Release kit $VERSION: pairing.json names commit $K" -- pairing.json; then die 'Could not commit pairing.json.'; fi
        [ "$(git diff --name-only "$K" HEAD)" = pairing.json ] || die 'The release commit changed more than pairing.json.'
        say ''
        say "Committed. Push it:   git push origin main"
    else
        say ''
        say 'Written, not committed (--no-commit). Commit pairing.json alone, then push.'
    fi
    say 'After the push:   bash tools/release.sh verify'
    say 'Blossom CRM reads pairing.json from the branch main by itself; nothing has to be handed over.'
    ;;
verify)
    [ -f pairing.json ] || die 'There is no pairing.json: no release was made from this checkout.'
    K=$(pin kitCommit pairing.json)
    say "== The provider programs versions.json names"
    check_provider_pins
    say "== The chain for kit $(pin kitVersion pairing.json), commit $K, against GitHub"
    verify_chain "$K" "$(pin bootstrapShSha256 pairing.json)" "$(pin bootstrapPs1Sha256 pairing.json)"
    say '== A kit that was tampered with must fail'
    fetch "https://github.com/$REPOSITORY/archive/$K.tar.gz" "$TMP/kit.tar.gz" || die 'The archive of the commit cannot be downloaded.'
    mkdir "$TMP/x" || exit 1
    tar -xzf "$TMP/kit.tar.gz" -C "$TMP/x" || die 'The archive of the commit cannot be unpacked.'
    . "$KIT/lib/farmkit.sh"
    problem=$(test_kit_tree "$TMP/x/${REPOSITORY##*/}-$K" "$(pin manifestSha256 pairing.json)")
    [ -z "$problem" ] || die "The archive GitHub serves for $K does not pass the list of pairing.json: $problem"
    say "   [ok] the archive GitHub serves for $K passes the list pairing.json names"
    echo '# tampered' >> "$TMP/x/${REPOSITORY##*/}-$K/install.sh"
    problem=$(test_kit_tree "$TMP/x/${REPOSITORY##*/}-$K" "$(pin manifestSha256 pairing.json)")
    [ -n "$problem" ] || die 'A changed install.sh was NOT noticed.'
    say "   [ok] with one line added to install.sh it is refused: $problem"
    say '== What the branch main shows (customers and Blossom CRM read it)'
    if fetch "$RAW/main/pairing.json" "$TMP/main-pairing.json" 2> /dev/null && cmp -s "$TMP/main-pairing.json" pairing.json; then
        say '   [ok] pairing.json on main is this one'
    else
        say '   NOT YET: pairing.json on main is missing or differs from this one. Until main is at this commit, Blossom CRM, the update check and "Code -> Download ZIP" do not see this release.'
    fi
    if fetch "$RAW/main/versions.json" "$TMP/main-versions.json" 2> /dev/null && [ "$(pin kit "$TMP/main-versions.json")" = "$(pin kitVersion pairing.json)" ]; then
        say "   [ok] versions.json on main says kit $(pin kitVersion pairing.json)"
    else
        say "   NOT YET: versions.json on main does not say kit $(pin kitVersion pairing.json)."
    fi
    ;;
*)
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 2
    ;;
esac
