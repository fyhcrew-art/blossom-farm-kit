#!/bin/bash
# Tests for the chain of checks that brings a kit onto a computer:
#   tools/make-manifest.sh    writes MANIFEST.sha256 and pins it in the bootstrap files
#   bootstrap.sh              the one-command setup
#   lib/farmkit.sh            get_released_kit, fetch_kit_commit, test_kit_tree,
#                             test_kit_update_rules (scripts/update.sh --latest)
# A small stand-in for the kit is packed the way GitHub packs a commit and
# served over https by tests/fake-blossom.js; the scripts are run against it:
# an unchanged kit, a changed file, a file too many, a list that was not
# regenerated, another commit's kit, a download that was cut short.
#
#   bash tests/bootstrap.test.sh
#
# Plain bash. Needs node, curl, openssl and tar; nothing here needs a Mac or
# root, and nothing leaves this computer.

# The test data is single-quoted on purpose; cleanup runs as a trap.
# shellcheck disable=SC2016,SC2329

set -u
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT_ROOT=$(dirname "$TESTS_DIR")
MAKE_MANIFEST=$KIT_ROOT/tools/make-manifest.sh
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"

PASSED=0
FAILED=0
GROUP=''
WORK=$(mktemp -d "${TMPDIR:-/tmp}/farmkit-bootstrap.XXXXXX") || exit 1
FAKE_PID=''
cleanup() {
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2> /dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

describe() { GROUP=$1; }
pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf 'FAILED  %s: %s\n' "$GROUP" "$1"; }
is() { if [ "$1" = "$2" ]; then pass; else fail "$3"; printf '          got:  [%s]\n          want: [%s]\n' "$1" "$2"; fi; }
ok() { if "$@"; then pass; else fail "expected success: $*"; fi; }
not_ok() { if "$@"; then fail "expected failure: $*"; else pass; fi; }
matches() { if printf '%s\n' "$1" | LC_ALL=C grep -Eq -- "$2"; then pass; else fail "$3"; printf '          text: [%s]\n' "$1"; fi; }
sha256_of() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'; else shasum -a 256 "$1" | awk '{ print $1 }'; fi; }

# ---------------------------------------------------------------------------
describe 'the kit and its list of files'
if git -C "$KIT_ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1 && [ "$(cd "$(git -C "$KIT_ROOT" rev-parse --show-toplevel)" && pwd -P)" = "$(cd "$KIT_ROOT" && pwd -P)" ]; then
    out=$(bash "$MAKE_MANIFEST" --check 2>&1); code=$?
else
    out=$(bash "$MAKE_MANIFEST" --tree "$KIT_ROOT" --check 2>&1); code=$?
fi
is "$code" 0 "MANIFEST.sha256 and the bootstrap files are up to date (run   bash tools/make-manifest.sh   ): $out"
for f in bootstrap.sh bootstrap.ps1; do
    is "$(grep -c "'$(sha256_of "$KIT_ROOT/MANIFEST.sha256")'" "$KIT_ROOT/$f" | tr -d ' ')" 1 "$f carries the SHA-256 of MANIFEST.sha256"
    not_ok grep -q "  $f\$" "$KIT_ROOT/MANIFEST.sha256"
done
not_ok grep -q -E '  (MANIFEST\.sha256|pairing\.json)$' "$KIT_ROOT/MANIFEST.sha256"
ok grep -q '  install.sh$' "$KIT_ROOT/MANIFEST.sha256"
ok grep -q '  lib/FarmKit.psm1$' "$KIT_ROOT/MANIFEST.sha256"
empty=$(test_kit_tree "$KIT_ROOT/tests/no-such-folder" "$(printf '%064d' 0)")
matches "$empty" 'no MANIFEST' 'test_kit_tree: a folder without a list is refused'

# A stand-in for the kit: its install.sh writes down how it was called.
new_stand_in() {
    # new_stand_in <folder> <kit version> [provider sha256]
    rm -rf "$1"
    mkdir -p "$1/lib" "$1/scripts"
    cp "$KIT_ROOT/bootstrap.sh" "$KIT_ROOT/bootstrap.ps1" "$1/"
    printf '{ "kit": "%s", "gads": { "version": "v6.0.0", "hubExeSha256": "%s" }, "gadsDrag": { "version": "v6.0.0-drag.1", "url": "https://example.org/GADS-drag.exe", "sha256": "%s" } }\n' "$2" "$(printf '%064d' 7)" "${3:-$(printf '%064d' 1)}" > "$1/versions.json"
    printf '{ "kitVersion": "0.0.1", "kitCommit": "%s" }\n' "$(printf '%040d' 0)" > "$1/pairing.json"
    echo 'a library' > "$1/lib/farmkit.sh"
    echo '#!/bin/bash' > "$1/scripts/update.sh"
    cat > "$1/install.sh" << 'SH'
#!/bin/bash
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
printf '%s\n' "$#" "$@" > "$here/called-with.txt"
echo "the stand-in installer ran in $here"
SH
}
pack() {
    # pack <folder> <commit the archive is served for> [commit in the name of its top folder]
    local top="blossom-farm-kit-${3:-$2}"
    rm -rf "$WORK/pack"
    mkdir -p "$WORK/pack" "$STATIC/archive"
    cp -R "$1" "$WORK/pack/$top"
    rm -f "$STATIC/archive/$2.tar.gz" "$STATIC/archive/$2.tar.gz.cut"
    tar -czf "$STATIC/archive/$2.tar.gz" -C "$WORK/pack" "$top"
}

describe 'tools/make-manifest.sh'
SRC=$WORK/src
new_stand_in "$SRC" 9.9.9
out=$(bash "$MAKE_MANIFEST" --tree "$SRC" --check 2>&1); code=$?
is "$code" 1 'a kit without a list is stale'
out=$(bash "$MAKE_MANIFEST" --tree "$SRC" 2>&1); code=$?
is "$code" 0 'writes the list'
LIST=$(sha256_of "$SRC/MANIFEST.sha256")
is "$(awk '{ print $2 }' "$SRC/MANIFEST.sha256" | tr '\n' ' ')" 'install.sh lib/farmkit.sh scripts/update.sh versions.json ' 'the list names every file but the four that cannot be on it'
is "$(awk -v f=install.sh '$2 == f { print $1 }' "$SRC/MANIFEST.sha256")" "$(sha256_of "$SRC/install.sh")" 'with its SHA-256'
ok grep -qx "KIT_MANIFEST_SHA256='$LIST'" "$SRC/bootstrap.sh"
ok grep -q "^\$KitManifestSha256 = '$LIST'" "$SRC/bootstrap.ps1"
ok bash -n "$SRC/bootstrap.sh"
out=$(bash "$MAKE_MANIFEST" --tree "$SRC" --check 2>&1); code=$?
is "$code" 0 'and is then up to date'
echo '# changed' >> "$SRC/install.sh"
out=$(bash "$MAKE_MANIFEST" --tree "$SRC" --check 2>&1); code=$?
is "$code" 1 'a changed file makes it stale'
matches "$out" 'make-manifest' 'and the message says what to run'
bash "$MAKE_MANIFEST" --tree "$SRC" > /dev/null 2>&1
echo 'new' > "$SRC/lib/new-file.sh"
out=$(bash "$MAKE_MANIFEST" --tree "$SRC" --check 2>&1); code=$?
is "$code" 1 'a new file makes it stale'
rm -f "$SRC/lib/new-file.sh"
sed -e "s/^KIT_MANIFEST_SHA256='.*'/KIT_MANIFEST_SHA256='$(printf '%064d' 0)'/" "$SRC/bootstrap.sh" > "$WORK/b.sh" && cat "$WORK/b.sh" > "$SRC/bootstrap.sh"
out=$(bash "$MAKE_MANIFEST" --tree "$SRC" --check 2>&1); code=$?
is "$code" 1 'a bootstrap file with another value makes it stale'
echo 'x' > "$SRC/a name with spaces"
out=$(bash "$MAKE_MANIFEST" --tree "$SRC" 2>&1); code=$?
is "$code" 1 'a file name the list cannot carry is refused'
rm -f "$SRC/a name with spaces"
new_stand_in "$SRC" 9.9.9
bash "$MAKE_MANIFEST" --tree "$SRC" > /dev/null 2>&1
LIST=$(sha256_of "$SRC/MANIFEST.sha256")

describe 'test_kit_tree'
is "$(test_kit_tree "$SRC" "$LIST")" '' 'an unchanged kit passes'
matches "$(test_kit_tree "$SRC" "$(printf '%064d' 5)")" 'not the expected one' 'another list than the expected one is refused'
cp -R "$SRC" "$WORK/t1"; echo 'echo evil' >> "$WORK/t1/install.sh"
matches "$(test_kit_tree "$WORK/t1" "$LIST")" 'install.sh is not the one the list names' 'a changed file is named'
cp -R "$SRC" "$WORK/t2"; echo 'x' > "$WORK/t2/scripts/extra.sh"
matches "$(test_kit_tree "$WORK/t2" "$LIST")" 'does not name: scripts/extra.sh' 'a file too many is named'
cp -R "$SRC" "$WORK/t3"; rm "$WORK/t3/lib/farmkit.sh"
matches "$(test_kit_tree "$WORK/t3" "$LIST")" 'lib/farmkit.sh is missing' 'a missing file is named'
cp -R "$SRC" "$WORK/t4"; ln -s /etc/hosts "$WORK/t4/lib/link"
matches "$(test_kit_tree "$WORK/t4" "$LIST")" 'neither a file nor a folder' 'a link is refused'
cp -R "$SRC" "$WORK/t5"; printf '%s  ../outside\n' "$(printf '%064d' 3)" >> "$WORK/t5/MANIFEST.sha256"
matches "$(test_kit_tree "$WORK/t5" "$(sha256_of "$WORK/t5/MANIFEST.sha256")")" 'not a checksum and a file name' 'a list that points outside the kit is refused'
cp -R "$SRC" "$WORK/t6"; echo 'changed' >> "$WORK/t6/bootstrap.ps1"; rm "$WORK/t6/pairing.json"
is "$(test_kit_tree "$WORK/t6" "$LIST")" '' 'the files that cannot be on the list do not count'

describe 'test_kit_update_rules'
OLD=$(cat "$SRC/versions.json")
new_stand_in "$WORK/v" 9.9.10; NEWER=$(cat "$WORK/v/versions.json")
is "$(test_kit_update_rules "$OLD" "$NEWER")" '' 'a newer kit with the same pins is accepted'
matches "$(test_kit_update_rules "$OLD" "$OLD")" 'not newer' 'the same version is refused'
matches "$(test_kit_update_rules "$NEWER" "$OLD")" 'not newer' 'an older version is refused'
new_stand_in "$WORK/v" 9.10.0 "$(printf '%064d' 2)"
matches "$(test_kit_update_rules "$OLD" "$(cat "$WORK/v/versions.json")")" 'pins another file for the provider v6.0.0-drag.1.*gadsDrag.sha256' 'another file under the provider version this kit pins is refused'
is "$(test_kit_update_rules "$OLD" "$(sed 's/v6.0.0-drag.1/v6.0.0-drag.2/' "$WORK/v/versions.json")")" '' 'the same file change under a new provider version is accepted'
matches "$(test_kit_update_rules "$OLD" "$(printf '%s' "$NEWER" | sed "s/$(printf '%064d' 7)/$(printf '%064d' 8)/")")" 'pins another file for GADS v6.0.0' 'another hub under the same GADS version is refused'
matches "$(test_kit_update_rules "$OLD" "$(printf '%s' "$NEWER" | sed 's|https://example.org|http://example.org|')")" 'gadsDrag.url is not https' 'a download address that is not https is refused'
matches "$(test_kit_update_rules "$OLD" '{ "kit": "latest" }')" 'no usable kit version' 'a version that is not a number is refused'
REAL=$(cat "$KIT_ROOT/versions.json")
matches "$(test_kit_update_rules "$REAL" "$REAL")" 'not newer' 'the real versions.json is read'
NEXT=$(printf '%s' "$REAL" | sed 's/"kit": "[0-9.]*"/"kit": "999.0.0"/')
is "$(test_kit_update_rules "$REAL" "$NEXT")" '' 'and a successor with the same pins passes'
matches "$(test_kit_update_rules "$REAL" "$(printf '%s' "$NEXT" | sed "s/$(json_get "$REAL" macos.x86_64.provider.sha256)/$(printf '%064d' 9)/")")" 'macos.x86_64.provider.sha256' 'one changed provider pin for another system is enough to refuse it'

for tool in node curl openssl tar; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        if [ -n "${FARMKIT_REQUIRE_STAND_IN:-}" ]; then echo "FAILED: $tool is not installed, and FARMKIT_REQUIRE_STAND_IN is set."; exit 1; fi
        echo "SKIPPED the tests against a stand-in server: $tool is not installed."
        [ "$FAILED" -eq 0 ] && { printf 'bash %s: %d tests passed, the rest skipped.\n' "$BASH_VERSION" "$PASSED"; exit 0; }
        exit 1
    fi
done

STATIC=$WORK/static
mkdir -p "$STATIC/archive" "$STATIC/raw/main"
node "$TESTS_DIR/fake-blossom.js" --dir "$WORK/fake" --static "$STATIC" > "$WORK/fake.log" 2>&1 &
FAKE_PID=$!
i=0
while [ ! -s "$WORK/fake/ports.json" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -s "$WORK/fake/ports.json" ]; then echo 'The stand-in server did not start:'; cat "$WORK/fake.log"; exit 1; fi
PORT=$(LC_ALL=C awk -f "$KIT_ROOT/lib/json.awk" < "$WORK/fake/ports.json" | awk -F '\t' '$1 == "https" { print $2 }')
BASE="https://127.0.0.1:$PORT/static"
export CURL_CA_BUNDLE="$WORK/fake/cert.pem"

# The bootstrap file under test: the one of the stand-in kit (it carries the
# SHA-256 of the stand-in's list), fetching from the stand-in server.
BOOT=$WORK/blossom-bootstrap.sh
sed -e "s|^KIT_ARCHIVE_URL='.*'|KIT_ARCHIVE_URL='$BASE/archive'|" "$SRC/bootstrap.sh" > "$BOOT"
K=1111111111111111111111111111111111111111
pack "$SRC" "$K"

# ---------------------------------------------------------------------------
describe 'bootstrap.sh'
out=$(bash "$BOOT" --dest "$WORK/never" 2>&1); code=$?
is "$code" 1 'without --kit-commit it refuses'
matches "$out" 'kit-commit' 'and names the option'
out=$(bash "$BOOT" --kit-commit main --dest "$WORK/never" 2>&1); code=$?
is "$code" 1 'a branch name is not a commit'
out=$(bash "$BOOT" --kit-commit "${K%1}" --dest "$WORK/never" 2>&1); code=$?
is "$code" 1 'nor is a short commit'
not_ok test -e "$WORK/never"

DEST=$WORK/opt/blossom-farm-kit
out=$(bash "$BOOT" --kit-commit "$K" --dest "$DEST" --app-origin https://app.blossom.example --pairing-code K7QM-2XVD-9HTR-4BWN-6CPA --domain 'agency.io' --with-appium 2>&1); code=$?
is "$code" 0 "downloads, checks, unpacks and starts the installer: $out"
matches "$out" 'every one of its 4 files has the SHA-256' 'says that every file was checked'
matches "$out" 'the stand-in installer ran' 'the installer of the kit ran'
ok test -f "$DEST/install.sh"
ok test -f "$DEST/versions.json"
ok test -f "$DEST/MANIFEST.sha256"
not_ok test -e "$DEST/bootstrap.sh"
not_ok test -e "$DEST/bootstrap.ps1"
not_ok test -e "$DEST/pairing.json"
is "$(tr '\n' ' ' < "$DEST/called-with.txt")" '7 --app-origin https://app.blossom.example --pairing-code K7QM-2XVD-9HTR-4BWN-6CPA --domain agency.io --with-appium ' 'with every option it was given, and not --dest or --kit-commit'
is "$(find "$WORK/opt" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 1 'nothing else is left behind'

echo 'kept from the first run' > "$DEST/marker.txt"
out=$(bash "$BOOT" --kit-commit="$K" --dest "$DEST" 2>&1); code=$?
is "$code" 0 'a second run replaces the kit'
not_ok test -f "$DEST/marker.txt"
is "$(cat "$DEST.previous/marker.txt" 2> /dev/null)" 'kept from the first run' 'and keeps the earlier one as .previous'
is "$(head -n 1 "$DEST/called-with.txt")" 0 'no options: none are handed on'

describe 'bootstrap.sh --verify-only'
before=$(find "$WORK/opt" | LC_ALL=C sort)
out=$(TMPDIR=$WORK/tmp1 && mkdir -p "$TMPDIR" && export TMPDIR && bash "$BOOT" --kit-commit "$K" --verify-only --dest "$WORK/opt-verify/kit" --app-origin https://app.blossom.example 2>&1); code=$?
is "$code" 0 'checks the whole chain'
matches "$out" 'every one of its 4 files' 'says so'
matches "$out" 'nothing was installed' 'and that nothing was installed'
not_ok test -e "$WORK/opt-verify"
is "$(find "$WORK/opt" | LC_ALL=C sort)" "$before" 'an installed kit is not touched'
is "$(find "$WORK/tmp1" -mindepth 1 | wc -l | tr -d ' ')" 0 'and nothing is left in the temporary folder'

# refused <commit> <pattern> <what>: the bootstrap stops, says why, leaves nothing
refused() {
    local d=$WORK/opt-refused out code
    rm -rf "$d"
    out=$(bash "$BOOT" --kit-commit "$1" --dest "$d/kit" 2>&1); code=$?
    is "$code" 1 "$3"
    matches "$out" "$2" "$3: the reason"
    case $out in *'stand-in installer ran'*) fail "$3: the installer ran" ;; *) pass ;; esac
    is "$(find "$d" -mindepth 1 2> /dev/null | wc -l | tr -d ' ')" 0 "$3: nothing was unpacked or left behind"
    out=$(bash "$BOOT" --kit-commit "$1" --verify-only 2>&1); code=$?
    is "$code" 1 "$3 (--verify-only)"
}

describe 'bootstrap.sh: a kit that was changed'
K2=2222222222222222222222222222222222222222
cp -R "$SRC" "$WORK/evil"; echo 'echo evil' >> "$WORK/evil/install.sh"
pack "$WORK/evil" "$K2"
refused "$K2" 'install.sh of the kit that was downloaded is not the one the list names' 'a changed file is refused'
# the attacker rewrites the list to match the changed file
bash "$MAKE_MANIFEST" --tree "$WORK/evil" > /dev/null 2>&1
pack "$WORK/evil" "$K2"
refused "$K2" 'list of files.*is not the one this file expects' 'a changed file with a rewritten list is refused'
cp -R "$SRC" "$WORK/evil2"; echo 'echo evil' > "$WORK/evil2/scripts/extra.sh"
pack "$WORK/evil2" "$K2"
refused "$K2" 'a file that its list does not name: scripts/extra.sh' 'a file too many is refused'
cp -R "$SRC" "$WORK/evil3"; rm "$WORK/evil3/lib/farmkit.sh"
pack "$WORK/evil3" "$K2"
refused "$K2" 'lacks the file lib/farmkit.sh' 'a missing file is refused'
cp -R "$SRC" "$WORK/evil4"; ln -s /etc/hosts "$WORK/evil4/lib/hosts"
pack "$WORK/evil4" "$K2"
refused "$K2" 'neither a file nor a folder' 'a link in the archive is refused'
cp -R "$SRC" "$WORK/evil5"; rm "$WORK/evil5/MANIFEST.sha256"
pack "$WORK/evil5" "$K2"
refused "$K2" 'no MANIFEST.sha256' 'a kit without a list is refused'
rm -rf "$WORK/pack"; mkdir -p "$WORK/pack/other"; cp -R "$SRC" "$WORK/pack/blossom-farm-kit-$K2"; echo x > "$WORK/pack/other/file"
tar -czf "$STATIC/archive/$K2.tar.gz" -C "$WORK/pack" "blossom-farm-kit-$K2" other
refused "$K2" 'outside the folder of this commit' 'an archive with something next to the kit folder is refused'
if tar --version 2> /dev/null | grep -q 'GNU tar'; then
    rm -rf "$WORK/pack"; mkdir -p "$WORK/pack"; cp -R "$SRC" "$WORK/pack/blossom-farm-kit-$K2"; echo x > "$WORK/pack/escape"
    tar -czf "$STATIC/archive/$K2.tar.gz" -C "$WORK/pack" --transform "s|^escape|blossom-farm-kit-$K2/../escape|" "blossom-farm-kit-$K2" escape 2> /dev/null
    refused "$K2" 'outside the folder of this commit' 'an archive that climbs out of the kit folder is refused'
    not_ok test -e "$WORK/opt-refused/escape"
fi

describe 'bootstrap.sh: a list that was not regenerated'
cp -R "$SRC" "$WORK/stale"; echo '# a later change' >> "$WORK/stale/scripts/update.sh"
pack "$WORK/stale" "$K2"
refused "$K2" 'scripts/update.sh of the kit that was downloaded is not the one the list names' 'a kit whose list is stale is refused'

describe 'bootstrap.sh: another commit'
new_stand_in "$WORK/other" 9.9.8
bash "$MAKE_MANIFEST" --tree "$WORK/other" > /dev/null 2>&1
pack "$WORK/other" "$K2"
refused "$K2" 'list of files.*is not the one this file expects' "another commit's kit, complete and with its own list, is refused"
pack "$SRC" "$K2" "$K"
refused "$K2" 'outside the folder of this commit' 'an archive made for another commit than the one asked for is refused'
refused 3333333333333333333333333333333333333333 'HTTP 404' 'a commit the repository does not have is reported'

describe 'bootstrap.sh: a download that was cut short'
pack "$SRC" "$K2"
size=$(wc -c < "$STATIC/archive/$K2.tar.gz" | tr -d ' ')
echo $((size / 2)) > "$STATIC/archive/$K2.tar.gz.cut"
refused "$K2" 'Downloading the kit failed' 'a connection that breaks off is reported'
rm -f "$STATIC/archive/$K2.tar.gz.cut"
head -c $((size / 2)) "$STATIC/archive/$K2.tar.gz" > "$WORK/half" && cat "$WORK/half" > "$STATIC/archive/$K2.tar.gz"
refused "$K2" 'incomplete or damaged' 'half an archive that arrives as a complete answer is refused'
head -c $((size - 20)) "$STATIC/archive/$K.tar.gz" > "$STATIC/archive/$K2.tar.gz"
out=$(bash "$BOOT" --kit-commit "$K2" --verify-only 2>&1); code=$?
is "$code" 1 'an archive that lacks its last bytes is refused'
: > "$STATIC/archive/$K2.tar.gz"
refused "$K2" 'incomplete or damaged' 'an empty answer is refused'
pack "$SRC" "$K2"
out=$(bash "$BOOT" --kit-commit "$K2" --verify-only 2>&1); code=$?
is "$code" 0 'the unchanged kit under that commit works again'

describe 'bootstrap.sh: the connection'
out=$(env -u CURL_CA_BUNDLE bash "$BOOT" --kit-commit "$K" --dest "$WORK/opt3/kit" 2>&1); code=$?
is "$code" 1 'a certificate that cannot be verified stops it'
not_ok test -e "$WORK/opt3/kit"
sed -e "s|^KIT_ARCHIVE_URL='https://|KIT_ARCHIVE_URL='http://|" "$BOOT" > "$WORK/plain.sh"
out=$(bash "$WORK/plain.sh" --kit-commit "$K" --dest "$WORK/opt4/kit" 2>&1); code=$?
is "$code" 1 'a download address that is not https stops it'
matches "$out" 'not https' 'with the reason'

# ---------------------------------------------------------------------------
describe 'a newer kit: get_released_kit'
FARM_KIT_RAW_URL=$BASE/raw
FARM_KIT_ARCHIVE_URL=$BASE/archive
W=$WORK/update; mkdir -p "$W"
cp "$SRC/versions.json" "$STATIC/raw/main/versions.json"
get_released_kit "$W"; code=$?
is "$code" 0 'main without pairing.json is not an error'
is "$RELEASED_KIT_VERSION/$RELEASED_KIT_COMMIT" '9.9.9/' 'the version is known, no commit is released'
printf '{ "kitVersion": "9.9.9", "kitCommit": "%s", "manifestSha256": "%s", "bootstrapShSha256": "%s", "bootstrapPs1Sha256": "%s" }\n' "$K" "$LIST" "$(sha256_of "$SRC/bootstrap.sh")" "$(sha256_of "$SRC/bootstrap.ps1")" > "$STATIC/raw/main/pairing.json"
get_released_kit "$W"; code=$?
is "$code/$RELEASED_KIT_VERSION/$RELEASED_KIT_COMMIT/$RELEASED_KIT_MANIFEST" "0/9.9.9/$K/$LIST" 'the released kit: version, commit, SHA-256 of its list'
sed 's/"kit": "9.9.9"/"kit": "9.9.10"/' "$SRC/versions.json" > "$STATIC/raw/main/versions.json"
get_released_kit "$W"; code=$?
is "$code/$RELEASED_KIT_VERSION/$RELEASED_KIT_COMMIT" '0/9.9.10/' 'a version on main that pairing.json does not name yet is not released'
cp "$SRC/versions.json" "$STATIC/raw/main/versions.json"
printf '{ "kitVersion": "9.9.9", "kitCommit": "main", "manifestSha256": "%s" }\n' "$LIST" > "$STATIC/raw/main/pairing.json"
get_released_kit "$W"; code=$?
is "$code" 1 'a pairing.json that names no commit is an error'
matches "$RELEASED_KIT_ERROR" 'does not name a commit' 'with the reason'
rm -f "$STATIC/raw/main/versions.json"
get_released_kit "$W"; code=$?
is "$code" 1 'a main that cannot be read is an error'
matches "$RELEASED_KIT_ERROR" 'could not be read \(HTTP 404\)' 'with the reason'
FARM_KIT_RAW_URL="http://127.0.0.1:$PORT/static/raw"
get_released_kit "$W"; code=$?
is "$code" 1 'an address that is not https is never asked'
FARM_KIT_RAW_URL=$BASE/raw

describe 'a newer kit: fetch_kit_commit'
fetched() { rm -rf "$W/stage"; mkdir -p "$W/stage"; fetch_kit_commit "$1" "$2" "$W/stage"; }
fetched "$K" "$LIST"; code=$?
is "$code" 0 "downloads and checks the kit of a commit: $FETCHED_KIT_ERROR"
ok test -f "$W/stage/kit/install.sh"
ok test -f "$W/stage/kit/MANIFEST.sha256"
not_ok test -e "$W/stage/kit/bootstrap.sh"
not_ok test -e "$W/stage/kit/pairing.json"
is "$(find "$W/stage" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 1 'and leaves nothing but the kit'
fetched "$K" "$(printf '%064d' 4)"; code=$?
is "$code" 1 'a kit whose list is not the announced one is refused'
matches "$FETCHED_KIT_ERROR" 'not the expected one' 'with the reason'
not_ok test -e "$W/stage/kit"
not_ok test -e "$W/stage/unpacked"
pack "$WORK/evil" "$K2"
fetched "$K2" "$LIST"; code=$?
is "$code" 1 'a changed kit is refused'
pack "$WORK/evil2" "$K2"
fetched "$K2" "$LIST"; code=$?
is "$code" 1 'a kit with a file too many is refused'
matches "$FETCHED_KIT_ERROR" 'does not name: scripts/extra.sh' 'with the reason'
pack "$WORK/stale" "$K2"
fetched "$K2" "$LIST"; code=$?
is "$code" 1 'a kit whose list is stale is refused'
pack "$SRC" "$K2" "$K"
fetched "$K2" "$LIST"; code=$?
is "$code" 1 'an archive made for another commit is refused'
pack "$SRC" "$K2"
echo 100 > "$STATIC/archive/$K2.tar.gz.cut"
fetched "$K2" "$LIST"; code=$?
is "$code" 1 'a download that breaks off is refused'
matches "$FETCHED_KIT_ERROR" 'could not be downloaded' 'with the reason'
rm -f "$STATIC/archive/$K2.tar.gz.cut"
head -c 300 "$STATIC/archive/$K.tar.gz" > "$STATIC/archive/$K2.tar.gz"
fetched "$K2" "$LIST"; code=$?
is "$code" 1 'half an archive is refused'
matches "$FETCHED_KIT_ERROR" 'incomplete or damaged' 'with the reason'
fetched main "$LIST"; code=$?
is "$code" 1 'a branch name is not fetched'
fetched 3333333333333333333333333333333333333333 "$LIST"; code=$?
is "$code" 1 'a commit that is not there is reported'
matches "$FETCHED_KIT_ERROR" 'HTTP 404' 'with the status'

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
    printf 'bash %s: all %d bootstrap tests passed.\n' "$BASH_VERSION" "$PASSED"
    exit 0
fi
printf 'bash %s: %d of %d bootstrap tests FAILED.\n' "$BASH_VERSION" "$FAILED" $((PASSED + FAILED))
exit 1
