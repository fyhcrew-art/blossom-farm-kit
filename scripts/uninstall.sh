#!/bin/bash
# Blossom farm kit - removes the farm services from this Mac; optionally the
# data too.
#
#     sudo bash scripts/uninstall.sh
#         removes the launchd services, the kit's packet filter rule and its
#         log rotation. /opt/farm with the database, the tunnel and the
#         programs stay: install.sh brings the farm back.
#
#     sudo bash scripts/uninstall.sh --remove-data
#         also deletes the tunnel at Cloudflare (when possible), /opt/farm
#         with the GADS database, every secret and phone pairing in it, and
#         the farm's service account.
#
# What the script does not remove is listed at the end with the way to remove it.
#   --remove-data     Delete the tunnel, /opt/farm and the service account. Cannot be undone.
#   --services-only   Same as running without options (kept for clarity in instructions).

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"
trap farm_http_cleanup EXIT

REMOVE_DATA=0; SERVICES_ONLY=0
for arg in "$@"; do
    case $arg in
        --remove-data) REMOVE_DATA=1 ;;
        --services-only) SERVICES_ONLY=1 ;;
        -h | --help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) stop_farm "Unknown option: $arg" 'Use --remove-data, --services-only, or no option.' ;;
    esac
done

assert_macos_root
if [ "$REMOVE_DATA" = 1 ] && [ "$SERVICES_ONLY" = 1 ]; then
    stop_farm '--remove-data and --services-only contradict each other.' 'Use one of them.'
fi
get_farm_paths /opt/farm
read_farm_config

if [ "$REMOVE_DATA" = 1 ]; then
    echo
    write_color "$FK_YELLOW" 'This deletes the farm from this Mac: services, tunnel, the GADS database'
    write_color "$FK_YELLOW" '(phones, users, uploaded WebDriverAgent), every secret and the phones'"'"' pairings.'
    write_color "$FK_YELLOW" 'It cannot be undone. To move a farm instead, use scripts/export-farm.sh first.'
    answer=''
    IFS= read -r -p 'Type DELETE to continue: ' answer < /dev/tty
    if [ "$answer" != DELETE ]; then write_note 'Nothing was changed.'; exit 0; fi
fi

write_step 'Removing the launchd services'
for name in $(get_farm_service_names) mongodb firewall; do
    if remove_farm_service "$name"; then write_ok "$(farm_label "$name") removed"
    else write_note "$(farm_label "$name"): not installed"; fi
done
remove_farm_firewall_block
write_ok "The kit's packet filter rule is removed (the packet filter itself is left as it is)."
if [ -f "$FARM_NEWSYSLOG_FILE" ]; then rm -f "$FARM_NEWSYSLOG_FILE"; write_ok "$FARM_NEWSYSLOG_FILE removed (log rotation)."; fi

if [ "$REMOVE_DATA" = 1 ]; then
    write_step 'Deleting the tunnel at Cloudflare'
    if [ -x "$FARM_CLOUDFLARED_EXE" ] && [ -n "$FARM_CFG_TUNNEL_ID" ] && [ -f "$FARM_TUNNEL_CERT" ]; then
        TUNNEL_ORIGIN_CERT=$FARM_TUNNEL_CERT run_native "$FARM_CLOUDFLARED_EXE" tunnel delete -f "$FARM_CFG_TUNNEL_ID"
        if [ "$RUN_CODE" -eq 0 ]; then write_ok 'Tunnel deleted.'
        else write_warn "The tunnel could not be deleted from here ($(printf '%s' "$RUN_OUTPUT" | tr '\n' ' ')). Delete it in the Cloudflare dashboard: Zero Trust -> Networks -> Tunnels."; fi
    else
        write_warn 'The tunnel cannot be deleted from here. Delete it in the Cloudflare dashboard: Zero Trust -> Networks -> Tunnels.'
    fi

    write_step 'Deleting /opt/farm'
    if [ -d "$FARM_ROOT" ] && [ ! -L "$FARM_ROOT" ] && [ "$FARM_ROOT" = /opt/farm ]; then
        rm -rf "$FARM_ROOT"
        write_ok '/opt/farm deleted (the database, secrets, tunnel credentials, pairings, programs, logs).'
    fi
    remove_service_account
    write_ok "The service account $FARM_SERVICE_USER is removed."
fi

write_step 'What is left, and how to remove it'
if [ "$FARM_HAS_CONFIG" = 1 ]; then
    write_note "DNS records at Cloudflare (dashboard -> your domain -> DNS): $FARM_CFG_HUB_HOST, $FARM_CFG_PROVIDER_HOST, $FARM_CFG_RESTART_HOST"
    write_note 'The site in Blossom CRM: Phone Farm -> Farm setup -> Remove.'
fi
write_note 'FFmpeg and OpenSSL from Homebrew (only if nothing else on this Mac uses them):   brew uninstall ffmpeg'
write_note 'Sleep was switched off by install.sh: System Settings -> Energy, or   sudo pmset -a sleep 1'
write_note 'The pairings macOS keeps for the phones stay with macOS. To forget them, reset "Location & Privacy" on each iPhone.'
if [ "$REMOVE_DATA" = 0 ]; then
    write_note '/opt/farm (the database included) was kept. Run install.sh to bring the farm back, or this script with --remove-data to delete it.'
fi
exit 0
