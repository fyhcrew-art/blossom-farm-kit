#!/bin/bash
# Blossom farm kit - shows the state of the farm on this Mac: services, ports,
# the packet filter, versions.
#
#     sudo bash scripts/status.sh
#     sudo bash scripts/status.sh --logs
#
# Changes nothing. Prints no password and no secret file.
#
# With --logs it prints the last lines of the service logs. Those logs are
# written by the farm programs, and GADS writes the address of every request
# into them, which can include a hub session token (valid for up to an hour).
# This script masks tokens and the farm's host names before printing, so its
# output is what to copy when you ask for help. Do not post the log FILES
# themselves anywhere: they are not masked.

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"
trap farm_http_cleanup EXIT

LOGS=0
for arg in "$@"; do
    case $arg in
        --logs) LOGS=1 ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) stop_farm "Unknown option: $arg" 'Use --logs, or no option.' ;;
    esac
done

assert_macos_root
get_farm_paths /opt/farm
read_farm_config
problems=0
note_problem() { write_warn "$1"; problems=$((problems + 1)); }

write_step 'Installation'
if [ "$FARM_HAS_CONFIG" = 0 ]; then
    note_problem 'No installation record (/opt/farm/config/farm.json). Run install.sh.'
else
    write_note "Kit $FARM_CFG_KIT, installed $FARM_CFG_INSTALLED_AT"
    write_note "Hub        https://$FARM_CFG_HUB_HOST"
    write_note "Provider   https://$FARM_CFG_PROVIDER_HOST   (nickname $FARM_CFG_NICKNAME)"
    write_note "Restart    https://$FARM_CFG_RESTART_HOST"
fi

write_step 'Services (launchd)'
for name in mongodb hub provider gate keep-available restart cloudflared; do
    label=$(printf '%-28s' "$(farm_label "$name")")
    if [ ! -f "$(farm_plist_path "$name")" ]; then note_problem "$label not installed"
    elif farm_service_running "$name"; then write_ok "$label running   (starts with the Mac)"
    elif farm_service_loaded "$name"; then note_problem "$label loaded, but its program is not running (see /opt/farm/logs)"
    else note_problem "$label stopped (not loaded). Start it:  sudo launchctl bootstrap system $(farm_plist_path "$name")"; fi
done
if [ -S /var/run/usbmuxd ]; then write_ok "usbmuxd                      running   (Apple's USB support for iPhones, part of macOS)"
else note_problem "usbmuxd: /var/run/usbmuxd is missing. Apple's USB support for iPhones is not running; restart the Mac."; fi

write_step 'Fixed ports (each must listen on 127.0.0.1 only)'
get_farm_listeners
for entry in '27017 MongoDB' '10000 GADS hub' '10001 GADS provider' '10002 provider gate' '19999 restart service'; do
    port=${entry%% *}; what=${entry#* }
    addresses=$(printf '%s\n' "$FARM_LISTENERS" | awk -F '\t' -v p="$port" '$4 == p { print $3 }' | sort -u | tr '\n' ' ')
    if [ -z "$addresses" ]; then note_problem "$(printf '%-6s' "$port")$what: nothing is listening"; continue; fi
    outside=''
    for a in $addresses; do test_loopback_address "$a" || outside=1; done
    if [ -n "$outside" ]; then note_problem "$(printf '%-6s' "$port")$what: listens on ${addresses% } - REACHABLE FROM YOUR NETWORK, see docs/security.md"
    else write_ok "$(printf '%-6s' "$port")$what: ${addresses% }"; fi
done

write_step 'Other ports opened by the farm programs, and the packet filter'
# For every iPhone the GADS provider opens ports (WebDriverAgent, the screen
# stream) on ALL addresses of this Mac, on numbers chosen at run time; an
# Appium server does the same. None of them asks for a login. The kit's
# packet filter rule keeps other computers away from them.
get_farm_firewall_state
wide=$(printf '%s\n' "$FARM_LISTENERS" | awk -F '\t' -v u="$FARM_SERVICE_USER" \
    '$5 == u && $4 != 27017 && $4 != 10000 && $4 != 10001 && $4 != 10002 && $4 != 19999 && $3 !~ /^127\./ && $3 != "::1" { print $2 "\t" $4 }' | sort -u)
if [ -z "$wide" ]; then
    write_ok 'No farm program listens on a network address right now (the provider opens its per-phone ports when phones are connected).'
else
    covered=''; uncovered=''
    while IFS='	' read -r cmd port; do
        [ -n "$port" ] || continue
        if firewall_covers_port "$port"; then covered="$covered $cmd:$port"; else uncovered="$uncovered $cmd:$port"; fi
    done <<LIST
$wide
LIST
    [ -n "$covered" ] && write_ok "Listening on all addresses (per-phone ports), closed to other computers by the kit's packet filter rule:$covered"
    [ -n "$uncovered" ] && note_problem "Listening on all addresses and NOT covered by the kit's packet filter rule:$uncovered - OTHER COMPUTERS ON YOUR NETWORK MAY REACH THESE PORTS, see docs/security.md, section 1"
fi
if [ "$FW_AVAILABLE" = 0 ]; then
    note_problem 'The packet filter of macOS (pf) could not be asked. Make sure whatever firewall manages this Mac blocks incoming connections to it.'
elif [ -z "$FW_FIRST" ]; then
    note_problem "The kit's packet filter rule is not loaded. Run install.sh again (it loads the rule), and read /opt/farm/logs/firewall.log."
elif [ "$FW_ENABLED" = 0 ]; then
    note_problem "The packet filter of macOS (pf) is switched OFF. The kit's rule does nothing while it is off (docs/security.md, section 1). Run install.sh again."
else
    write_ok "The packet filter is on; new connections from the network to ports $FW_FIRST-$FW_LAST are dropped."
fi

write_step 'Local answers'
invoke_farm_http 'http://127.0.0.1:10000/health' --timeout 5
if [ "$HTTP_STATUS" -eq 401 ] || [ "$HTTP_STATUS" -eq 200 ]; then write_ok "Hub answers (HTTP $HTTP_STATUS)."; else note_problem "Hub: HTTP $HTTP_STATUS $HTTP_ERROR"; fi
invoke_farm_http 'http://127.0.0.1:10002/devices' --timeout 5
if [ "$HTTP_STATUS" -eq 401 ]; then write_ok 'Provider gate answers and refuses a request without a token (401).'; else note_problem "Provider gate: HTTP $HTTP_STATUS $HTTP_ERROR (expected 401)"; fi
invoke_farm_http 'http://127.0.0.1:10001/info' --timeout 5
if [ "$HTTP_STATUS" -eq 200 ]; then write_ok 'Provider answers locally.'; else note_problem "Provider: HTTP $HTTP_STATUS $HTTP_ERROR. Read /opt/farm/logs/provider.log (docs/phones.md explains the WebDriverAgent message)."; fi
invoke_farm_http 'http://127.0.0.1:19999/status' --timeout 5
if [ "$HTTP_STATUS" -eq 401 ]; then write_ok 'Restart service answers and refuses a request without the secret (401).'; else note_problem "Restart service: HTTP $HTTP_STATUS $HTTP_ERROR (expected 401)"; fi

write_step 'Programs'
arch=$(farm_arch_key "$(uname -m)")
installed=$FARM_CONFIG/versions.json
if [ -f "$installed" ] && [ -n "$arch" ]; then
    for entry in "$FARM_HUB_EXE|macos.$arch.hub.exeSha256|GADS hub $(json_file_get "$installed" gads.version)" \
        "$FARM_PROVIDER_EXE|macos.$arch.provider.sha256|GADS provider $(json_file_get "$installed" gadsDrag.version)"; do
        file=${entry%%|*}; rest=${entry#*|}; key=${rest%%|*}; what=${rest#*|}
        if [ ! -f "$file" ]; then note_problem "$what: file missing"; continue; fi
        if [ "$(get_file_sha256 "$file")" = "$(to_lower "$(json_file_get "$installed" "$key")")" ]; then write_ok "$what: SHA-256 matches the pinned value"
        else note_problem "$what: the file on disk does NOT match the pinned SHA-256"; fi
    done
fi
for entry in "node|$FARM_NODE_EXE" "mongod|$FARM_MONGOD_EXE" "cloudflared|$FARM_CLOUDFLARED_EXE" "ffmpeg|$FARM_TOOLS_DIR/ffmpeg"; do
    tool=${entry%%|*}; where=${entry#*|}
    if [ -x "$where" ]; then
        target=$where
        [ -L "$where" ] && target="$where -> $(readlink "$where")"
        write_ok "$(printf '%-12s' "$tool")$target"
    else note_problem "$(printf '%-12s' "$tool")not found ($where)"; fi
done
free_kb=$(df -Pk / | awk 'NR == 2 { print $4 }')
case $free_kb in '' | *[!0-9]*) free_kb=0 ;; esac
if [ "$free_kb" -lt 5242880 ]; then note_problem "Only $((free_kb / 1048576)) GB free on the startup disk."; else write_ok "$((free_kb / 1048576)) GB free on the startup disk."; fi

write_step 'Power'
sleep_minutes=$(pmset -g 2> /dev/null | awk '$1 == "sleep" { print $2; exit }')
if [ "$sleep_minutes" = 0 ]; then write_ok 'Sleep is switched off.'
else note_problem "This Mac goes to sleep after ${sleep_minutes:-?} minute(s): a sleeping computer is an offline farm. Switch it off:  sudo pmset -a sleep 0"; fi
if fdesetup status 2> /dev/null | grep -q 'FileVault is On'; then
    write_note 'FileVault is on: after a restart or a power cut the farm stays off until somebody types the password at this Mac (README, "Check that it survives a restart").'
fi

if [ "$LOGS" = 1 ]; then
    echo
    write_color "$FK_YELLOW" '   Below: the end of each log, with session tokens and your host names masked.'
    write_color "$FK_YELLOW" '   When asking for help, copy THIS output. Never post a log file itself.'
    for log in mongodb.log hub.log provider.log provider-gate.log keep-available.log restart-server.log cloudflared.log firewall.log; do
        file=$FARM_LOGS/$log
        write_step "Last lines of $file"
        if [ -f "$file" ]; then tail -n 15 "$file" | hide_log_secret "$FARM_CFG_HUB_HOST" "$FARM_CFG_PROVIDER_HOST" "$FARM_CFG_RESTART_HOST" | sed 's/^/   /'
        else write_note '(no such file yet)'; fi
    done
fi

echo
if [ "$problems" -eq 0 ]; then
    write_ok 'No problem found on this Mac. To test the public side: sudo bash scripts/self-test.sh'
    exit 0
fi
write_warn "$problems point(s) need attention (marked [warn] above). README, section Troubleshooting, lists the usual causes."
exit 2
