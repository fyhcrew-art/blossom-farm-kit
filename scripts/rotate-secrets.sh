#!/bin/bash
# Blossom farm kit - replaces secrets of the farm with new ones.
#
#     sudo bash scripts/rotate-secrets.sh --restart-secret
#     sudo bash scripts/rotate-secrets.sh --hub-user
#     sudo bash scripts/rotate-secrets.sh --admin-password
#     sudo bash scripts/rotate-secrets.sh --all
#
# When somebody who had Phone Farm access in Blossom leaves: run it with
# --hub-user (and --admin-password if that person knew it). See docs/security.md.
#
# On a computer that is paired with Blossom, the new hub password and the new
# restart secret are sent to Blossom by this script (with the computer's farm
# token) and are not shown. Without a pairing, or when Blossom cannot be
# reached, they are shown once, to be entered in Blossom (Farm setup -> Edit),
# and written to no log.
#   --restart-secret   New restart secret.
#   --hub-user         New random password for the hub user Blossom uses ("blossom").
#   --keep-available   New random password for the internal keep-available user (nothing to enter anywhere).
#   --admin-password   Change the password of the hub administrator ("admin"); you choose it.
#   --all              All of the above.

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"

HUB_URL='http://127.0.0.1:10000'
DO_RESTART=0; DO_HUB_USER=0; DO_KEEP=0; DO_ADMIN=0
NEW_HUB_PASSWORD=''; NEW_RESTART_SECRET=''; SENT_TO_BLOSSOM=0
for arg in "$@"; do
    case $arg in
        --restart-secret) DO_RESTART=1 ;;
        --hub-user) DO_HUB_USER=1 ;;
        --keep-available) DO_KEEP=1 ;;
        --admin-password) DO_ADMIN=1 ;;
        --all) DO_RESTART=1; DO_HUB_USER=1; DO_KEEP=1; DO_ADMIN=1 ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) stop_farm "Unknown option: $arg" 'Add --restart-secret, --hub-user, --keep-available, --admin-password or --all.' ;;
    esac
done

show_new() {
    trap - EXIT
    farm_http_cleanup
    if [ -z "$NEW_HUB_PASSWORD" ] && [ -z "$NEW_RESTART_SECRET" ]; then return 0; fi
    if [ "$SENT_TO_BLOSSOM" = 1 ]; then return 0; fi
    echo
    write_color "$FK_CYAN" '======================================================================'
    write_color "$FK_CYAN" ' Enter these in Blossom CRM -> Phone Farm -> Farm setup -> Edit'
    write_color "$FK_CYAN" '======================================================================'
    [ -n "$NEW_HUB_PASSWORD" ] && echo "   Hub user blossom, new hub password ... $NEW_HUB_PASSWORD"
    [ -n "$NEW_RESTART_SECRET" ] && echo "   New restart secret ................... $NEW_RESTART_SECRET"
    echo
    write_color "$FK_YELLOW" ' WARNING: shown ONCE and written to no log. Until you enter them in Blossom,'
    write_color "$FK_YELLOW" ' the site shows "Not reachable" there. The old values no longer work.'
    echo
}
# New values are shown whatever happens after they were made.
trap show_new EXIT

hub_call() {
    # hub_call <path> [method] [body]
    invoke_farm_http "$HUB_URL$1" --method "${2:-GET}" --body "${3:-}" --bearer "$ADMIN_TOKEN" --timeout 20
}

assert_macos_root
if [ "$DO_RESTART$DO_HUB_USER$DO_KEEP$DO_ADMIN" = 0000 ]; then
    stop_farm 'Nothing was chosen.' 'Add --restart-secret, --hub-user, --keep-available, --admin-password or --all.'
fi
get_farm_paths /opt/farm
read_farm_config
[ "$FARM_HAS_CONFIG" = 1 ] || stop_farm 'This Mac has no farm installation.' 'Run install.sh first.'

ADMIN_TOKEN=''; ADMIN_CURRENT=''
if [ "$DO_HUB_USER$DO_KEEP$DO_ADMIN" != 000 ]; then
    write_step 'Signing in to the hub as its administrator'
    read_secret_line 'Current password of the hub user "admin" (hidden)'
    ADMIN_CURRENT=$REPLY_SECRET; REPLY_SECRET=''
    connect_hub "$HUB_URL" admin "$ADMIN_CURRENT"
    ADMIN_TOKEN=$HUB_TOKEN
    if [ -z "$ADMIN_TOKEN" ]; then
        stop_farm 'The hub refused the administrator password.' 'Run the script again with the right password. If it is lost, see README, section Troubleshooting, "Lost hub administrator password".'
    fi
    write_ok 'Signed in.'
fi

if [ "$DO_HUB_USER" = 1 ]; then
    write_step 'New password for the hub user "blossom"'
    candidate=$(new_random_secret 32 base64url)
    body="{\"username\":\"blossom\",\"password\":$(json_string "$candidate"),\"role\":\"admin\",\"workspace_ids\":[]}"
    hub_call /admin/user PUT "$body"
    [ "$HTTP_STATUS" -eq 200 ] || hub_call /admin/user POST "$body"
    [ "$HTTP_STATUS" -eq 200 ] || stop_farm "The hub did not update the user \"blossom\" (HTTP $HTTP_STATUS)." 'Check the hub with scripts/status.sh and run the script again.'
    NEW_HUB_PASSWORD=$candidate; candidate=''; body=''
    write_ok 'Done. Sessions that were issued with the old password: see the note at the end.'
fi

if [ "$DO_KEEP" = 1 ]; then
    write_step 'New password for the internal user "farm-keepalive"'
    hub_call '/admin/workspaces?page=1&limit=100'
    ids=$(json_values "$HTTP_TEXT" 'result.workspaces.*.id' | awk 'NF')
    [ -n "$ids" ] || stop_farm 'The hub did not list its workspaces.' 'Check the hub with scripts/status.sh and run the script again.'
    ids_json=''
    for id in $ids; do ids_json="$ids_json,$(json_string "$id")"; done
    keep=$(new_random_secret 32 base64url)
    body="{\"username\":\"farm-keepalive\",\"password\":$(json_string "$keep"),\"role\":\"user\",\"workspace_ids\":[${ids_json#,}]}"
    hub_call /admin/user PUT "$body"
    [ "$HTTP_STATUS" -eq 200 ] || hub_call /admin/user POST "$body"
    [ "$HTTP_STATUS" -eq 200 ] || stop_farm "The hub did not update the user \"farm-keepalive\" (HTTP $HTTP_STATUS)." 'Run the script again.'
    write_secret_file "$FARM_KEEP_AVAILABLE" "{
  \"hubUrl\": $(json_string "$HUB_URL"),
  \"username\": \"farm-keepalive\",
  \"password\": $(json_string "$keep")
}" service
    keep=''; body=''
    launchctl kickstart -k "system/$(farm_label keep-available)" > /dev/null 2>&1
    write_ok 'Done, and the keep-available service was restarted. It now covers every workspace of the hub.'
fi

if [ "$DO_ADMIN" = 1 ]; then
    write_step 'New password for the hub administrator "admin"'
    write_note 'Rules: at least 14 characters, mixing three of lower case, upper case, digits, other characters.'
    read_farm_password 'New hub administrator password'
    hub_call /change-password POST "{\"current_password\":$(json_string "$ADMIN_CURRENT"),\"new_password\":$(json_string "$REPLY_SECRET")}"
    REPLY_SECRET=''
    [ "$HTTP_STATUS" -eq 200 ] || stop_farm "The hub did not change the administrator password (HTTP $HTTP_STATUS)." 'The new password must differ from the current one. Run the script again.'
    write_ok 'Done. Keep it in a password manager; it is stored nowhere on this Mac except inside the hub'"'"'s database.'
fi
ADMIN_CURRENT=''; ADMIN_TOKEN=''

if [ "$DO_RESTART" = 1 ]; then
    write_step 'New restart secret'
    NEW_RESTART_SECRET=$(new_random_secret 32 hex)
    [ "${#NEW_RESTART_SECRET}" -eq 64 ] || { NEW_RESTART_SECRET=''; stop_farm 'The random generator of this Mac gave no secret.' 'Run the script again.'; }
    write_secret_file "$FARM_RESTART_SECRET" "$NEW_RESTART_SECRET" private
    launchctl kickstart -k "system/$(farm_label restart)" > /dev/null 2>&1
    sleep 2
    if ! wait_tcp_port 19999 20; then write_warn 'The restart service did not come back. Read /opt/farm/logs/restart-server.log.'
    else write_ok 'Done, and the restart service was restarted with the new secret.'; fi
fi

# Paired with Blossom: the new values go there with this computer's farm
# token, and nobody has to copy them.
if [ -n "$NEW_HUB_PASSWORD" ] || [ -n "$NEW_RESTART_SECRET" ]; then
    read_farm_pairing
    if [ "$FARM_IS_PAIRED" = 1 ]; then
        write_step 'Blossom CRM'
        secret=''
        [ -f "$FARM_RESTART_SECRET" ] && secret=$(tr -d '[:space:]' < "$FARM_RESTART_SECRET")
        if pair_send_site "https://$FARM_CFG_HUB_HOST" "https://$FARM_CFG_PROVIDER_HOST" "$FARM_CFG_NICKNAME" "${FARM_CFG_HUB_USER:-blossom}" "$NEW_HUB_PASSWORD" "https://$FARM_CFG_RESTART_HOST" "$secret"; then
            SENT_TO_BLOSSOM=1
            write_ok "Blossom ($PAIR_ORIGIN) received the new values through the pairing of this computer. Nothing has to be entered there, and they are not shown here."
            [ "$PAIR_NEEDS_CONFIRMATION" = true ] && write_warn 'The site is waiting for an admin to confirm it in Blossom (Phone Farm -> Farm setup); until then Blossom does not use it.'
        else
            write_warn "The new values could not be sent to Blossom: $APP_MESSAGE"
            write_warn 'They are shown below instead: enter them in Blossom by hand.'
        fi
        secret=''
    fi
fi

show_new
if [ "$DO_HUB_USER" = 1 ] || [ "$DO_ADMIN" = 1 ]; then
    write_note 'About sessions already handed out: a browser that opened Phone Farm before the change holds a'
    write_note 'hub session token. In GADS 6.0.0 such a token stays valid until it expires, one hour after it'
    write_note 'was issued; a password change does not cancel it (docs/security.md). To cut every session'
    write_note 'at once, replace the signing key in the hub page (Admin -> Secret keys).'
fi
exit 0
