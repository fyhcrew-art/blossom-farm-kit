#!/bin/bash
# Blossom farm kit - runs the same checks as "Test connection" in Blossom CRM,
# from this Mac, against the farm's public host names.
#
#     sudo bash scripts/self-test.sh
#     sudo bash scripts/self-test.sh --hub-user NAME
#
# Asks for the password of the hub user (hidden). Nothing is stored.
#   --hub-user NAME   Hub user to sign in with (default: the one Blossom uses, "blossom").

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"
trap farm_http_cleanup EXIT

HUB_USER=''
while [ $# -gt 0 ]; do
    case $1 in
        --hub-user=*) HUB_USER=${1#*=} ;;
        --hub-user) [ $# -ge 2 ] || stop_farm '--hub-user needs a name.' 'For example:  --hub-user blossom'; HUB_USER=$2; shift ;;
        -h | --help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) stop_farm "Unknown option: $1" 'Use --hub-user NAME, or no option.' ;;
    esac
    shift
done

assert_macos_root
get_farm_paths /opt/farm
read_farm_config
if [ "$FARM_HAS_CONFIG" = 0 ]; then
    stop_farm 'This Mac has no farm installation (/opt/farm/config/farm.json is missing).' 'Run install.sh first.'
fi
if [ ! -f "$FARM_RESTART_SECRET" ]; then
    stop_farm 'The restart secret file is missing.' 'Run scripts/rotate-secrets.sh --restart-secret, enter the new secret in Blossom, then test again.'
fi
[ -n "$HUB_USER" ] || HUB_USER=$FARM_CFG_HUB_USER
write_step "Self-test of $FARM_CFG_HUB_HOST, $FARM_CFG_PROVIDER_HOST, $FARM_CFG_RESTART_HOST"
read_secret_line "Password of the hub user \"$HUB_USER\" (hidden)"
password=$REPLY_SECRET; REPLY_SECRET=''
secret=$(tr -d '[:space:]' < "$FARM_RESTART_SECRET")
invoke_farm_self_test "$FARM_CFG_HUB_HOST" "$FARM_CFG_PROVIDER_HOST" "$FARM_CFG_RESTART_HOST" "$FARM_CFG_NICKNAME" "$HUB_USER" "$password" "$secret"
password=''; secret=''
write_self_test_report
echo
if [ "$SELFTEST_FAILED" = 0 ]; then
    write_ok 'Everything that can be checked from this Mac works. Now press "Test connection" in Blossom: that test runs from Blossom'"'"'s servers.'
    exit 0
fi
write_warn 'At least one step failed. Fix the first failed step and run the test again.'
exit 2
