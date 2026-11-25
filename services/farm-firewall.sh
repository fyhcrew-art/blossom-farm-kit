#!/bin/bash
# Blossom farm kit - keeps other computers away from the per-phone ports.
#
# For every connected iPhone the GADS provider opens ports (WebDriverAgent,
# the screen stream) on ALL network addresses of the Mac, on numbers the
# system picks from its range for temporary ports, and none of them asks for
# a login. With Appium switched on, the Appium servers do the same. Everything
# the farm needs reaches these ports from the Mac itself.
#
# This script loads one rule into the packet filter of macOS (pf): new TCP
# connections that arrive from the network for a port of that range are
# dropped. Connections the Mac makes itself, everything on the loopback
# interface, and UDP (the live video is WebRTC over UDP) are not touched.
#
# The rule lives in an anchor of its own below "com.apple", which the
# standard /etc/pf.conf of macOS already evaluates; no system file is
# changed. It runs as root from launchd when the Mac starts and every five
# minutes after that, and puts the rule back if anything removed it.
#
#   farm-firewall.sh load     load the rule (default)
#   farm-firewall.sh unload   remove it
#
# bash 3.2 (the bash of macOS).

set -u
ANCHOR='com.apple/blossom-farm'
RULES=${FARM_PF_RULES:-/opt/farm/config/pf.rules}
PFCTL=/sbin/pfctl

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') [farm-firewall] $1"; }

case ${1:-load} in
    unload)
        "$PFCTL" -a "$ANCHOR" -F all > /dev/null 2>&1
        say 'rule removed'
        exit 0
        ;;
    load) ;;
    *) echo 'usage: farm-firewall.sh [load|unload]' >&2; exit 2 ;;
esac

if [ ! -f "$RULES" ]; then say "no rules file at $RULES; run install.sh"; exit 1; fi

# The main rule set of macOS must be loaded: it is what refers to the anchors
# below com.apple.
if ! "$PFCTL" -s rules 2> /dev/null | grep -q 'anchor "com.apple/\*"'; then
    "$PFCTL" -f /etc/pf.conf > /dev/null 2>&1
fi

wanted=$(grep -v '^[[:space:]]*#' "$RULES" | grep -c 'block')
loaded=$("$PFCTL" -a "$ANCHOR" -s rules 2> /dev/null | grep -c 'block')
changed=0
if [ "$loaded" -ne "$wanted" ] || [ "$wanted" -eq 0 ]; then
    if ! "$PFCTL" -a "$ANCHOR" -f "$RULES" 2> /dev/null; then say "pfctl did not accept $RULES"; exit 1; fi
    changed=1
fi
if ! "$PFCTL" -s info 2> /dev/null | grep -q 'Status: Enabled'; then
    "$PFCTL" -E > /dev/null 2>&1
    changed=1
fi
if ! "$PFCTL" -s rules 2> /dev/null | grep -q 'anchor "com.apple/\*"'; then
    say 'the pf rule set of this Mac does not evaluate "com.apple/*" anchors (is /etc/pf.conf changed?); the rule has no effect'
    exit 1
fi
[ "$changed" -eq 1 ] && say 'rule loaded and pf enabled'
exit 0
