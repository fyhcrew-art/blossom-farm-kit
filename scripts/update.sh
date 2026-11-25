#!/bin/bash
# Blossom farm kit - moves an installed farm to the versions of THIS kit folder.
#
# Download the newer kit, unpack it, and from inside the new folder run:
#
#     sudo bash scripts/update.sh
#
# It downloads the GADS programs pinned in this kit's versions.json (and
# verifies their SHA-256), stops the farm for about a minute, replaces the
# programs and the service scripts, and starts everything again. The
# database, the secrets, the tunnel and the phones' pairings are not touched.
# The previous programs are kept next to the new ones; to go back:
#
#     sudo bash scripts/update.sh --rollback
#
# Node.js, MongoDB, cloudflared and FFmpeg are not changed by this script; see
# README, section "Updating".
#   --rollback               Put back the programs and service scripts that the last update replaced.
#   --provider-binary PATH   A GADS-drag program you already have, used instead of downloading it.
#                            Only accepted when its SHA-256 is the one pinned in versions.json.

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"
SCRIPT_ARGS=("$@")
trap farm_http_cleanup EXIT

ROLLBACK=0; PROVIDER_BINARY=''
while [ $# -gt 0 ]; do
    case $1 in
        --rollback) ROLLBACK=1 ;;
        --provider-binary=*) PROVIDER_BINARY=${1#*=} ;;
        --provider-binary) [ $# -ge 2 ] || stop_farm '--provider-binary needs a path.' 'Give the full path of the GADS-drag program.'; PROVIDER_BINARY=$2; shift ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) stop_farm "Unknown option: $1" 'Use --rollback, --provider-binary PATH, or no option.' ;;
    esac
    shift
done

stop_farm_programs() {
    local name
    for name in cloudflared keep-available restart gate provider hub; do stop_farm_service "$name"; done
}

farm_ports_missing() {
    # Prints what does not answer on its local port after a start. A service
    # that launchd runs is not yet a program that works.
    wait_tcp_port 10000 90 || printf 'hub (port 10000) '
    wait_tcp_port 10002 20 || printf 'gate (port 10002) '
    wait_tcp_port 19999 20 || printf 'restart (port 19999) '
}

start_farm_programs() {
    # Prints the services that did not start.
    local name
    for name in $(get_farm_start_order); do
        [ -f "$(farm_plist_path "$name")" ] || continue
        start_farm_service "$name" 40 || printf '%s ' "$name"
    done
}

assert_macos_root
use_protected_kit_folder "scripts/update.sh" ${SCRIPT_ARGS[@]+"${SCRIPT_ARGS[@]}"}
get_farm_arch
get_farm_paths /opt/farm
read_farm_config
[ "$FARM_HAS_CONFIG" = 1 ] || stop_farm 'This Mac has no farm installation.' 'Run install.sh instead.'
BACKUP=$FARM_ROOT/previous
# what is replaced: <installed file>|<name in the backup folder>
FILES="$FARM_HUB_EXE|GADS
$FARM_PROVIDER_EXE|GADS-drag
$FARM_SERVICES/restart-server.js|restart-server.js
$FARM_SERVICES/provider-gate.js|provider-gate.js
$FARM_SERVICES/keep-available.sh|keep-available.sh
$FARM_SERVICES/farm-run.sh|farm-run.sh
$FARM_SERVICES/farm-firewall.sh|farm-firewall.sh
$FARM_SERVICES/json.awk|json.awk
$FARM_CONFIG/versions.json|versions.json"

if [ "$ROLLBACK" = 1 ]; then
    write_step 'Rollback to the programs before the last update'
    if [ ! -f "$BACKUP/versions.json" ]; then
        stop_farm 'There is nothing to go back to (/opt/farm/previous is empty).' 'A rollback is only possible after an update made with this script.'
    fi
    stop_farm_programs
    printf '%s\n' "$FILES" | while IFS='|' read -r target saved; do
        # as a new file, never onto the program it replaces (lib/farmkit.sh, copy_as_new_file)
        if [ -f "$BACKUP/$saved" ] && ! copy_as_new_file "$BACKUP/$saved" "$target"; then
            write_warn "Could not put back $target."
        fi
    done
    bad=$(start_farm_programs)
    [ -n "$bad" ] || bad=$(farm_ports_missing)
    [ -z "$bad" ] || stop_farm "After the rollback these services did not start or do not answer: $bad" 'Run scripts/status.sh --logs and read the log of the first one.'
    wait_tcp_port 10001 30 || write_warn 'The GADS provider is not listening yet. Read /opt/farm/logs/provider.log.'
    write_ok 'The previous programs are back and running.'
    exit 0
fi

read_kit_versions "$KIT_ROOT"
current=$FARM_CONFIG/versions.json
write_step 'What changes'
was='(unknown)'
[ -f "$current" ] && was="kit $(json_file_get "$current" kit), hub $(json_file_get "$current" gads.version), provider $(json_file_get "$current" gadsDrag.version)"
write_note "Installed: $was"
write_note "This kit:  kit $(kit_version kit), hub $(kit_version gads.version), provider $(kit_version gadsDrag.version)"

write_step 'Downloading and verifying (the farm keeps running)'
new_hub=$FARM_DOWNLOADS/update-GADS
new_provider=$FARM_DOWNLOADS/update-GADS-drag
hub_hash=$(to_lower "$(kit_version "macos.$FARM_ARCH.hub.exeSha256")")
provider_hash=$(to_lower "$(kit_version "macos.$FARM_ARCH.provider.sha256")")
if [ -f "$FARM_HUB_EXE" ] && [ "$(get_file_sha256 "$FARM_HUB_EXE")" = "$hub_hash" ]; then
    cp -f "$FARM_HUB_EXE" "$new_hub"
else
    zip=$FARM_DOWNLOADS/update-gads-mac.zip
    get_verified_download "$(kit_version "macos.$FARM_ARCH.hub.zipUrl")" "$(kit_version "macos.$FARM_ARCH.hub.zipSha256")" "$zip" "GADS $(kit_version gads.version) for macOS"
    unpack=$FARM_DOWNLOADS/update-gads-mac
    rm -rf "$unpack"; mkdir "$unpack"
    if ! unzip -q -o "$zip" -d "$unpack" || [ ! -f "$unpack/GADS" ] || [ "$(get_file_sha256 "$unpack/GADS")" != "$hub_hash" ]; then
        rm -rf "$unpack"
        stop_farm 'GADS inside the downloaded archive does not have the expected SHA-256.' 'Nothing was changed. Delete /opt/farm/downloads/update-* and run the update again; if it repeats, report it on the kit repository.'
    fi
    cp -f "$unpack/GADS" "$new_hub"
    rm -rf "$unpack"
fi
if [ -f "$FARM_PROVIDER_EXE" ] && [ "$(get_file_sha256 "$FARM_PROVIDER_EXE")" = "$provider_hash" ]; then
    cp -f "$FARM_PROVIDER_EXE" "$new_provider"
else
    if [ -n "$PROVIDER_BINARY" ]; then
        if [ ! -f "$PROVIDER_BINARY" ] || [ "$(get_file_sha256 "$PROVIDER_BINARY")" != "$provider_hash" ]; then
            stop_farm "--provider-binary: $PROVIDER_BINARY is missing or does not have the SHA-256 this kit pins for the provider $(kit_version gadsDrag.version)." 'Nothing was changed. Use the GADS-drag program of exactly this version and for this processor, or leave --provider-binary out to download it.'
        fi
        cp -f "$PROVIDER_BINARY" "$new_provider"
    fi
    get_verified_download "$(kit_version "macos.$FARM_ARCH.provider.url")" "$provider_hash" "$new_provider" "the patched GADS provider $(kit_version gadsDrag.version)"
fi
if [ "$(get_file_sha256 "$new_hub")" != "$hub_hash" ] || [ "$(get_file_sha256 "$new_provider")" != "$provider_hash" ]; then
    stop_farm 'A downloaded program could not be kept on the disk.' 'Nothing was changed. Check the free space on the disk and run the update again.'
fi
write_ok 'Both programs are downloaded and their SHA-256 values match.'

write_step 'Replacing (the farm is offline for about a minute)'
_fk_make_dir "$BACKUP" private
stop_farm_programs
printf '%s\n' "$FILES" | while IFS='|' read -r target saved; do
    [ -f "$target" ] && cp -pf "$target" "$BACKUP/$saved"
done
install_one_file "$new_hub" "$FARM_HUB_EXE"
install_one_file "$new_provider" "$FARM_PROVIDER_EXE"
copy_service_files
if ! { cp -f "$KIT_ROOT/versions.json" "$current" && chown 0:0 "$current" && chmod 600 "$current"; }; then
    stop_farm "Could not write $current." 'Go back with   sudo bash scripts/update.sh --rollback'
fi
rm -f "$new_hub" "$new_provider"

bad=$(start_farm_programs)
[ -n "$bad" ] || bad=$(farm_ports_missing)
if [ -n "$bad" ]; then
    stop_farm "After the update these services did not start or do not answer: $bad" 'Go back with   sudo bash scripts/update.sh --rollback   . To report it on the kit repository, copy the output of   sudo bash scripts/status.sh --logs   (it masks session tokens and your host names). Never post a file from /opt/farm/logs itself: GADS writes request addresses into its logs, and they can contain a login token.'
fi
wait_tcp_port 10001 30 || write_warn 'The GADS provider is not listening yet. Read /opt/farm/logs/provider.log; scripts/status.sh says more.'
write_ok 'Updated and running. Check with scripts/status.sh, then "Test connection" in Blossom.'
read_farm_pairing
if [ "$FARM_IS_PAIRED" = 1 ]; then
    if pair_send_computer; then write_ok "Blossom ($PAIR_ORIGIN) was told the versions this computer runs now."
    else write_note "Blossom could not be told the new versions ($APP_MESSAGE). Nothing depends on it; scripts/status.sh shows the pairing."; fi
fi
write_note 'If this kit changed the tunnel configuration or the services (see its release notes), run install.sh once as well.'
exit 0
