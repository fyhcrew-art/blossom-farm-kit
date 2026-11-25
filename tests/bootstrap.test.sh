#!/bin/bash
# Tests for bootstrap.sh and .github/scripts/make-kit-release.sh: the chain
# of checksums of the one-command setup. A kit release is made from a small
# stand-in for the kit, served over https by tests/fake-blossom.js, and
# bootstrap.sh is run against it.
#
#   bash tests/bootstrap.test.sh
#
# Plain bash. Needs node, curl, openssl, zip and unzip; nothing here needs a
# Mac or root, and nothing leaves this computer.

# The test data is single-quoted on purpose; cleanup runs as a trap.
# shellcheck disable=SC2016,SC2329

set -u
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT_ROOT=$(dirname "$TESTS_DIR")
MAKE=$KIT_ROOT/.github/scripts/make-kit-release.sh

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
describe 'the template'
out=$(bash "$KIT_ROOT/bootstrap.sh" --dest "$WORK/never" 2>&1); code=$?
is "$code" 1 'the file of the source tree refuses to run'
matches "$out" 'template' 'and says that it is the template'
not_ok test -e "$WORK/never"
for f in bootstrap.sh bootstrap.ps1; do
    for placeholder in @KIT_TAG@ @KIT_BASE_URL@ @KIT_ARCHIVE@ @KIT_SUMS_SHA256@; do
        is "$(grep -c "'$placeholder'" "$KIT_ROOT/$f" | tr -d ' ')" 1 "$f sets $placeholder in exactly one place"
    done
done

for tool in node curl openssl zip unzip; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        if [ -n "${FARMKIT_REQUIRE_STAND_IN:-}" ]; then echo "FAILED: $tool is not installed, and FARMKIT_REQUIRE_STAND_IN is set."; exit 1; fi
        echo "SKIPPED the tests against a stand-in release: $tool is not installed."
        [ "$FAILED" -eq 0 ] && { printf 'bash %s: %d tests passed, the rest skipped.\n' "$BASH_VERSION" "$PASSED"; exit 0; }
        exit 1
    fi
done

# A stand-in for the kit: its install.sh writes down how it was called.
SRC=$WORK/src
mkdir -p "$SRC/lib"
cp "$KIT_ROOT/bootstrap.sh" "$KIT_ROOT/bootstrap.ps1" "$SRC/"
printf '{ "kit": "9.9.9" }\n' > "$SRC/versions.json"
cat > "$SRC/install.sh" <<'SH'
#!/bin/bash
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
printf '%s\n' "$#" "$@" > "$here/called-with.txt"
echo "the stand-in installer ran in $here"
SH

mkdir "$WORK/release"
node "$TESTS_DIR/fake-blossom.js" --dir "$WORK/fake" --static "$WORK/release" > "$WORK/fake.log" 2>&1 &
FAKE_PID=$!
i=0
while [ ! -s "$WORK/fake/ports.json" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -s "$WORK/fake/ports.json" ]; then echo 'The stand-in server did not start:'; cat "$WORK/fake.log"; exit 1; fi
PORT=$(LC_ALL=C awk -f "$KIT_ROOT/lib/json.awk" < "$WORK/fake/ports.json" | awk -F '\t' '$1 == "https" { print $2 }')
BASE="https://127.0.0.1:$PORT/releases/kit-v9.9.9"
export CURL_CA_BUNDLE="$WORK/fake/cert.pem"

# ---------------------------------------------------------------------------
describe 'make-kit-release.sh'
REL=$WORK/release/kit-v9.9.9
out=$(bash "$MAKE" --out "$REL" --source "$SRC" --base-url "$BASE" 2>&1); code=$?
is "$code" 0 'makes a release from a folder'
for f in blossom-farm-kit-9.9.9.zip SHA256SUMS bootstrap.sh bootstrap.ps1 bootstrap-hashes.json; do ok test -s "$REL/$f"; done
is "$(cat "$REL/SHA256SUMS")" "$(sha256_of "$REL/blossom-farm-kit-9.9.9.zip")  blossom-farm-kit-9.9.9.zip" 'SHA256SUMS names the archive'
matches "$(cat "$REL/bootstrap.sh")" "^KIT_SUMS_SHA256='$(sha256_of "$REL/SHA256SUMS")'\$" 'bootstrap.sh carries the SHA-256 of SHA256SUMS'
matches "$(cat "$REL/bootstrap.ps1")" "^\\\$KitSumsSha256 = '$(sha256_of "$REL/SHA256SUMS")'" 'so does bootstrap.ps1'
matches "$(cat "$REL/bootstrap.sh")" "^KIT_TAG='kit-v9.9.9'\$" 'and the tag'
matches "$(cat "$REL/bootstrap-hashes.json")" "\"bootstrapShSha256\": \"$(sha256_of "$REL/bootstrap.sh")\"" 'bootstrap-hashes.json has the SHA-256 of bootstrap.sh'
matches "$(cat "$REL/bootstrap-hashes.json")" "\"bootstrapPs1Sha256\": \"$(sha256_of "$REL/bootstrap.ps1")\"" 'and of bootstrap.ps1'
not_ok grep -q '@KIT_' "$REL/bootstrap.sh" "$REL/bootstrap.ps1"
out=$(bash "$MAKE" --out "$WORK/other" --source "$SRC" --tag kit-v1.2.3 2>&1); code=$?
is "$code" 1 'refuses a tag that does not match versions.json'
out=$(bash "$MAKE" --out "$WORK/other2" --source "$SRC" --base-url "http://127.0.0.1:$PORT/releases/kit-v9.9.9" 2>&1); code=$?
is "$code" 1 'refuses a download address that is not https'
out=$(bash "$MAKE" --out "$REL" --source "$SRC" --base-url "$BASE" 2>&1); code=$?
is "$code" 1 'refuses to write into a folder that is not empty'

# ---------------------------------------------------------------------------
describe 'bootstrap.sh'
BOOT=$WORK/blossom-bootstrap.sh
cp "$REL/bootstrap.sh" "$BOOT"
DEST=$WORK/opt/blossom-farm-kit
out=$(bash "$BOOT" --dest "$DEST" --app-origin https://app.blossom.example --pairing-code K7QM-2XVD-9HTR-4BWN-6CPA --domain 'agency.io' --with-appium 2>&1); code=$?
is "$code" 0 'downloads, verifies, unpacks and starts the installer'
matches "$out" 'SHA-256 verified' 'says that the checksum was verified'
matches "$out" 'the stand-in installer ran' 'the installer of the kit ran'
ok test -f "$DEST/install.sh"
ok test -f "$DEST/versions.json"
is "$(tr '\n' ' ' < "$DEST/called-with.txt")" '7 --app-origin https://app.blossom.example --pairing-code K7QM-2XVD-9HTR-4BWN-6CPA --domain agency.io --with-appium ' 'with every option it was given, and not --dest'
is "$(find "$WORK/opt" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 1 'nothing else is left behind'

echo 'kept from the first run' > "$DEST/marker.txt"
out=$(bash "$BOOT" --dest "$DEST" 2>&1); code=$?
is "$code" 0 'a second run replaces the kit'
not_ok test -f "$DEST/marker.txt"
is "$(cat "$DEST.previous/marker.txt" 2> /dev/null)" 'kept from the first run' 'and keeps the earlier one as .previous'
is "$(head -n 1 "$DEST/called-with.txt")" 0 'no options: none are handed on'

describe 'bootstrap.sh: a download that was changed'
cp "$REL/blossom-farm-kit-9.9.9.zip" "$WORK/good.zip"
echo 'echo evil' >> "$SRC/install.sh"
(cd "$WORK" && rm -rf evil && mkdir evil && cp -R "$SRC" evil/blossom-farm-kit-9.9.9 && cd evil && zip -q -r -X "$REL/blossom-farm-kit-9.9.9.zip" blossom-farm-kit-9.9.9)
DEST2=$WORK/opt2/blossom-farm-kit
out=$(bash "$BOOT" --dest "$DEST2" 2>&1); code=$?
is "$code" 1 'an archive with another SHA-256 is refused'
matches "$out" 'SHA-256 is wrong' 'with the reason'
not_ok test -e "$DEST2"
is "$(find "$WORK/opt2" -mindepth 1 2> /dev/null | wc -l | tr -d ' ')" 0 'nothing was unpacked or left behind'
# the attacker changes SHA256SUMS to match the changed archive
printf '%s  blossom-farm-kit-9.9.9.zip\n' "$(sha256_of "$REL/blossom-farm-kit-9.9.9.zip")" > "$REL/SHA256SUMS"
out=$(bash "$BOOT" --dest "$DEST2" 2>&1); code=$?
is "$code" 1 'a changed SHA256SUMS is refused as well'
matches "$out" 'list of checksums.*is not the one this file expects' 'with the reason'
not_ok test -e "$DEST2"
cp "$WORK/good.zip" "$REL/blossom-farm-kit-9.9.9.zip"
printf '%s  blossom-farm-kit-9.9.9.zip\n' "$(sha256_of "$WORK/good.zip")" > "$REL/SHA256SUMS"
out=$(bash "$BOOT" --dest "$DEST2" 2>&1); code=$?
is "$code" 0 'the unchanged release works again'

describe 'bootstrap.sh: the connection'
out=$(env -u CURL_CA_BUNDLE bash "$BOOT" --dest "$WORK/opt3/kit" 2>&1); code=$?
is "$code" 1 'a certificate that cannot be verified stops it'
not_ok test -e "$WORK/opt3/kit"
sed -e "s|^KIT_BASE_URL='https://|KIT_BASE_URL='http://|" "$BOOT" > "$WORK/plain.sh"
out=$(bash "$WORK/plain.sh" --dest "$WORK/opt4/kit" 2>&1); code=$?
is "$code" 1 'a download address that is not https stops it'
matches "$out" 'not https' 'with the reason'
rm -f "$REL/SHA256SUMS"
out=$(bash "$BOOT" --dest "$WORK/opt5/kit" 2>&1); code=$?
is "$code" 1 'a file that is missing from the release stops it'
matches "$out" 'HTTP 404' 'with the status'

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
    printf 'bash %s: all %d bootstrap tests passed.\n' "$BASH_VERSION" "$PASSED"
    exit 0
fi
printf 'bash %s: %d of %d bootstrap tests FAILED.\n' "$BASH_VERSION" "$FAILED" $((PASSED + FAILED))
exit 1
