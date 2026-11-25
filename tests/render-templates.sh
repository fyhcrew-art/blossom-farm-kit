#!/bin/bash
# Fills in the launchd and packet filter templates with the values
# install.sh uses on a Mac and writes the results into a folder, so that they
# can be checked with the tools of macOS:
#
#     bash tests/render-templates.sh /tmp/rendered
#     plutil -lint /tmp/rendered/*.plist
#     sudo pfctl -n -f /tmp/rendered/pf.rules
#
# Used by tools/check.sh. Changes nothing on the computer.

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"

OUT=${1:-}
if [ -z "$OUT" ]; then echo 'usage: render-templates.sh <output folder>' >&2; exit 2; fi
mkdir -p "$OUT" || exit 1
get_farm_paths /opt/farm
appium_env="        <key>APPIUM_HOME</key>
        <string>$FARM_ROOT/appium</string>
        <key>NPM_CONFIG_PREFIX</key>
        <string>$FARM_ROOT/npm</string>
"
failed=0
for name in mongodb hub provider gate keep-available restart cloudflared firewall; do
    if ! render_template "$KIT_ROOT/launchd/$(farm_label "$name").plist" "FARM_ROOT=$FARM_ROOT" "SERVICE_USER=$FARM_SERVICE_USER" \
        "SERVICE_GROUP=$FARM_SERVICE_GROUP" 'NICKNAME=Provider1' "PROVIDER_PATH=$FARM_ROOT/npm/bin:$FARM_TOOLS_DIR:$FARM_NODE_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "APPIUM_ENV_XML=$appium_env" > "$OUT/$(farm_label "$name").plist"; then
        echo "could not render $name" >&2; failed=1
    fi
done
render_template "$KIT_ROOT/launchd/pf.rules.template" 'PORT_FIRST=49152' 'PORT_LAST=65535' > "$OUT/pf.rules" || failed=1
get_cloudflared_config_text 00000000-0000-0000-0000-000000000000 "$FARM_TUNNEL_CREDENTIALS" farm-hub.yourdomain.com farm-provider.yourdomain.com farm-restart.yourdomain.com > "$OUT/config.yml" || failed=1
ls -l "$OUT"
exit "$failed"
