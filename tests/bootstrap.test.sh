#!/bin/bash
# Tests for the chain of checks that brings a kit onto a computer:
#   tools/make-manifest.sh    writes MANIFEST.sha256 and pins it in the bootstrap files
#   bootstrap.sh              the one-command setup
#   lib/farmkit.sh            get_released_kit, fetch_kit_commit, test_kit_tree,
#                             test_kit_update_rules
#   scripts/update.sh         --check and --latest, run as a whole
# A small stand-in for the kit is packed the way GitHub packs a commit and
# served over https by tests/fake-blossom.js; the scripts are run against it:
# an unchanged kit, a changed file, a file or a folder too many, a list that
# was not regenerated, another commit's kit, a download that was cut short.
# scripts/update.sh runs unchanged from a copy of the kit whose library has a
# few lines added at its end: they point it at the stand-in server and at a
# folder of this run, and replace the checks that need root and a Mac.
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
# pairing.json, when a release was made: well-formed, and true for the commit it names
if [ -f "$KIT_ROOT/pairing.json" ]; then
    pj=$(cat "$KIT_ROOT/pairing.json")
    kc=$(json_get "$pj" kitCommit)
    ok test_git_commit_text "$kc"
    matches "$(json_get "$pj" kitVersion)" '^[0-9]+\.[0-9]+\.[0-9]+$' 'pairing.json names a kit version'
    for key in bootstrapShSha256 bootstrapPs1Sha256 manifestSha256; do
        matches "$(json_get "$pj" "$key")" '^[0-9a-f]{64}$' "pairing.json: $key is a SHA-256 in lower case"
    done
    if git -C "$KIT_ROOT" cat-file -e "$kc^{commit}" 2> /dev/null; then
        for pair in bootstrapShSha256:bootstrap.sh bootstrapPs1Sha256:bootstrap.ps1 manifestSha256:MANIFEST.sha256; do
            git -C "$KIT_ROOT" show "$kc:${pair#*:}" > "$WORK/at-commit" 2> /dev/null
            is "$(json_get "$pj" "${pair%%:*}")" "$(sha256_of "$WORK/at-commit")" "pairing.json: ${pair%%:*} is the SHA-256 of ${pair#*:} in the commit it names"
        done
        git -C "$KIT_ROOT" show "$kc:versions.json" > "$WORK/at-commit" 2> /dev/null
        is "$(json_get "$pj" kitVersion)" "$(json_file_get "$WORK/at-commit" kit)" 'pairing.json: kitVersion is the kit version of the commit it names'
        git -C "$KIT_ROOT" show "$kc:bootstrap.sh" > "$WORK/at-commit" 2> /dev/null
        ok grep -q "^KIT_MANIFEST_SHA256='$(json_get "$pj" manifestSha256)'\$" "$WORK/at-commit"
    fi
fi
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
cp -R "$SRC" "$WORK/t7"; mkdir -p "$WORK/t7/services/node_modules"
matches "$(test_kit_tree "$WORK/t7" "$LIST")" 'a folder that its list names no file for: services' 'an empty folder too many is named'
cp -R "$SRC" "$WORK/t8"; mkdir "$WORK/t8/lib/deeper"
matches "$(test_kit_tree "$WORK/t8" "$LIST")" 'a folder that its list names no file for: lib/deeper' 'also inside a folder of the kit'
cp -R "$SRC" "$WORK/t9"; printf 'x' > "$WORK/t9/install.sh
versions.json"
matches "$(test_kit_tree "$WORK/t9" "$LIST")" 'does not name' 'a file whose name is two listed names on two lines is not taken for them'
# The awk of macOS does not accept a value with a line break in "-v name=value":
# it prints an error and runs nothing. The comparison must not depend on that.
mkdir -p "$WORK/strict-awk"
REAL_AWK=$(command -v awk)
cat > "$WORK/strict-awk/awk" << SH
#!/bin/bash
prev=''
for a in "\$@"; do
    case \$prev in -v) case \$a in *'
'*) echo 'awk: newline in string' >&2; exit 2 ;; esac ;; esac
    prev=\$a
done
exec "$REAL_AWK" "\$@"
SH
chmod +x "$WORK/strict-awk/awk"
is "$(PATH="$WORK/strict-awk:$PATH" test_kit_tree "$SRC" "$LIST")" '' 'with an awk that refuses a line break in -v: an unchanged kit passes'
matches "$(PATH="$WORK/strict-awk:$PATH" test_kit_tree "$WORK/t2" "$LIST")" 'does not name: scripts/extra.sh' 'and a file too many is still named'
matches "$(PATH="$WORK/strict-awk:$PATH" test_kit_tree "$WORK/t7" "$LIST")" 'names no file for: services' 'and a folder too many'
mkdir -p "$WORK/no-comm"
printf '#!/bin/bash\nexit 2\n' > "$WORK/no-comm/comm"; chmod +x "$WORK/no-comm/comm"
matches "$(PATH="$WORK/no-comm:$PATH" test_kit_tree "$SRC" "$LIST")" 'could not be compared' 'a comparison that cannot be carried out is a problem, not "nothing found"'

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
# sideways: the same or a higher version in another spelling
for v in 9.9.9.0 9.9.09 09.9.9 9.9.9.0.9 9.9 9.9.9. 9.9.10.0 9.10 010.0.0 '9.9.10 ' 10.0.0-1; do
    matches "$(test_kit_update_rules "$OLD" "$(printf '%s' "$NEWER" | sed "s/\"kit\": \"9.9.10\"/\"kit\": \"$v\"/")")" 'no usable kit version' "the kit version [$v] is not a version"
done
matches "$(test_kit_update_rules "$(printf '%s' "$OLD" | sed 's/"kit": "9.9.9"/"kit": "9.9"/')" "$NEWER")" 'not newer' 'a kit whose own version is not well-formed accepts no successor by comparison'
for v in V6.0.0-drag.1 'v6.0.0-drag.1 ' v6.0.0-DRAG.1 6.0.0-drag.1 'v6.0.0 drag'; do
    matches "$(test_kit_update_rules "$OLD" "$(printf '%s' "$NEWER" | sed "s/\"version\": \"v6.0.0-drag.1\"/\"version\": \"$v\"/; s/$(printf '%064d' 1)/$(printf '%064d' 2)/")")" 'gadsDrag.version is not written like a version' "another file under the provider version [$v] is refused"
done
matches "$(test_kit_update_rules "$OLD" "$(printf '%s' "$NEWER" | sed 's/"version": "v6.0.0"/"version": "V6.0.0"/')")" 'gads.version is not written like a version' 'the same for the version of GADS'
matches "$(test_kit_update_rules "$OLD" '{ "kit": "9.9.10" }')" 'gads.version is not written like a version' 'a kit that names no program versions is refused'
is "$(describe_kit_versions "$OLD")" 'kit 9.9.9, hub v6.0.0, provider v6.0.0-drag.1' 'describe_kit_versions: one line'

describe 'version_greater'
ok version_greater 1.0.1 1.0.0
ok version_greater 1.10.0 1.9.9
ok version_greater 2.0.0 1.99.99
not_ok version_greater 1.0.0 1.0.0
not_ok version_greater 1.0.0 1.0.1
not_ok version_greater 1.0 1.0.0
not_ok version_greater 1.0.0.1 1.0.0
not_ok version_greater 01.0.1 1.0.0
not_ok version_greater 1.0.1 ''
not_ok version_greater '' 1.0.0
not_ok version_greater 1.0.1 latest
ok test_kit_version_text 0.0.1
not_ok test_kit_version_text 1.0.0.
not_ok test_kit_version_text ' 1.0.0'
not_ok test_kit_version_text 1.0.1234567
ok test_program_version_text v6.0.0
ok test_program_version_text v6.0.0-drag.12
not_ok test_program_version_text v6.0.0-
not_ok test_program_version_text ''
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
cp -R "$SRC" "$WORK/evil6"; mkdir -p "$WORK/evil6/services/node_modules"
pack "$WORK/evil6" "$K2"
refused "$K2" 'a folder that its list names no file for: services' 'an empty folder too many is refused'
PLAIN_PATH=$PATH
PATH="$WORK/strict-awk:$PATH"
refused "$K2" 'a folder that its list names no file for: services' 'the same with an awk that refuses a line break in -v'
pack "$WORK/evil2" "$K2"
refused "$K2" 'a file that its list does not name: scripts/extra.sh' 'and a file too many, with that awk'
out=$(bash "$BOOT" --kit-commit "$K" --verify-only 2>&1); code=$?
is "$code" 0 "and the unchanged kit passes with that awk: $out"
PATH=$PLAIN_PATH
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
pack "$WORK/evil6" "$K2"
fetched "$K2" "$LIST"; code=$?
is "$code" 1 'a kit with an empty folder too many is refused'
matches "$FETCHED_KIT_ERROR" 'names no file for: services' 'with the reason'
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
# scripts/update.sh as a whole. The installed kit is a stand-in (version
# 9.9.9) with the real lib/farmkit.sh, lib/json.awk and scripts/update.sh.
# The lines added to the END of its library are the only difference to what
# runs on a Mac: where the kit is looked for, where it is installed, and no
# check for root and macOS. The kit that is fetched is another stand-in whose
# scripts/update.sh writes down how it was called.
describe 'scripts/update.sh --check and --latest'
U=$WORK/u
INST=$U/opt/blossom-farm-kit
K3=4444444444444444444444444444444444444444
new_installed() {
    rm -rf "$U"
    mkdir -p "$U/opt" "$U/farm"
    new_stand_in "$INST" 9.9.9
    cp "$KIT_ROOT/lib/farmkit.sh" "$KIT_ROOT/lib/json.awk" "$INST/lib/"
    cp "$KIT_ROOT/scripts/update.sh" "$INST/scripts/update.sh"
    cat >> "$INST/lib/farmkit.sh" << SH

# --- added by tests/bootstrap.test.sh ---
FARM_KIT_HOME='$INST'
FARM_KIT_RAW_URL='$BASE/raw'
FARM_KIT_ARCHIVE_URL='$BASE/archive'
assert_macos_root() { :; }
use_protected_kit_folder() { :; }
read_farm_config() { FARM_HAS_CONFIG=0; [ -f '$U/farm/installed' ] && FARM_HAS_CONFIG=1; return 0; }
chown() { :; }
SH
    : > "$U/farm/installed"
}
new_next() {
    # new_next <kit version> [provider sha256]: the kit that main will announce
    new_stand_in "$WORK/next" "$@"
    cat > "$WORK/next/scripts/update.sh" << 'SH'
#!/bin/bash
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
printf '%s\n' "$#" "$@" > "$here/update-called.txt"
echo "the update script of the new kit ran in $here"
SH
    bash "$MAKE_MANIFEST" --tree "$WORK/next" > /dev/null 2>&1
    NEXT_LIST=$(sha256_of "$WORK/next/MANIFEST.sha256")
}
announce() {
    # announce <kit version on main> <kit version in pairing.json> [commit]
    sed "s/\"kit\": \"[^\"]*\"/\"kit\": \"$1\"/" "$WORK/next/versions.json" > "$STATIC/raw/main/versions.json"
    printf '{ "kitVersion": "%s", "kitCommit": "%s", "manifestSha256": "%s" }\n' "$2" "${3:-$K3}" "$NEXT_LIST" > "$STATIC/raw/main/pairing.json"
}
tree_of() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort; find . -type d | LC_ALL=C sort); }
update() { out=$(bash "$INST/scripts/update.sh" "$@" 2>&1); code=$?; }
# unchanged <what>: the installed kit is the one from before, nothing is next to it
unchanged() {
    is "$(tree_of "$INST")" "$BEFORE" "$1: the installed kit is unchanged"
    is "$(find "$U/opt" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 1 "$1: nothing is left next to it"
    case $out in *'update script of the new kit ran'*) fail "$1: the update script of the fetched kit ran" ;; *) pass ;; esac
}

new_next 9.9.10
pack "$WORK/next" "$K3"
new_installed
BEFORE=$(tree_of "$INST")

announce 9.9.10 9.9.10
update --check
is "$code" 0 "--check with a newer kit on main: $out"
matches "$out" 'Kit 9.9.10 is available \(commit 4444' 'says which kit and which commit'
unchanged '--check'

announce 9.9.9 9.9.9
update --latest
is "$code" 0 'the same version on main'
matches "$out" 'This kit is the newest one' 'says so'
unchanged 'the same version'
announce 9.9.8 9.9.8
update --latest
is "$code" 0 'an older version on main'
matches "$out" 'This kit is the newest one' 'says so'
unchanged 'an older version'
for v in 9.9.9.1 9.9.10.0 9.10 09.9.10 latest; do
    announce "$v" "$v"
    update --latest
    is "$code" 1 "main names the kit [$v]"
    matches "$out" 'names no kit version' "[$v]: with the reason"
    unchanged "the kit version [$v]"
done
announce 9.9.10 9.9.9
update --latest
is "$code" 0 'a version on main that pairing.json does not name yet'
matches "$out" 'being prepared' 'says that it is not released'
unchanged 'a kit that is not released'

announce 9.9.11 9.9.11
update --latest
is "$code" 1 'main announces another version than the commit holds'
matches "$out" 'says it is kit 9.9.10, but the repository announced kit 9.9.11' 'with the reason'
unchanged 'another version than announced'

announce 9.9.10 9.9.10
cp -R "$WORK/next" "$WORK/next-evil"; echo 'echo evil' >> "$WORK/next-evil/scripts/update.sh"
pack "$WORK/next-evil" "$K3"
update --latest
is "$code" 1 'a changed file in the archive'
matches "$out" 'did not pass its check.*scripts/update.sh is not the one the list names' 'with the reason'
unchanged 'a changed file'
bash "$MAKE_MANIFEST" --tree "$WORK/next-evil" > /dev/null 2>&1
pack "$WORK/next-evil" "$K3"
update --latest
is "$code" 1 'a changed file with a rewritten list'
matches "$out" 'list of files is not the expected one' 'with the reason'
unchanged 'a changed file with a rewritten list'
cp -R "$WORK/next" "$WORK/next-dir"; mkdir "$WORK/next-dir/extra-folder"
pack "$WORK/next-dir" "$K3"
update --latest
is "$code" 1 'an empty folder too many in the archive'
unchanged 'a folder too many'
pack "$WORK/next" "$K3"
size=$(wc -c < "$STATIC/archive/$K3.tar.gz" | tr -d ' ')
echo $((size / 2)) > "$STATIC/archive/$K3.tar.gz.cut"
update --latest
is "$code" 1 'a download that breaks off'
matches "$out" 'could not be downloaded' 'with the reason'
unchanged 'a download that breaks off'
rm -f "$STATIC/archive/$K3.tar.gz.cut"
head -c $((size / 2)) "$STATIC/archive/$K3.tar.gz" > "$WORK/half" && cat "$WORK/half" > "$STATIC/archive/$K3.tar.gz"
update --latest
is "$code" 1 'half an archive'
matches "$out" 'incomplete or damaged' 'with the reason'
unchanged 'half an archive'
announce 9.9.10 9.9.10 5555555555555555555555555555555555555555
update --latest
is "$code" 1 'a commit the repository does not have'
unchanged 'a missing commit'

# another file for the provider under the version the installed kit pins
new_next 9.9.10 "$(printf '%064d' 2)"
pack "$WORK/next" "$K3"
announce 9.9.10 9.9.10
update --latest
is "$code" 1 'a kit that pins another provider file under the same provider version'
matches "$out" 'was refused. It pins another file for the provider v6.0.0-drag.1' 'with the reason'
unchanged 'a changed pin'
sed 's/v6.0.0-drag.1/V6.0.0-drag.1/' "$WORK/next/versions.json" > "$WORK/v.json" && cat "$WORK/v.json" > "$WORK/next/versions.json"
bash "$MAKE_MANIFEST" --tree "$WORK/next" > /dev/null 2>&1
NEXT_LIST=$(sha256_of "$WORK/next/MANIFEST.sha256")
pack "$WORK/next" "$K3"
announce 9.9.10 9.9.10
update --latest
is "$code" 1 'the same with the provider version in another spelling'
matches "$out" 'was refused. Its gadsDrag.version is not written like a version' 'with the reason'
unchanged 'a changed pin under a respelled version'

new_next 9.9.10
pack "$WORK/next" "$K3"
announce 9.9.10 9.9.10
rm -f "$U/farm/installed"
update --latest
is "$code" 1 'a computer without a farm'
matches "$out" 'no farm installation' 'with the reason'
unchanged 'no farm'
: > "$U/farm/installed"
out=$(env -u CURL_CA_BUNDLE bash "$INST/scripts/update.sh" --latest 2>&1); code=$?
is "$code" 1 'a certificate that cannot be verified'
unchanged 'an untrusted connection'
update --check --latest
is "$code" 1 'two of --check, --latest, --rollback at a time are refused'
unchanged 'two options'

# and the kit that passes everything
update --latest --provider-binary '/a path/GADS-drag'
is "$code" 0 "a newer kit is fetched, checked and put in place: $out"
matches "$out" 'Commit:    4444444444444444444444444444444444444444' 'the commit is shown before the kit is replaced'
matches "$out" 'This kit:  kit 9.9.9, hub v6.0.0, provider v6.0.0-drag.1' 'and the versions of this kit'
matches "$out" 'New kit:   kit 9.9.10, hub v6.0.0, provider v6.0.0-drag.1' 'and of the new one'
matches "$out" 'the update script of the new kit ran in .*/opt/blossom-farm-kit' 'the update script of the new kit continues'
is "$(printf '%s\n' "$out" | grep -E 'New kit:|update script of the new kit ran' | cut -c1-10 | tr '\n' '|')" '   New kit|the update|' 'in that order'
is "$(tr '\n' '|' < "$INST/update-called.txt")" '2|--provider-binary|/a path/GADS-drag|' 'with the option that belongs to it, and not --latest'
is "$(json_file_get "$INST/versions.json" kit)" 9.9.10 'the kit folder holds the new kit'
is "$(sha256_of "$INST/MANIFEST.sha256")" "$NEXT_LIST" 'with its list'
not_ok test -e "$INST/bootstrap.sh"
not_ok test -e "$INST/pairing.json"
ok cmp -s "$INST.previous/scripts/update.sh" "$KIT_ROOT/scripts/update.sh"
is "$(json_file_get "$INST.previous/versions.json" kit)" 9.9.9 'the kit before it is kept as .previous'
is "$(find "$U/opt" -mindepth 1 -maxdepth 1 | LC_ALL=C sort | sed "s|$U/opt/||" | tr '\n' ' ')" 'blossom-farm-kit blossom-farm-kit.previous ' 'and nothing else is left'

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
    printf 'bash %s: all %d bootstrap tests passed.\n' "$BASH_VERSION" "$PASSED"
    exit 0
fi
printf 'bash %s: %d of %d bootstrap tests FAILED.\n' "$BASH_VERSION" "$FAILED" $((PASSED + FAILED))
exit 1
