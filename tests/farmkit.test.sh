#!/bin/bash
# Tests for the pure functions of lib/farmkit.sh (the mirror of
# tests/FarmKit.Tests.ps1) and for the small service scripts.
#
#   bash tests/farmkit.test.sh
#
# Plain bash, no test framework. Runs with the bash 3.2 of macOS and with
# newer ones, and on Linux: nothing here needs a Mac, root or a network.
# Exit status 0 when every test passed.

# The test data is single-quoted on purpose, and two functions of the library
# are replaced by stand-ins further down.
# shellcheck disable=SC2016,SC2026,SC2329

set -u
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT_ROOT=$(dirname "$TESTS_DIR")
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"

PASSED=0
FAILED=0
GROUP=''
WORK=$(mktemp -d "${TMPDIR:-/tmp}/farmkit-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

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
has_line() { if printf '%s\n' "$1" | grep -Fxq -- "$2"; then pass; else fail "missing line: $2"; fi; }
line_no() { printf '%s\n' "$1" | grep -Fxn -- "$2" | "${3:-head}" -n 1 | cut -d: -f1; }

# ---------------------------------------------------------------------------
describe 'new_random_secret'
matches "$(new_random_secret 32 hex)" '^[0-9a-f]{64}$' 'returns 64 hex characters for 32 bytes'
matches "$(new_random_secret 32 base64url)" '^[A-Za-z0-9_-]{43}$' 'returns URL-safe base64 without padding'
matches "$(new_random_secret)" '^[0-9a-f]{64}$' 'defaults to 32 bytes of hex'
all=$(i=0; while [ "$i" -lt 200 ]; do new_random_secret; echo; i=$((i + 1)); done | sort -u | wc -l | tr -d ' ')
is "$all" 200 'never returns the same value twice'
not_ok new_random_secret 8
not_ok new_random_secret 32 other
s=$(new_random_secret); ok test "${#s}" -ge 32

# ---------------------------------------------------------------------------
describe 'test_password_strength'
empty "$(test_password_strength 'Violet-Tram-93-harbour')" 'accepts a long mixed password'
for p in '' 'short1A!' 'password' 'Password12345!' 'MyAdminLogin-2026' 'alllowercaseletters' 'aaaaaaaaaaaaaaA1!' ' Violet-Tram-93-harbour' 'Violet-Tram-93-harbour ' 'farm-blossom-2026-xyz'; do
    not_empty "$(test_password_strength "$p")" "refuses [$p]"
done
not_empty "$(test_password_strength 'Violet-Tram-93-harbour' harbour)" 'refuses a password containing a forbidden word'
empty "$(test_password_strength 'Violet-Tram-93-harbour' xyz)" 'ignores forbidden words shorter than four characters'
not_empty "$(test_password_strength "Violet-Tram-93-$(printf '\001')harbour")" 'refuses control characters'
matches "$(test_password_strength 'short1A!')" 'at least 14 characters' 'names the length rule'
empty "$(test_password_strength 'a B"c\d$e`f!g*h?[i]9')" 'accepts quotes, backslashes and shell characters'

# ---------------------------------------------------------------------------
describe 'test_farm_hostname'
for n in 'farm-hub.yourdomain.com' 'farm-provider.agency.co.uk' 'a1.b2.io' '  farm-hub.yourdomain.com  '; do
    empty "$(test_farm_hostname "$n")" "accepts [$n]"
done
long_label=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4)
for n in '' 'https://farm-hub.yourdomain.com' 'farm-hub.yourdomain.com/path' 'farm-hub.yourdomain.com:10000' 'Farm-Hub.yourdomain.com' \
    'yourdomain.com' 'localhost' '192.168.1.10' 'farm.hub.local' 'farm.hub.internal' 'farm-hub.example.com' '-farm.yourdomain.com' \
    'farm_hub.yourdomain.com' 'farm hub.yourdomain.com' 'abc.cfargotunnel.com' 'farm..yourdomain.com' 'farm.yourdomain.com.' \
    '.farm.yourdomain.com' 'farm.yourdomain.123' "$long_label.yourdomain.com" 'farm*.yourdomain.com' 'farm.x.trycloudflare.com'; do
    not_empty "$(test_farm_hostname "$n")" "refuses [$n]"
done

# ---------------------------------------------------------------------------
describe 'test_farm_hostname_set'
empty "$(test_farm_hostname_set farm-hub.yourdomain.com farm-provider.yourdomain.com farm-restart.yourdomain.com)" 'accepts three different valid names'
not_empty "$(test_farm_hostname_set farm.yourdomain.com farm.yourdomain.com farm-restart.yourdomain.com)" 'refuses the same name twice'
matches "$(test_farm_hostname_set farm-hub.yourdomain.com localhost farm-restart.yourdomain.com)" 'Provider host name' 'names the field that is wrong'

# ---------------------------------------------------------------------------
describe 'test_provider_nickname'
empty "$(test_provider_nickname Provider1)" 'accepts Provider1'
for n in '' '1provider' 'my provider' 'a' 'prov/../x' 'prov"x' 'abcdefghijklmnopqrstuvwxyz1234567'; do
    not_empty "$(test_provider_nickname "$n")" "refuses [$n]"
done

# ---------------------------------------------------------------------------
describe 'test_public_ip_address'
for a in 104.16.0.1 8.8.8.8 2606:4700::1111 2a06:98c1:3120::3 '::ffff:8.8.8.8'; do ok test_public_ip_address "$a"; done
for a in 127.0.0.1 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 169.254.169.254 100.64.0.1 0.0.0.0 224.0.0.1 255.255.255.255 \
    192.0.2.1 198.18.0.1 198.51.100.7 203.0.113.9 ::1 :: fe80::1 'fe80::1%en0' fd00::1 fc00::1 ff02::1 2001:db8::1 ::ffff:192.168.1.1 \
    0:0:0:0:0:0:0:1 not-an-address '' 1.2.3 1.2.3.4.5 256.1.1.1 '*' '1:2:3:4:5:6:7:8:9' ':::1'; do
    not_ok test_public_ip_address "$a"
done
ok test_public_ip_address 172.32.0.1
ok test_public_ip_address 100.128.0.1

# ---------------------------------------------------------------------------
describe 'get_cloudflared_config_text'
yml=$(get_cloudflared_config_text 6FF42AE2-765D-4ADF-8112-31C55C1551EF /opt/farm/config/cloudflared/tunnel-credentials.json \
    farm-hub.yourdomain.com farm-provider.yourdomain.com farm-restart.yourdomain.com)
has_line "$yml" 'tunnel: 6ff42ae2-765d-4adf-8112-31c55c1551ef'
has_line "$yml" "credentials-file: '/opt/farm/config/cloudflared/tunnel-credentials.json'"
i=$(line_no "$yml" '  - hostname: farm-hub.yourdomain.com' tail)
is "$(printf '%s\n' "$yml" | sed -n "$((i + 1))p")" '    service: http://127.0.0.1:10000' 'sends the hub name to the hub port'
i=$(line_no "$yml" '  - hostname: farm-provider.yourdomain.com')
is "$(printf '%s\n' "$yml" | sed -n "$((i + 1))p")" '    service: http://127.0.0.1:10002' 'sends the provider name to the gate'
not_matches "$yml" '127\.0\.0\.1:10001' 'never points at the provider port'
i=$(line_no "$yml" '  - hostname: farm-restart.yourdomain.com')
is "$(printf '%s\n' "$yml" | sed -n "$((i + 1))p")" '    service: http://127.0.0.1:19999' 'sends the restart name to the restart service'
block=$(line_no "$yml" "    path: '(?i)appium'")
hub=$(line_no "$yml" '  - hostname: farm-hub.yourdomain.com' tail)
ok test "$block" -gt 0
ok test "$block" -lt "$hub"
is "$(printf '%s\n' "$yml" | sed -n "$((block + 1))p")" '    service: http_status:403' 'refuses hub paths containing "appium" before the hub rule'
block=$(line_no "$yml" "    path: '^/admin/provider/[^/]+/info'")
ok test "$block" -lt "$hub"
is "$(printf '%s\n' "$yml" | sed -n "$((block - 1))p")" '  - hostname: farm-hub.yourdomain.com' 'the provider-record rule is on the hub name'
is "$(printf '%s\n' "$yml" | sed -n "$((block + 1))p")" '    service: http_status:403' 'refuses the open provider record'
is "$(printf '%s\n' "$yml" | grep -Fxc '    service: http_status:403')" 3 'has three refusal rules'
is "$(printf '%s\n' "$yml" | grep -Fxc '  - hostname: farm-hub.yourdomain.com')" 4 'all three refusals are on the hub name'
is "$(printf '%s\n' "$yml" | awk 'NF' | tail -n 1)" '  - service: http_status:404' 'ends with the catch-all rule'
is "$(printf '%s\n' "$yml" | grep -Ec '^ +service: http://')" 3 'has three local services'
is "$(printf '%s\n' "$yml" | grep -E '^ +service: http://' | grep -Evc 'service: http://127\.0\.0\.1:[0-9]+$')" 0 'only ever points at this computer'
not_matches "$yml" "$(printf '\r|\t')" 'uses LF line ends and no tabs'
not_ok get_cloudflared_config_text blossom-farm /x.json a.yourdomain.com b.yourdomain.com c.yourdomain.com 2> /dev/null
not_ok get_cloudflared_config_text 6ff42ae2-765d-4adf-8112-31c55c1551ef /x.json localhost b.yourdomain.com c.yourdomain.com 2> /dev/null
y=$(get_cloudflared_config_text 6ff42ae2-765d-4adf-8112-31c55c1551ef "/Users/o'brien/t.json" a.yourdomain.com b.yourdomain.com c.yourdomain.com)
has_line "$y" "credentials-file: '/Users/o''brien/t.json'"

# ---------------------------------------------------------------------------
describe 'small helpers'
is "$(get_tunnel_id_from_text 'Created tunnel blossom-farm with id 6FF42AE2-765d-4adf-8112-31c55c1551ef')" 6ff42ae2-765d-4adf-8112-31c55c1551ef 'finds a UUID'
empty "$(get_tunnel_id_from_text 'no id here')" 'no UUID, no output'
a64=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8)
ok test_sha256_text "$a64"
not_ok test_sha256_text "${a64%a}"
not_ok test_sha256_text ''
not_ok test_sha256_text "g${a64%a}"
ok test_looks_down 502 ''
ok test_looks_down 200 '<!DOCTYPE html><html>'
not_ok test_looks_down 401 '{"error":"x"}'
is "$(get_text_sha256 abc)" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 'SHA-256 of "abc"'
printf 'abc' > "$WORK/abc"
is "$(get_file_sha256 "$WORK/abc")" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 'SHA-256 of a file'
is "$(trim_text '  a b  ')" 'a b' 'trim_text'
is "$(to_lower 'AbC-9')" 'abc-9' 'to_lower'
ok version_at_least 26.1 26.0
ok version_at_least 26.0 26
ok version_at_least 27.0.1 26.4
not_ok version_at_least 15.7.2 26.0
not_ok version_at_least 14.9 15.0
ok version_at_least 15.0 15.0
is "$(farm_arch_key arm64)" arm64 'arm64'
is "$(farm_arch_key x86_64)" x86_64 'x86_64'
empty "$(farm_arch_key i386)" 'unknown processor'
is "$(farm_label hub)" blossom-farm.hub 'service label'
is "$(url_encode 'Provider1')" 'Provider1' 'url_encode leaves plain text'
is "$(url_encode 'a b/c?d')" 'a%20b%2Fc%3Fd' 'url_encode escapes the rest'
ok test_loopback_address 127.0.0.1
ok test_loopback_address ::1
not_ok test_loopback_address '*'
not_ok test_loopback_address 192.168.1.5
is "$(printf 'root 0\n_a 300\n_b 301\nme 501\n' | first_free_id 300 499)" 302 'first_free_id skips used numbers'
empty "$(printf '_a 300\n' | first_free_id 300 300)" 'first_free_id: none left'

# ---------------------------------------------------------------------------
describe 'hide_log_secret'
line='[GIN] 2026/01/01 - 10:00:00 | 101 | 12m3s | 127.0.0.1 | GET      "/device/00008030-AAAA/ios-webrtc?token=eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoiYiJ9.c2lnbmF0dXJl"'
out=$(printf '%s\n' "$line" | hide_log_secret)
not_matches "$out" 'eyJ' 'masks a session token in a request address'
matches "$out" 'ios-webrtc\?token=<hidden>' 'keeps the rest of the address'
matches "$out" '^\[GIN\] 2026/01/01' 'keeps the rest of the line'
is "$(printf '%s\n' 'GET "/devices/control/x/lock?ttl_minutes=5&token=abc.def-123&x=1"' | hide_log_secret)" 'GET "/devices/control/x/lock?ttl_minutes=5&token=<hidden>&x=1"' 'masks the token wherever it stands in the query'
is "$(printf '%s\n' 'GET /x?TOKEN=abc&Password=p' | hide_log_secret)" 'GET /x?TOKEN=<hidden>&Password=<hidden>' 'in any letter case'
is "$(printf '%s\n' 'token eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoiYiJ9.c2ln was refused' | hide_log_secret)" 'token <hidden-token> was refused' 'masks a bare JWT'
is "$(printf '%s\n' 'Authorization: Bearer 0123456789abcdef0123456789abcdef' | hide_log_secret)" 'Authorization: Bearer <hidden>' 'masks a bearer header'
is "$(printf '%s\n' 'connected to Farm-Hub.yourdomain.com and farm-restart.yourdomain.com' | hide_log_secret farm-hub.yourdomain.com farm-restart.yourdomain.com)" 'connected to <host-name> and <host-name>' 'masks the given host names, in any letter case'
is "$(printf '%s\n' 'provider started on 127.0.0.1:10001' | hide_log_secret)" 'provider started on 127.0.0.1:10001' 'leaves an ordinary line alone'
is "$(printf '\n' | hide_log_secret a.b.c)" '' 'leaves an empty line alone'
is "$(printf '%s\n' 'farm-hubXyourdomain.com' | hide_log_secret farm-hub.yourdomain.com)" 'farm-hubXyourdomain.com' 'a dot in a name is a dot, not "any character"'

# ---------------------------------------------------------------------------
describe 'test_farm_root_trust (a /opt/farm that exists before the kit runs)'
is "$(test_farm_root_trust 1 0 0 0 750 0 755)" use 'uses a folder the kit locked: owned by root, nobody else may write'
is "$(test_farm_root_trust 1 0 0 0 700 0 755)" use 'uses a folder only root can open'
is "$(test_farm_root_trust 1 0 1 501 777 0 755)" recreate 'replaces an empty folder, whoever made it'
matches "$(test_farm_root_trust 1 0 0 501 755 0 755)" '^refuse: .+' 'refuses a folder with content that a user owns'
matches "$(test_farm_root_trust 1 0 0 0 770 0 755)" '^refuse: ' 'refuses a folder a group may write to'
matches "$(test_farm_root_trust 1 0 0 0 757 0 755)" '^refuse: ' 'refuses a folder everybody may write to'
matches "$(test_farm_root_trust 1 1 1 0 755 0 755)" '^refuse: ' 'refuses a link'
matches "$(test_farm_root_trust 0 0 0 0 644 0 755)" '^refuse: ' 'refuses a file'
matches "$(test_farm_root_trust 1 0 0 '' '' 0 755)" '^refuse: ' 'refuses a folder whose owner cannot be read'
matches "$(test_farm_root_trust 1 0 1 0 755 501 755)" '^refuse: ' 'refuses when the folder above belongs to a user'
matches "$(test_farm_root_trust 1 0 0 0 750 0 775)" '^refuse: ' 'refuses when the folder above is group-writable'
mkdir "$WORK/root-test" && chmod 755 "$WORK/root-test"
matches "$(get_farm_root_verdict "$WORK/root-test")" '^(recreate|refuse: )' 'get_farm_root_verdict reads a real folder'

# ---------------------------------------------------------------------------
describe 'JSON'
doc='{"result":{"access_token":"abc.def","workspaces":[{"id":"w1","name":"Default","is_default":true},{"id":"w2","name":"Second \"one\"","n":-12.5e3}]},"empty":{},"list":[],"nothing":null,"text":"a\\b\/c\u0041\u00e9\nline","port":10001}'
is "$(json_get "$doc" result.access_token)" 'abc.def' 'reads a nested string'
is "$(json_get "$doc" result.workspaces.1.name)" 'Second "one"' 'resolves an escaped quote'
is "$(json_get "$doc" result.workspaces.0.is_default)" true 'reads a boolean'
is "$(json_get "$doc" result.workspaces.1.n)" '-12.5e3' 'reads a number as written'
is "$(json_get "$doc" port)" 10001 'reads an integer'
is "$(json_get "$doc" nothing)" null 'reads null'
is "$(json_get "$doc" text)" 'a\b/cA\u00e9 line' 'resolves escapes; a line break becomes a space'
empty "$(json_get "$doc" missing)" 'a missing path prints nothing'
empty "$(json_get "$doc" empty)" 'an empty object prints nothing'
is "$(json_values "$doc" 'result.workspaces.*.id' | tr '\n' ' ')" 'w1 w2 ' 'lists every match of a path with *'
is "$(json_find_index "$doc" 'result.workspaces.*.name' Default)" 0 'finds the position of a value'
empty "$(json_find_index "$doc" 'result.workspaces.*.name' Nope)" 'no position for a value that is not there'
ok sh -c 'printf "%s" "$1" | LC_ALL=C awk -f "$2" > /dev/null' sh "$doc" "$FARMKIT_JSON_AWK"
for badjson in '' '{' '{"a":}' '{"a":1,}' '[1,2' '{"a":"b"} x' 'nope' '{"a":"\q"}' '{a:1}'; do
    not_ok sh -c 'printf "%s" "$1" | LC_ALL=C awk -f "$2" > /dev/null 2>&1' sh "$badjson" "$FARMKIT_JSON_AWK"
done
# What Windows PowerShell's ConvertTo-Json writes (an imported farm.json).
ps_json=$(printf '{\r\n    "nickname":  "Provider1",\r\n    "hubHost":  "farm-hub.yourdomain.com",\r\n    "routesCreated":  true,\r\n    "note":  "it\\u0027s"\r\n}\r\n')
is "$(json_get "$ps_json" nickname)" Provider1 'reads PowerShell-formatted JSON with CRLF'
is "$(json_get "$ps_json" routesCreated)" true 'reads its booleans'
is "$(json_get "$ps_json" note)" "it's" 'resolves the escape PowerShell writes for an apostrophe'
is "$(json_string 'a"b\c')" '"a\"b\\c"' 'json_string escapes quotes and backslashes'
is "$(json_string "$(printf 'a\tb\nc')")" '"a\tb\nc"' 'json_string escapes tabs and line breaks'
round='p@ss "w\ord" $x `y` {z} '"'"'q'"'"' '$(printf '\303\251')
is "$(json_get "{\"p\":$(json_string "$round")}" p)" "$round" 'a password survives json_string and the reader'
is "$(json_file_get "$KIT_ROOT/versions.json" gads.version)" v6.0.0 'reads versions.json'

# ---------------------------------------------------------------------------
describe 'curl_config_quote, xml_escape, render_template'
is "$(curl_config_quote 'a"b\c')" '"a\"b\\c"' 'curl_config_quote'
is "$(xml_escape 'a<b>&c')" 'a&lt;b&gt;&amp;c' 'xml_escape'
printf '<string>@A@</string><string>@B_XML@</string>\n' > "$WORK/t.plist"
is "$(render_template "$WORK/t.plist" 'A=x&y<z' 'B_XML=<true/>')" '<string>x&amp;y&lt;z</string><string><true/></string>' 'render_template escapes values, not _XML ones'
not_ok render_template "$WORK/t.plist" 'A=x' > /dev/null 2>&1

# ---------------------------------------------------------------------------
describe 'parse_lsof_listeners'
lsof_out=$(printf 'p101\ncmongod\nL_blossomfarm\nf9\nn127.0.0.1:27017\np202\ncGADS-drag\nL_blossomfarm\nf7\nn127.0.0.1:10001\nf12\nn*:49231\nf13\nn*:49231\nf14\nn[::1]:50000\np303\ncnode\nLroot\nf20\nn[::]:4723\n')
parsed=$(printf '%s\n' "$lsof_out" | parse_lsof_listeners)
has_line "$parsed" "$(printf '101\tmongod\t127.0.0.1\t27017\t_blossomfarm')"
has_line "$parsed" "$(printf '202\tGADS-drag\t*\t49231\t_blossomfarm')"
has_line "$parsed" "$(printf '202\tGADS-drag\t::1\t50000\t_blossomfarm')"
has_line "$parsed" "$(printf '303\tnode\t::\t4723\troot')"
is "$(printf '%s\n' "$parsed" | wc -l | tr -d ' ')" 5 'one line per socket, duplicates removed'

# ---------------------------------------------------------------------------
describe 'self-test report'
SELFTEST_STEPS=$(printf 'address\tok\tfine\t\ndns\tfail\tdoes not resolve\twait\n')
report=$(write_self_test_report); code=$?
is "$code" 1 'status 1 when a step failed'
matches "$report" 'OK +Addresses: fine' 'prints a passed step'
matches "$report" 'FAILED +DNS: does not resolve' 'prints a failed step'
matches "$report" 'What to do: wait' 'prints the fix'
matches "$report" 'NOT RUN Hub sign-in' 'names the steps that were not reached'
SELFTEST_STEPS=$(printf 'address\tok\ta\t\ndns\tok\ta\t\nreach\tok\ta\t\nsignin\tok\ta\t\nhub\tok\ta\t\ndevices\twarn\tnone yet\tphones\nprovider\tok\ta\t\nrestart\tok\ta\t\n')
report=$(write_self_test_report); code=$?
is "$code" 0 'status 0 when nothing failed (a CHECK is not a failure)'
not_matches "$report" 'NOT RUN' 'nothing is reported as not run'

# ---------------------------------------------------------------------------
describe 'self-test against stand-in answers'
# invoke_farm_http and farm_resolve are replaced: no network is used.
farm_resolve() { echo 104.16.0.1; }
FAKE_MODE=good
invoke_farm_http() {
    local url=$1 bearer='' arg prev=''
    for arg in "$@"; do [ "$prev" = --bearer ] && bearer=$arg; prev=$arg; done
    HTTP_STATUS=200; HTTP_TEXT='{}'; HTTP_ERROR=''; HTTP_CHALLENGE=0
    case $url in
        */health) [ "$FAKE_MODE" = challenge ] && { HTTP_STATUS=403; HTTP_CHALLENGE=1; } ;;
        */authenticate) HTTP_TEXT='{"result":{"access_token":"tok"}}'; [ "$FAKE_MODE" = badlogin ] && { HTTP_STATUS=401; HTTP_TEXT='{}'; } ;;
        */admin/devices) HTTP_TEXT='{"result":{"devices":[{"udid":"U1"},{"udid":"U2"}]}}' ;;
        *appium* | *APPIUM* | */admin/provider/*/info) HTTP_STATUS=403; [ "$FAKE_MODE" = leak ] && HTTP_STATUS=200 ;;
        */provider/Provider1/devices) HTTP_TEXT='{"result":[{"udid":"U1","connected":true,"provider_state":"live"},{"udid":"U3","connected":false,"provider_state":"init"}]}' ;;
        https://p.yourdomain.com/devices) HTTP_STATUS=401; [ "$FAKE_MODE" = open ] && HTTP_STATUS=200 ;;
        https://p.yourdomain.com/device/U1/info) [ "$bearer" = tok ] || HTTP_STATUS=401 ;;
        https://r.yourdomain.com/status)
            if [ "$bearer" = secret ]; then HTTP_TEXT='{"hub":true,"provider":true,"cloudflare":true,"keep_available":true,"mongodb":true,"action_in_progress":false}'
            else HTTP_STATUS=401; fi ;;
    esac
    return 0
}
invoke_farm_self_test h.yourdomain.com p.yourdomain.com r.yourdomain.com Provider1 blossom pw secret
is "$SELFTEST_FAILED" 0 'a healthy farm passes'
is "$(printf '%s' "$SELFTEST_STEPS" | cut -f1 | tr '\n' ' ')" 'address dns reach signin hub hub-appium hub-provider-info devices provider provider-locked restart restart-locked ' 'runs the twelve steps in order'
matches "$SELFTEST_STEPS" 'devices	ok	3 phone\(s\) registered, 1 live right now' 'counts registered and live phones'
FAKE_MODE=open; invoke_farm_self_test h.yourdomain.com p.yourdomain.com r.yourdomain.com Provider1 blossom pw secret
is "$SELFTEST_FAILED" 1 'fails when the provider answers without a login'
matches "$SELFTEST_STEPS" 'provider-locked	fail' 'and names that step'
FAKE_MODE=leak; invoke_farm_self_test h.yourdomain.com p.yourdomain.com r.yourdomain.com Provider1 blossom pw secret
matches "$SELFTEST_STEPS" 'hub-appium	fail' 'fails when the tunnel lets "appium" paths through'
matches "$SELFTEST_STEPS" 'hub-provider-info	fail' 'fails when the tunnel lets the provider record through'
FAKE_MODE=challenge; invoke_farm_self_test h.yourdomain.com p.yourdomain.com r.yourdomain.com Provider1 blossom pw secret
matches "$SELFTEST_STEPS" 'reach	fail	Cloudflare blocked or challenged' 'names a Cloudflare challenge'
is "$(printf '%s' "$SELFTEST_STEPS" | awk 'NF' | wc -l | tr -d ' ')" 3 'and stops there'
FAKE_MODE=badlogin; invoke_farm_self_test h.yourdomain.com p.yourdomain.com r.yourdomain.com Provider1 blossom pw secret
matches "$SELFTEST_STEPS" 'signin	fail	The hub refused' 'names a refused login'
FAKE_MODE=good; invoke_farm_self_test h.yourdomain.com p.yourdomain.com r.yourdomain.com Provider1 blossom pw wrong
matches "$SELFTEST_STEPS" 'restart	fail	The restart service refused the secret' 'names a refused restart secret'
farm_resolve() { echo 192.168.1.20; }
invoke_farm_self_test h.yourdomain.com p.yourdomain.com r.yourdomain.com Provider1 blossom pw secret
matches "$SELFTEST_STEPS" 'dns	fail	h.yourdomain.com resolves to a private address' 'refuses a name that resolves to a private address'
farm_resolve() { :; }
invoke_farm_self_test h.yourdomain.com p.yourdomain.com r.yourdomain.com Provider1 blossom pw secret
matches "$SELFTEST_STEPS" 'dns	fail	h.yourdomain.com does not resolve yet' 'reports a name that does not resolve'

# ---------------------------------------------------------------------------
describe 'versions.json (macOS entries)'
v=$(cat "$KIT_ROOT/versions.json")
for arch in arm64 x86_64; do
    for key in hub.zipSha256 hub.exeSha256 provider.sha256 node.sha256 mongodb.sha256 mongodbTools.sha256 cloudflared.sha256 cloudflared.exeSha256; do
        ok test_sha256_text "$(json_get "$v" "macos.$arch.$key")"
    done
    matches "$(json_get "$v" "macos.$arch.hub.zipUrl")" '^https://github\.com/shamanec/GADS/releases/download/' 'the hub comes from its publisher'
    matches "$(json_get "$v" "macos.$arch.provider.url")" '^https://github\.com/fyhcrew-art/blossom-farm-kit/releases/download/' 'the provider comes from this repository'
    matches "$(json_get "$v" "macos.$arch.provider.url")" "$(json_get "$v" gadsDrag.releaseTag)" 'and from the pinned release'
    matches "$(json_get "$v" "macos.$arch.node.url")" '^https://nodejs\.org/dist/v' 'Node.js comes from nodejs.org'
    matches "$(json_get "$v" "macos.$arch.mongodb.url")" '^https://fastdl\.mongodb\.org/osx/' 'MongoDB comes from mongodb.org'
    matches "$(json_get "$v" "macos.$arch.mongodbTools.url")" '^https://fastdl\.mongodb\.org/tools/db/' 'the database tools come from mongodb.org'
    matches "$(json_get "$v" "macos.$arch.cloudflared.url")" '^https://github\.com/cloudflare/cloudflared/releases/download/' 'cloudflared comes from its publisher'
    matches "$(json_get "$v" "macos.$arch.minimumMacOS")" '^[0-9]+\.[0-9]+$' 'a minimum macOS version is named'
done
is "$(json_get "$v" macos.node)" "$(json_get "$v" winget.node.version)" 'the same Node.js version on both systems'
is "$(json_get "$v" macos.mongodb)" "$(json_get "$v" winget.mongodb.version)" 'the same MongoDB version on both systems'
is "$(json_get "$v" macos.cloudflared)" "$(json_get "$v" winget.cloudflared.version)" 'the same cloudflared version on both systems'
is "$(json_get "$v" macos.mongodbTools)" "$(json_get "$v" winget.mongodbTools.version)" 'the same database tools version on both systems'

# ---------------------------------------------------------------------------
describe 'launchd property lists'
get_farm_paths /opt/farm
for name in mongodb hub provider gate keep-available restart cloudflared firewall; do
    template=$KIT_ROOT/launchd/blossom-farm.$name.plist
    ok test -f "$template"
    rendered=$(render_template "$template" "FARM_ROOT=$FARM_ROOT" "SERVICE_USER=$FARM_SERVICE_USER" "SERVICE_GROUP=$FARM_SERVICE_GROUP" \
        'NICKNAME=Provider1' 'PROVIDER_PATH=/opt/farm/bin/tools:/usr/bin:/bin' 'APPIUM_ENV_XML=' 2> /dev/null)
    code=$?
    is "$code" 0 "$name: every @NAME@ is filled in"
    matches "$rendered" "<string>blossom-farm\\.$name</string>" "$name: the label is the file name"
    not_matches "$rendered" '0\.0\.0\.0' "$name: nothing listens on all addresses"
    if [ "$name" = restart ] || [ "$name" = firewall ]; then
        not_matches "$rendered" '<key>UserName</key>' "$name runs as root"
    else
        matches "$rendered" '<string>_blossomfarm</string>' "$name runs as the service account"
    fi
    printf '%s\n' "$rendered" > "$WORK/blossom-farm.$name.plist"
done
matches "$(cat "$KIT_ROOT/launchd/blossom-farm.restart.plist")" 'GADS_RESTART_SECRET_FILE' 'the restart service is given the path of its secret file'

# ---------------------------------------------------------------------------
describe 'farm-run.sh (start order and logs)'
RUN=$KIT_ROOT/services/farm-run.sh
log=$WORK/run.log
bash "$RUN" --log "$log" -- /bin/sh -c 'echo one; echo two >&2'
sleep 0.3
has_line "$(cat "$log")" one
has_line "$(cat "$log")" two
# rotation: the file is renamed while the program runs; new lines go to a new file
( bash "$RUN" --log "$log" -- /bin/sh -c 'echo before; sleep 1; echo after' ) &
sleep 0.5; mv "$log" "$log.0"; wait
sleep 0.3
has_line "$(cat "$log.0")" before
has_line "$(cat "$log" 2> /dev/null)" after
# a port that never opens: gives up with status 1 and says so in the log
closed_port=1
bash "$RUN" --log "$log" --wait "$closed_port" --wait-seconds 1 -- /bin/sh -c 'echo started'; code=$?
sleep 0.3
is "$code" 1 'does not start the program while the port is closed'
matches "$(cat "$log")" 'still waiting for 127\.0\.0\.1:1' 'and logs what it waits for'
not_matches "$(cat "$log")" '^started$' 'the program was not run'
not_ok bash "$RUN" --log "$log" 2> /dev/null
not_ok bash "$RUN" -- /bin/true 2> /dev/null

# ---------------------------------------------------------------------------
describe 'keep-available.sh'
KEEP=$KIT_ROOT/services/keep-available.sh
out=$(bash "$KEEP" --check-config "$WORK/none.json" 2>&1); code=$?
is "$code" 1 'stops without a configuration file'
printf '{"hubUrl":"https://farm-hub.yourdomain.com","username":"u","password":"p"}' > "$WORK/k.json"
out=$(bash "$KEEP" --check-config "$WORK/k.json" 2>&1); code=$?
is "$code" 1 'refuses a hub address that is not this computer'
matches "$out" 'must be the hub on this computer' 'and says why'
not_matches "$out" '"p"|password.*p$' 'without printing the configuration'
printf '{"hubUrl":"http://127.0.0.1:10000","username":"u"}' > "$WORK/k.json"
not_ok bash "$KEEP" --check-config "$WORK/k.json" > /dev/null 2>&1
printf '{\r\n  "hubUrl":  "http://127.0.0.1:10000",\r\n  "username":  "farm-keepalive",\r\n  "password":  "s3cret-value"\r\n}' > "$WORK/k.json"
out=$(bash "$KEEP" --check-config "$WORK/k.json" 2>&1); code=$?
is "$code" 0 'accepts the file the installer writes (also as Windows wrote it)'
not_matches "$out" 's3cret-value' 'and prints no password'
src=$(cat "$KEEP")
not_matches "$src" 'curl[^|]*(-u |--user |-d |--data|-H )' 'no credential is ever given to curl as an argument'

# ---------------------------------------------------------------------------
describe 'the scripts'
for f in "$KIT_ROOT"/install.sh "$KIT_ROOT"/bootstrap.sh "$KIT_ROOT"/lib/farmkit.sh "$KIT_ROOT"/scripts/*.sh "$KIT_ROOT"/services/*.sh "$KIT_ROOT"/tests/*.sh; do
    ok bash -n "$f"
    if LC_ALL=C grep -q '[^[:print:][:space:]]' "$f"; then fail "$f contains non-ASCII characters"; else pass; fi
    # What the bash 3.2 of macOS does not have.
    if grep -nE 'declare -[aA-Zb-z]*A|mapfile|readarray|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|wait -n|coproc |&>>|\|&' "$f" | grep -v 'grep -nE' | grep -v '^[0-9]*:[[:space:]]*#' > /dev/null; then
        fail "$f uses a feature bash 3.2 does not have"
    else pass; fi
done
for name in status self-test update rotate-secrets export-farm import-farm uninstall; do
    ok test -f "$KIT_ROOT/scripts/$name.sh"
    ok test -f "$KIT_ROOT/scripts/$name.ps1"
done
# every installer has both of its parts, and both offer the pairing options
for name in install bootstrap; do
    ok test -f "$KIT_ROOT/$name.sh"
    ok test -f "$KIT_ROOT/$name.ps1"
done
ok grep -q -- '--pairing-code' "$KIT_ROOT/install.sh"
ok grep -q -- '--app-origin' "$KIT_ROOT/install.sh"
ok grep -q 'PairingCode' "$KIT_ROOT/install.ps1"
ok grep -q 'AppOrigin' "$KIT_ROOT/install.ps1"

# ---------------------------------------------------------------------------
echo
if [ "$FAILED" -eq 0 ]; then
    printf 'bash %s: all %d tests passed.\n' "$BASH_VERSION" "$PASSED"
    exit 0
fi
printf 'bash %s: %d of %d tests FAILED.\n' "$BASH_VERSION" "$FAILED" $((PASSED + FAILED))
exit 1
