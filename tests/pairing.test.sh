#!/bin/bash
# Tests for the pairing client of lib/farmkit.sh (the mirror of
# tests/Pairing.Tests.ps1), against tests/fake-blossom.js: a stand-in for
# Blossom CRM that serves the pairing API over https with a certificate made
# for the run.
#
#   bash tests/pairing.test.sh
#
# Plain bash, no test framework. Needs node, curl and openssl (without them
# the tests against the stand-in are skipped, unless FARMKIT_REQUIRE_STAND_IN
# is set, as tools/check.sh --require-all does); nothing here needs a Mac or
# root, and nothing leaves this computer. Exit status 0 when every test passed.

# The test data is single-quoted on purpose, and one function of the library
# is replaced by a stand-in further down.
# shellcheck disable=SC2016,SC2329

set -u
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT_ROOT=$(dirname "$TESTS_DIR")
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"

PASSED=0
FAILED=0
GROUP=''
WORK=$(mktemp -d "${TMPDIR:-/tmp}/farmkit-pairing.XXXXXX") || exit 1
FAKE_PID=''
cleanup() {
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2> /dev/null
    farm_http_cleanup
    rm -rf "$WORK"
}
trap cleanup EXIT

describe() { GROUP=$1; }
pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf 'FAILED  %s: %s\n' "$GROUP" "$1"; }
is() {
    # is <got> <want> <what>
    if [ "$1" = "$2" ]; then pass; else fail "$3"; printf '          got:  [%s]\n          want: [%s]\n' "$1" "$2"; fi
}
ok() { if "$@"; then pass; else fail "expected success: $*"; fi; }
not_ok() { if "$@"; then fail "expected failure: $*"; else pass; fi; }
empty() { if [ -z "$1" ]; then pass; else fail "$2 (got: $1)"; fi; }
not_empty() { if [ -n "$1" ]; then pass; else fail "$2"; fi; }
matches() {
    # matches <text> <extended regular expression> <what>
    if printf '%s\n' "$1" | LC_ALL=C grep -Eq -- "$2"; then pass; else fail "$3"; printf '          text: [%s]\n' "$1"; fi
}
not_matches() { if printf '%s\n' "$1" | LC_ALL=C grep -Eq -- "$2"; then fail "$3"; else pass; fi; }

# ---------------------------------------------------------------------------
describe 'normalize_pairing_code, test_pairing_code'
is "$(normalize_pairing_code 'k7qm-2xvd-9htr-4bwn-6cpa')" 'K7QM2XVD9HTR4BWN6CPA' 'upper case, no hyphens'
is "$(normalize_pairing_code ' K7QM 2XVD 9HTR 4BWN 6CPA ')" 'K7QM2XVD9HTR4BWN6CPA' 'no spaces'
is "$(normalize_pairing_code 'OIL0-0000-0000-0000-0000')" '01100000000000000000' 'O is 0, I and L are 1'
empty "$(test_pairing_code 'K7QM-2XVD-9HTR-4BWN-6CPA')" 'accepts a code as Blossom shows it'
empty "$(test_pairing_code 'k7qm2xvd9htr4bwn6cpa')" 'accepts it without hyphens and in lower case'
for c in '' 'K7QM-2XVD-9HTR' 'K7QM-2XVD-9HTR-4BWN-6CPA-AAAA' 'K7QM-2XVD-9HTR-4BWN-6CP!' 'U7QM-2XVD-9HTR-4BWN-6CPA' 'K7QM-2XVD-9HTR-4BWN-6CP$(id)'; do
    not_empty "$(test_pairing_code "$c")" "refuses [$c]"
done
# 20 characters of a 32-letter alphabet, 5 bits each: 100 bits
sample=$(normalize_pairing_code 'K7QM-2XVD-9HTR-4BWN-6CPA')
is $((${#sample} * 5)) 100 'a code carries 100 bits'

# ---------------------------------------------------------------------------
describe 'normalize_app_origin, test_app_origin'
is "$(normalize_app_origin ' HTTPS://App.Example.org/ ')" 'https://app.example.org' 'lower case, no slash at the end'
for o in 'https://app.blossom.example' 'https://app.blossom.example:8443' 'https://127.0.0.1:4443' 'HTTPS://App.Blossom.Example/'; do
    empty "$(test_app_origin "$o")" "accepts [$o]"
done
for o in '' 'http://app.blossom.example' 'app.blossom.example' 'ftp://app.blossom.example' 'https://' 'https://app.blossom.example/path' \
    'https://app.blossom.example?x=1' 'https://user:pw@app.blossom.example' 'https://app.blossom.example#x' 'https://app.blossom.example:port' \
    'https://app.blossom.example:0' 'https://app.blossom.example:70000' 'https://app..example' 'https://-app.example' 'https://[::1]:443' \
    'https://app.blossom.example evil' 'https://app.blossom.example\@evil.example'; do
    not_empty "$(test_app_origin "$o")" "refuses [$o]"
done
matches "$(test_app_origin 'http://app.blossom.example')" 'https://' 'says that http is refused'

# ---------------------------------------------------------------------------
describe 'farm tokens'
t=$(new_farm_token)
ok test_farm_token "$t"
matches "$t" '^bft_[A-Za-z0-9_-]{43}$' 'bft_ and 256 random bits'
for bad in '' 'bft_' 'bft_short' "x${t#b}" "$t=" "bft_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4)"; do
    not_ok test_farm_token "$bad"
done
is "$(i=0; while [ "$i" -lt 50 ]; do new_farm_token; echo; i=$((i + 1)); done | sort -u | wc -l | tr -d ' ')" 50 'never the same token twice'

# ---------------------------------------------------------------------------
describe 'the default host names'
is "$(get_default_farm_hostnames 'YourDomain.com' | tr '\n' ' ')" 'farm-hub.yourdomain.com farm-provider.yourdomain.com farm-restart.yourdomain.com ' 'three names under the domain'
is "$(normalize_farm_domain ' https://Agency.co.uk/ ')" 'agency.co.uk' 'a pasted address becomes a domain'
empty "$(test_farm_domain 'agency.co.uk')" 'accepts a domain'
for d in '' 'com' 'example.com' 'my domain.com' 'agency.local' '192.168.1.1'; do
    not_empty "$(test_farm_domain "$d")" "refuses [$d]"
done
names=$(get_default_farm_hostnames agency.io)
# shellcheck disable=SC2086
empty "$(test_farm_hostname_set $names)" 'the proposed names pass the host name rules'

# ---------------------------------------------------------------------------
describe 'texts'
is "$(clean_computer_label 'Farm PC #1 (office)')" 'Farm PC 1 office' 'a computer name is reduced to plain characters'
is "$(clean_computer_label '')" 'farm computer' 'and is never empty'
is "$(clean_remote_text "$(printf 'one\ntwo\033[31m red\001')")" 'one two[31m red' 'a text from the network loses its control characters'
long=$(clean_remote_text "$(head -c 400 /dev/zero | tr '\0' x)")
is "${#long}" 300 'and is cut at 300 characters'
matches "$(get_pairing_message pairing_code_expired '')" '30 minutes' 'an expired code is explained'
matches "$(get_pairing_message pairing_code_used '')" 'another computer' 'a used code is explained'
is "$(get_pairing_message something_new 'Text from Blossom.')" 'Text from Blossom.' 'an unknown code shows the text Blossom sent'

# ---------------------------------------------------------------------------
# From here on: against the stand-in for Blossom.
for tool in node curl openssl; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        if [ -n "${FARMKIT_REQUIRE_STAND_IN:-}" ]; then echo "FAILED: $tool is not installed, and FARMKIT_REQUIRE_STAND_IN is set."; exit 1; fi
        echo "SKIPPED the tests against the stand-in for Blossom: $tool is not installed."
        [ "$FAILED" -eq 0 ] && { printf 'bash %s: %d tests passed, the rest skipped.\n' "$BASH_VERSION" "$PASSED"; exit 0; }
        exit 1
    fi
done

node "$TESTS_DIR/fake-blossom.js" --dir "$WORK/fake" > "$WORK/fake.log" 2>&1 &
FAKE_PID=$!
i=0
while [ ! -s "$WORK/fake/ports.json" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -s "$WORK/fake/ports.json" ]; then echo 'The stand-in for Blossom did not start:'; cat "$WORK/fake.log"; exit 1; fi
HTTPS_PORT=$(json_file_get "$WORK/fake/ports.json" https)
HTTP_PORT=$(json_file_get "$WORK/fake/ports.json" http)
ORIGIN="https://127.0.0.1:$HTTPS_PORT"
CONTROL="http://127.0.0.1:$HTTP_PORT"
export CURL_CA_BUNDLE="$WORK/fake/cert.pem"
FK_APP_RETRY_DELAY=0
FK_APP_TRIES=3

NOTHING='{}'
ctl() {
    # ctl <switch> [json]   one of the test switches of the stand-in
    curl -q -sS --noproxy '*' -X POST -H 'Content-Type: application/json' --data-binary "${2:-$NOTHING}" "$CONTROL/__test/$1"
}
new_code() { json_get "$(ctl new-code "${1:-$NOTHING}")" code; }
mine() {
    # The JSON that points a switch at the pairing of the farm in use: mine ['"more":"fields"']
    read_farm_pairing
    if [ "$FARM_IS_PAIRED" = 1 ]; then printf '{"token":"%s"%s}' "$PAIR_TOKEN" "${1:+,$1}"; else printf '{%s}' "${1:-}"; fi
}
fake() { json_get "$(ctl state "${2:-$(mine)}")" "$1"; }
hits() { json_values "$(ctl state)" 'hits.*.path' | wc -l | tr -d ' '; }

# The library locks its files to root; the tests are not root.
protect_farm_path() { chmod 600 "$1" 2> /dev/null; return 0; }
use_farm() {
    get_farm_paths "$WORK/$1"
    mkdir -p "$FARM_CONFIG"
    printf '{"kit":"9.9.9","gads":{"version":"v6.0.0"},"gadsDrag":{"version":"v6.0.0-drag.1"}}' > "$FARM_CONFIG/versions.json"
}
send_site() {
    # send_site [hub password] [restart secret] [hub host]
    pair_send_site "https://${3:-farm-hub.agency.io}" 'https://farm-provider.agency.io' Provider1 blossom "${1:-}" 'https://farm-restart.agency.io' "${2:-}"
}

# ---------------------------------------------------------------------------
describe 'claim'
use_farm farm1
CODE=$(new_code '{"workspace":"Agency One"}')
matches "$CODE" '^[0-9A-Z]{4}(-[0-9A-Z]{4}){4}$' 'the stand-in hands out a code in five groups'
pair_claim "$ORIGIN" "$CODE" > "$WORK/out" 2>&1; code=$?
out=$(cat "$WORK/out")
is "$code" 0 'a fresh code is accepted'
is "$APP_KIND" ok 'and the kind says so'
ok test -f "$FARM_PAIRING"
not_ok test -f "$FARM_PAIRING_NEW"
read_farm_pairing
is "$FARM_IS_PAIRED" 1 'this computer holds a pairing now'
is "$PAIR_ORIGIN" "$ORIGIN" 'for the address the code came with'
is "$PAIR_WORKSPACE" 'Agency One' 'and knows the workspace by name'
ok test_farm_token "$PAIR_TOKEN"
TOKEN1=$PAIR_TOKEN
is "$(fake pairing.state)" installing 'Blossom has the computer as "installing"'
is "$(fake pairing.computer.platform)" macos 'with its platform'
is "$(fake pairing.computer.kit_version)" 9.9.9 'and its kit version'
state=$(ctl state "$(mine)")
matches "$(json_get "$state" hits.0.userAgent)" '^blossom-farm-kit/9\.9\.9$' 'the kit names itself'
is "$(json_get "$state" hits.0.secure)" true 'over https'
not_matches "$(cat "$FARM_PAIRING")" "${CODE//-/}" 'the pairing code itself is not kept on disk'
not_matches "$out" 'bft_' 'and nothing printed shows the token'

before=$(hits)
pair_claim "$ORIGIN" "$CODE"; code=$?
is "$code" 0 'the same command again is fine'
is "$(hits)" "$before" 'and asks Blossom nothing'
read_farm_pairing
is "$PAIR_TOKEN" "$TOKEN1" 'the token stays'

describe 'claim: a code cannot be used twice'
use_farm farm2
pair_claim "$ORIGIN" "$CODE"; code=$?
is "$code" 1 'a second computer is refused'
is "$APP_CODE" pairing_code_used 'because the code was used'
matches "$APP_MESSAGE" 'another computer' 'and the message says what that means'
not_ok test -f "$FARM_PAIRING"
not_ok test -f "$FARM_PAIRING_NEW"

describe 'claim: expired, unknown, cancelled'
CODE2=$(new_code '{"ttlSeconds":0}')
sleep 0.2
pair_claim "$ORIGIN" "$CODE2"; code=$?
is "$code$APP_CODE" 1pairing_code_expired 'an expired code is refused'
not_ok test -f "$FARM_PAIRING_NEW"
pair_claim "$ORIGIN" 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ'; code=$?
is "$code$APP_CODE" 1pairing_code_unknown 'an unknown code is refused'
CODE3=$(new_code); ctl cancel-code "{\"code\":\"$CODE3\"}" > /dev/null
pair_claim "$ORIGIN" "$CODE3"; code=$?
is "$code$APP_CODE" 1pairing_code_unknown 'a cancelled code looks like an unknown one'
before=$(hits)
pair_claim "$ORIGIN" 'not-a-code'; code=$?
is "$code$APP_KIND" 1origin 'a text that is no code is refused here'
is "$(hits)" "$before" 'without asking Blossom'

describe 'claim: the answer was lost on the way'
use_farm farm3
CODE4=$(new_code)
ctl fail-next '{"count":3,"status":503}' > /dev/null
pair_claim "$ORIGIN" "$CODE4"; code=$?
is "$code$APP_KIND" 1network 'Blossom is not available: the claim fails'
ok test -f "$FARM_PAIRING_NEW"
is "$(file_mode "$FARM_PAIRING_NEW")" 600 'the token made for it is kept, for root only'
PENDING=$(json_file_get "$FARM_PAIRING_NEW" farmToken)
# The claim reaches Blossom, but its answer never reaches the computer:
curl -q -sS --noproxy '*' -o /dev/null -X POST -H 'Content-Type: application/json' \
    --data-binary "{\"protocol\":1,\"pairing_code\":\"$CODE4\",\"farm_token\":\"$PENDING\",\"computer\":{\"label\":\"x\",\"platform\":\"macos\"}}" "$ORIGIN/api/farm/pair/claim"
pair_claim "$ORIGIN" "$CODE4"; code=$?
is "$code" 0 'the same command again completes the same claim'
read_farm_pairing
is "$PAIR_TOKEN" "$PENDING" 'with the token that was made the first time'
not_ok test -f "$FARM_PAIRING_NEW"

# ---------------------------------------------------------------------------
describe 'wrong address: nothing is sent'
use_farm farm4
CODE5=$(new_code)
ctl reset-hits > /dev/null
pair_claim "http://127.0.0.1:$HTTP_PORT" "$CODE5"; code=$?
is "$code$APP_KIND" 1origin 'an http address is refused'
matches "$APP_MESSAGE" 'https://' 'with the reason'
pair_claim "$ORIGIN/api" "$CODE5"; code=$?
is "$code$APP_KIND" 1origin 'an address with a path is refused'
invoke_blossom "http://127.0.0.1:$HTTP_PORT" GET /api/farm/pair/status --bearer "$TOKEN1"; code=$?
is "$code$APP_KIND" 1origin 'the token is not sent over http either'
is "$(fake plainApiHits)" 0 'nothing arrived on the plain port'
is "$(hits)" 0 'and nothing arrived at all'
printf '{"appOrigin":"http://127.0.0.1:%s","farmToken":"%s"}' "$HTTP_PORT" "$TOKEN1" > "$FARM_PAIRING"
read_farm_pairing
is "$FARM_IS_PAIRED" 0 'a pairing file with an http address is not used'
rm -f "$FARM_PAIRING"

describe 'a certificate that cannot be verified'
use_farm farm1
ctl reset-hits > /dev/null
(
    unset CURL_CA_BUNDLE
    send_site 'hub-password-1' 'restart-secret-1'
    echo "$?|$APP_KIND|$APP_MESSAGE"
) > "$WORK/tls.out" 2>&1
matches "$(cat "$WORK/tls.out")" '^1\|tls\|' 'the call fails as a certificate problem'
matches "$(cat "$WORK/tls.out")" 'could not be verified' 'and says so'
is "$(hits)" 0 'no request, and so no password, reached the other side'

describe 'a redirect is refused, not followed'
ctl redirect '{"on":true}' > /dev/null
send_site 'hub-password-1' 'restart-secret-1'; code=$?
is "$code$APP_KIND" 1redirect 'the call fails as a redirect'
matches "$APP_MESSAGE" 'not followed' 'and says so'
is "$(fake redirectHits)" 0 'nothing was sent to where the redirect points'
pair_get_status; code=$?
is "$code$APP_KIND" 1redirect 'the same for a read'
ctl redirect '{"on":false}' > /dev/null

describe 'an address that is not Blossom'
ctl fail-next '{"count":1,"status":200,"html":true}' > /dev/null
pair_get_status 1; code=$?
is "$code$APP_KIND" 1not_blossom 'a web page instead of the API is recognised'
ctl fail-next '{"count":1,"status":404,"html":true}' > /dev/null
pair_get_status 1; code=$?
is "$code$APP_KIND" 1not_blossom 'so is a refusal that is not from the API'

# ---------------------------------------------------------------------------
describe 'sending the farm'
send_site '' 'restart-secret-1'; code=$?
is "$code$APP_CODE" 1credentials_required 'the first time, the hub password is required'
send_site 'hub-password-1' ''; code=$?
is "$code$APP_CODE" 1credentials_required 'and the restart secret'
read_farm_pairing
empty "$PAIR_SITE_SENT_AT" 'nothing is recorded as sent yet'
pair_send_site 'http://farm-hub.agency.io' 'https://farm-provider.agency.io' Provider1 blossom pw 'https://farm-restart.agency.io' s; code=$?
is "$code$APP_CODE" 1site_address_refused 'Blossom refuses an address it would not call'
ctl set-check '{"ok":true,"devices":3}' > /dev/null
send_site 'hub-password-1' 'restart-secret-1' > "$WORK/out" 2>&1; code=$?
out=$(cat "$WORK/out")
is "$code" 0 'the complete description is accepted'
is "$PAIR_STATE" checking 'Blossom starts checking the farm'
is "$PAIR_NEEDS_CONFIRMATION" true 'and an admin has to confirm it'
read_farm_pairing
not_empty "$PAIR_SITE_SENT_AT" 'the pairing file records that the farm was sent'
state=$(ctl state "$(mine)")
is "$(json_get "$state" pairing.site.hub_url)" 'https://farm-hub.agency.io' 'Blossom has the hub address'
is "$(json_get "$state" pairing.site.provider_nickname)" Provider1 'the nickname'
is "$(json_get "$state" pairing.secrets.hub_password)" 'hub-password-1' 'the hub password'
is "$(json_get "$state" pairing.secrets.restart_secret)" 'restart-secret-1' 'and the restart secret'
is "$(json_get "$state" pairing.confirmed)" false 'the site is not active before the confirmation'
not_matches "$out" 'hub-password-1|restart-secret-1|bft_' 'nothing secret was printed'

describe 'status and the confirmation'
pair_get_status; is "$PAIR_STATE" checking 'first: checking'
pair_get_status; is "$PAIR_STATE" awaiting_confirmation 'then: waiting for the admin'
is "$PAIR_CHECK_OK$PAIR_DEVICES" true3 'with what Blossom found'
is "$(describe_pairing_check)" 'Blossom sees your farm: 3 phones.' 'said in one sentence'
out=$(pair_wait 0); code=$?
is "$code" 2 'waiting ends without an error while nobody confirmed'
matches "$out" 'confirm in Blossom' 'and asks for the confirmation'
(sleep 2; ctl confirm "$(mine '"label":"Milan"')" > /dev/null) &
confirmer=$!
out=$(pair_wait 30); code=$?
wait "$confirmer"
is "$code" 0 'after the confirmation the wait ends well'
matches "$out" 'Blossom sees your farm: 3 phones\.' 'with the sentence the installer ends on'
matches "$out" 'Milan' 'and the name the site got in Blossom'
not_matches "$out" 'bft_' 'the token is never printed'
ctl set-check '{"ok":false,"devices":0,"failed_step":"signin","detail":"The hub refused the user name or password."}' > /dev/null
ctl recheck "$(mine)" > /dev/null
pair_get_status
matches "$(describe_pairing_check)" 'could not use the farm yet \(step: signin\): The hub refused' 'a failed check is described'
ctl set-check '{"ok":true,"devices":1}' > /dev/null
ctl recheck "$(mine)" > /dev/null; pair_get_status
is "$(describe_pairing_check)" 'Blossom sees your farm: 1 phone.' 'one phone is not "1 phones"'

# ---------------------------------------------------------------------------
describe 'new credentials through the farm token'
send_site 'hub-password-2' ''; code=$?
is "$code" 0 'a new hub password alone is accepted'
is "$PAIR_NEEDS_CONFIRMATION" false 'without a new confirmation: the addresses are the same'
state=$(ctl state "$(mine)")
is "$(json_get "$state" pairing.secrets.hub_password)" 'hub-password-2' 'Blossom has the new password'
is "$(json_get "$state" pairing.secrets.restart_secret)" 'restart-secret-1' 'and kept the restart secret'
is "$(json_get "$state" pairing.confirmed)" true 'the site stays confirmed'
send_site '' 'restart-secret-2'; code=$?
is "$code$(fake pairing.secrets.restart_secret)" '0restart-secret-2' 'the same for a new restart secret'
send_site '' ''; code=$?
is "$code" 0 'sending nothing new changes nothing'
is "$(json_get "$APP_TEXT" site_changed)" false 'and Blossom says so'

describe 'new addresses need a new confirmation'
send_site '' '' 'farm-hub.other.io'; code=$?
is "$code$APP_CODE" 1credentials_required 'a stored password is not reused for another hub address'
is "$(fake pairing.site.hub_url)" 'https://farm-hub.agency.io' 'and nothing changed'
send_site 'hub-password-3' '' 'farm-hub.other.io'; code=$?
is "$code" 0 'with its password the new address is accepted'
is "$PAIR_NEEDS_CONFIRMATION" true 'but an admin has to confirm it again'
state=$(ctl state "$(mine)")
is "$(json_get "$state" pairing.awaiting)" true 'the new address waits for it'
is "$(json_get "$state" pairing.confirmed)$(json_get "$state" pairing.confirmedSite.hub_url)" 'truehttps://farm-hub.agency.io' 'and until then Blossom goes on using the confirmed one: the token cannot take the site out of service'
pair_get_status; pair_get_status
is "$PAIR_STATE$PAIR_NEEDS_CONFIRMATION" awaiting_confirmationtrue 'the status says that a confirmation is awaited'
ctl reject "$(mine)" > /dev/null
pair_get_status; code=$?
is "$code$PAIR_STATE" 0active 'declined new addresses leave the site and the pairing as they were'

describe 'the versions after an update'
printf '{"kit":"9.9.10","gads":{"version":"v6.0.1"},"gadsDrag":{"version":"v6.0.1-drag.1"}}' > "$FARM_CONFIG/versions.json"
pair_send_computer; code=$?
state=$(ctl state "$(mine)")
is "$code$(json_get "$state" pairing.computer.kit_version)" '09.9.10' 'Blossom learns the new kit version'
is "$(json_get "$state" pairing.computer.gads_version)" 'v6.0.1' 'and the GADS version'
is "$(json_get "$state" pairing.site.hub_url)" 'https://farm-hub.agency.io' 'the site itself is untouched'

# ---------------------------------------------------------------------------
describe 'retries'
ctl reset-hits > /dev/null
ctl fail-next '{"count":2,"status":503}' > /dev/null
pair_get_status 3; code=$?
is "$code" 0 'a call that fails twice with 503 succeeds at the third try'
is "$(hits)" 3 'after exactly three requests'
ctl reset-hits > /dev/null
ctl fail-next '{"count":1,"status":429,"code":"rate_limited","retryAfter":1}' > /dev/null
start=$(date +%s)
pair_get_status 2; code=$?
is "$code" 0 'a 429 is retried'
ok test $(($(date +%s) - start)) -ge 1
ctl fail-next '{"count":5,"status":503}' > /dev/null
pair_get_status 2; code=$?
is "$code$APP_KIND" 1network 'and after the last try the call fails as "not available"'
ctl reset-hits > /dev/null
ctl fail-next '{"count":1,"status":400,"code":"bad_request","error":"No."}' > /dev/null
pair_get_status 3; code=$?
is "$code$(hits)" 11 'a refusal is not retried'

describe 'too many wrong codes'
use_farm farm5
ctl limits '{"claimFailureLimit":2}' > /dev/null
FK_APP_TRIES=1
pair_claim "$ORIGIN" 'AAAA-AAAA-AAAA-AAAA-AAAA'; pair_claim "$ORIGIN" 'BBBB-BBBB-BBBB-BBBB-BBBB'
pair_claim "$ORIGIN" 'CCCC-CCCC-CCCC-CCCC-CCCC'; code=$?
is "$code$APP_STATUS" 1429 'the third wrong code in a row is not even looked at'
FK_APP_TRIES=3
ctl limits '{"claimFailureLimit":10}' > /dev/null

# ---------------------------------------------------------------------------
describe 'declined, expired, revoked'
use_farm farm6
pair_claim "$ORIGIN" "$(new_code)"; send_site pw secret > /dev/null
ctl reject "$(mine)" > /dev/null
out=$(pair_wait 5); code=$?
is "$code" 1 'a declined pairing ends the wait'
matches "$out" 'declined in Blossom' 'and says so'
send_site pw secret; code=$?
is "$code$APP_CODE" 1pairing_rejected 'and takes nothing more'
use_farm farm7
pair_claim "$ORIGIN" "$(new_code)"
ctl expire-pairing "$(mine)" > /dev/null
pair_get_status; is "$PAIR_STATE" expired 'a pairing nobody confirmed in time is expired'
use_farm farm1
ctl revoke "{\"token\":\"$TOKEN1\"}" > /dev/null
pair_get_status; code=$?
is "$code$APP_KIND$APP_CODE" 1refusedfarm_token_revoked 'a token revoked in Blossom is refused'
send_site pw secret; code=$?
is "$code$APP_STATUS" 1401 'for writing as well'
out=$(pair_wait 5); code=$?
is "$code" 1 'the wait ends'
matches "$out" 'no longer accepts this computer' 'and says why'

describe 'unpair'
pair_unpair; code=$?
is "$code" 0 'unpairing a computer Blossom already dropped works'
not_ok test -f "$FARM_PAIRING"
use_farm farm8
pair_claim "$ORIGIN" "$(new_code)"
read_farm_pairing; TOKEN8=$PAIR_TOKEN
pair_unpair; code=$?
is "$code" 0 'unpairing tells Blossom'
is "$(fake pairing.unpairedByComputer "{\"token\":\"$TOKEN8\"}")" true 'and Blossom took note'
not_ok test -f "$FARM_PAIRING"
read_farm_pairing; is "$FARM_IS_PAIRED" 0 'the computer holds no pairing any more'
pair_unpair; code=$?
is "$code" 0 'unpairing twice is fine'
# Blossom cannot be reached: the pairing file stays, so that it can be tried again
printf '{"appOrigin":"https://127.0.0.1:1","farmToken":"%s"}' "$TOKEN8" > "$FARM_PAIRING"
FK_APP_TRIES=1
pair_unpair; code=$?
is "$code" 1 'when Blossom cannot be told, it says so'
ok test -f "$FARM_PAIRING"
FK_APP_TRIES=3

describe 'a new code of the same workspace replaces an earlier pairing'
use_farm farm9
ASKED=0
read_typed_word() { ASKED=$((ASKED + 1)); return 1; }   # nobody is at the keyboard
pair_claim "$ORIGIN" "$(new_code)"; read_farm_pairing; OLD=$PAIR_TOKEN
matches "$PAIR_WORKSPACE_ID" '^[0-9a-f-]{36}$' 'the identifier of the workspace is kept with the pairing'
pair_claim "$ORIGIN" "$(new_code)"; code=$?
read_farm_pairing
is "$code$ASKED" 00 'the new code wins, and nothing is asked: it is the same workspace'
ok test "$PAIR_TOKEN" != "$OLD"
is "$(fake pairing.revoked "{\"token\":\"$OLD\"}")" revoked 'and the token of the earlier pairing was given up'
pair_claim "$ORIGIN" 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ'; code=$?
KEPT=$PAIR_TOKEN
read_farm_pairing
is "$code$FARM_IS_PAIRED" 11 'a code that fails leaves the pairing as it was'
is "$PAIR_TOKEN" "$KEPT" 'with its token'

describe 'a command made in another workspace does not move the farm by itself'
# A genuine Blossom, and a workspace that gave itself the same name: only its
# identifier tells it from the one this computer is paired with.
ok test_same_workspace https://a.example id-1 https://a.example id-1
not_ok test_same_workspace https://a.example id-1 https://a.example id-2
not_ok test_same_workspace https://a.example id-1 https://b.example id-1
not_ok test_same_workspace https://a.example '' https://a.example ''
is "$(clean_workspace_id '0B0E6C1E-AAAA-4BBB-8CCC-000000000001')" '0b0e6c1e-aaaa-4bbb-8ccc-000000000001' 'an identifier is kept in lower case'
empty "$(clean_workspace_id 'Agency "One"')" 'a name is not an identifier'
OTHER='{"workspace":"Test Agency","workspaceId":"11111111-2222-4333-8444-555555555555"}'
read_farm_pairing; MINE=$PAIR_TOKEN; MINE_ID=$PAIR_WORKSPACE_ID
ASKED=0
pair_claim "$ORIGIN" "$(new_code "$OTHER")" > "$WORK/out" 2>&1; code=$?
out=$(cat "$WORK/out")
is "$code$APP_KIND$ASKED" 1declined1 'without somebody at the keyboard the answer is no'
matches "$APP_MESSAGE" 'stays paired with' 'and the reason is said'
matches "$out" 'already paired with Blossom' 'the question names what is about to happen'
matches "$out" 'A workspace name proves nothing' 'and that the name is no proof'
read_farm_pairing
is "$PAIR_TOKEN$PAIR_WORKSPACE_ID" "$MINE$MINE_ID" 'the pairing is as it was'
pair_get_status; code=$?
is "$code" 0 'and Blossom still accepts it'
not_ok test -e "$FARM_PAIRING_NEW"
latest=$(ctl state)
is "$(json_get "$latest" pairing.workspaceId)$(json_get "$latest" pairing.revoked)" '11111111-2222-4333-8444-555555555555revoked' 'the claim made in the other workspace was given up again'
is "$(json_get "$latest" pairing.site)" null 'which never received an address or a secret'
read_typed_word() { ASKED=$((ASKED + 1)); REPLY_WORD='yes'; return 0; }
pair_claim "$ORIGIN" "$(new_code "$OTHER")" > /dev/null 2>&1; code=$?
read_farm_pairing
is "$code$APP_KIND$PAIR_TOKEN" "1declined$MINE" 'any answer but the word that is asked for is a no'
read_typed_word() { REPLY_WORD=' Replace '; return 0; }
pair_claim "$ORIGIN" "$(new_code "$OTHER")" > /dev/null 2>&1; code=$?
read_farm_pairing
is "$code$PAIR_WORKSPACE_ID" '011111111-2222-4333-8444-555555555555' 'the typed word moves the farm'
is "$(fake pairing.revoked "{\"token\":\"$MINE\"}")" revoked 'and only then is the earlier token given up'
empty "$PAIR_SITE_SENT_AT" 'the farm has not been sent to the new workspace yet'
# the option says yes in advance, for a run without a keyboard
read_typed_word() { ASKED=$((ASKED + 1)); return 1; }
ASKED=0; MINE=$PAIR_TOKEN
FK_REPLACE_PAIRING=1
pair_claim "$ORIGIN" "$(new_code)" > /dev/null 2>&1; code=$?
FK_REPLACE_PAIRING=0
read_farm_pairing
is "$code$ASKED" 00 '--replace-pairing answers the question in advance'
ok test "$PAIR_TOKEN" != "$MINE"
# another Blossom altogether: asked before anything is sent there
MINE=$PAIR_TOKEN
before=$(hits)
pair_claim 'https://127.0.0.1:1' "$(normalize_pairing_code K7QM-2XVD-9HTR-4BWN-6CPA)" > "$WORK/out" 2>&1; code=$?
read_farm_pairing
is "$code$APP_KIND$ASKED$PAIR_TOKEN" "1declined1$MINE" 'a command that names another Blossom is not followed without a yes'
matches "$(cat "$WORK/out")" 'https://127\.0\.0\.1:1' 'the other address is shown'
not_ok test -e "$FARM_PAIRING_NEW"
unset -f read_typed_word
. "$KIT_ROOT/lib/farmkit.sh"
protect_farm_path() { chmod 600 "$1" 2> /dev/null; return 0; }
FK_APP_RETRY_DELAY=0; FK_APP_TRIES=3
matches "$FK_PAIR_HELP" 'Only ever run a command you took from your own Blossom' 'the hint for a new command says whose command to run'

describe 'self-test: whose password is asked for'
use_farm farm10
is "$(default_self_test_user blossom)" blossom 'a computer that is not paired tests with the user whose password was shown'
pair_claim "$ORIGIN" "$(new_code)"
is "$(default_self_test_user blossom)" blossom 'paired, but the farm was never sent: still that user'
send_site 'hub-password-1' 'restart-secret-1' > /dev/null 2>&1
is "$(default_self_test_user blossom)" admin 'once Blossom has the password, nobody else does: the test asks for the administrator'
matches "$(cat "$KIT_ROOT/scripts/self-test.sh")" 'default_self_test_user' 'scripts/self-test.sh uses it'

# ---------------------------------------------------------------------------
describe 'the source'
src=$(cat "$KIT_ROOT/lib/farmkit.sh")
not_matches "$src" 'curl[^|]*(-u |--user |-d |--data|-H |-k |--insecure)' 'no credential is ever given to curl as an argument, and no check is switched off'
not_matches "$(cat "$KIT_ROOT/install.sh" "$KIT_ROOT"/scripts/*.sh "$KIT_ROOT/bootstrap.sh")" 'curl[^|]*(-k |--insecure|--location-trusted)' 'nor anywhere in the scripts'

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
    printf 'bash %s: all %d pairing tests passed.\n' "$BASH_VERSION" "$PASSED"
    exit 0
fi
printf 'bash %s: %d of %d pairing tests FAILED.\n' "$BASH_VERSION" "$FAILED" $((PASSED + FAILED))
exit 1
