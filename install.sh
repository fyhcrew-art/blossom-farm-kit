#!/bin/bash
# Blossom farm kit - sets up a phone-farm Mac from start to finish.
#
# Run in Terminal, inside the kit folder:
#
#     sudo bash install.sh
#
# The script can be run again at any time. It keeps what is already in place
# (programs, the tunnel, secrets, the database) and only fills in what is
# missing. See README.md for what each step does.
#
# The command Blossom CRM shows under Phone Farm -> Farm setup -> Connect a
# computer runs this script with --app-origin and --pairing-code: the farm is
# then connected to Blossom by the script itself, and nothing has to be
# copied by hand.
#
# Options:
#   --pairing-code CODE      The pairing code Blossom shows (five groups of four characters). It
#                            works once and for 30 minutes. Needs --app-origin.
#   --app-origin ADDRESS     The https address of Blossom, as in the command Blossom shows. The
#                            farm's credentials are sent there and nowhere else.
#   --domain NAME            Your domain at Cloudflare, for example yourdomain.com. The three host
#                            names become farm-hub., farm-provider. and farm-restart. under it.
#   --hub-host NAME          Public host name for the hub, for example farm-hub.yourdomain.com.
#   --provider-host NAME     Public host name for the provider, for example farm-provider.yourdomain.com.
#   --restart-host NAME      Public host name for the restart service, for example farm-restart.yourdomain.com.
#   --nickname NAME          The provider's nickname in the hub (default Provider1).
#   --tunnel-name NAME       Name of the Cloudflare tunnel to create (default blossom-farm).
#   --overwrite-dns          Replace DNS records that already exist for the three host names.
#   --reset-hub-user         Give the hub user "blossom" a new password even when the user exists.
#   --with-appium            Also install Appium and its iOS driver and let the provider start an
#                            Appium server per phone. No screen of Blossom CRM needs it (see README,
#                            "Appium: off unless you ask for it"). Once chosen it is remembered.
#   --provider-binary PATH   A GADS-drag program for this Mac that you already have, used instead of
#                            downloading it. Only accepted when its SHA-256 is the one pinned in
#                            versions.json.
#   --ffmpeg PATH            An FFmpeg program of your own (with the libx264 encoder), when there
#                            is none from Homebrew. It is copied into /opt/farm/bin/tools and used
#                            from there; later runs keep it.
#   --replace-pairing        Needed, together with a pairing code, when this Mac is already paired
#                            with another Blossom workspace and nobody is at the keyboard to say yes:
#                            the farm leaves that workspace for the one of the new command.
#   --skip-firewall-rules    Do not load the packet filter rule that keeps other computers on your
#                            network away from the ports the provider opens for each phone. Only for
#                            a Mac whose firewall is managed elsewhere (docs/security.md, section 1).
#   --skip-power-settings    Do not switch off sleep.
#   --skip-self-test         Do not run the connection test at the end.
#
# Written for the bash that macOS ships (3.2).

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"

HUB_HOST=''; PROVIDER_HOST=''; RESTART_HOST=''; NICKNAME=''; TUNNEL_NAME='blossom-farm'
OVERWRITE_DNS=0; RESET_HUB_USER=0; WITH_APPIUM=0; PROVIDER_BINARY=''; FFMPEG_OPTION=''
SKIP_FIREWALL=0; SKIP_POWER=0; SKIP_SELF_TEST=0; REPLACE_PAIRING=0
# The options as they were given, for the case that the kit moves itself to
# its protected folder and starts again from there (step 1).
ORIGINAL_ARGS=("$@")
PAIRING_CODE=''; APP_ORIGIN=''; DOMAIN=''

need_value() { [ $# -ge 2 ] || stop_farm "The option $1 needs a value." 'See the list of options at the top of install.sh.'; }
while [ $# -gt 0 ]; do
    case $1 in
        --pairing-code=*) PAIRING_CODE=${1#*=} ;;
        --pairing-code) need_value "$@"; PAIRING_CODE=$2; shift ;;
        --app-origin=*) APP_ORIGIN=${1#*=} ;;
        --app-origin) need_value "$@"; APP_ORIGIN=$2; shift ;;
        --domain=*) DOMAIN=${1#*=} ;;
        --domain) need_value "$@"; DOMAIN=$2; shift ;;
        --hub-host=*) HUB_HOST=${1#*=} ;;
        --hub-host) need_value "$@"; HUB_HOST=$2; shift ;;
        --provider-host=*) PROVIDER_HOST=${1#*=} ;;
        --provider-host) need_value "$@"; PROVIDER_HOST=$2; shift ;;
        --restart-host=*) RESTART_HOST=${1#*=} ;;
        --restart-host) need_value "$@"; RESTART_HOST=$2; shift ;;
        --nickname=*) NICKNAME=${1#*=} ;;
        --nickname) need_value "$@"; NICKNAME=$2; shift ;;
        --tunnel-name=*) TUNNEL_NAME=${1#*=} ;;
        --tunnel-name) need_value "$@"; TUNNEL_NAME=$2; shift ;;
        --provider-binary=*) PROVIDER_BINARY=${1#*=} ;;
        --provider-binary) need_value "$@"; PROVIDER_BINARY=$2; shift ;;
        --ffmpeg=*) FFMPEG_OPTION=${1#*=} ;;
        --ffmpeg) need_value "$@"; FFMPEG_OPTION=$2; shift ;;
        --overwrite-dns) OVERWRITE_DNS=1 ;;
        --reset-hub-user) RESET_HUB_USER=1 ;;
        --with-appium) WITH_APPIUM=1 ;;
        --skip-firewall-rules) SKIP_FIREWALL=1 ;;
        --skip-power-settings) SKIP_POWER=1 ;;
        --skip-self-test) SKIP_SELF_TEST=1 ;;
        --replace-pairing) REPLACE_PAIRING=1 ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) stop_farm "Unknown option: $1" 'See the list of options at the top of install.sh, or run:   bash install.sh --help' ;;
    esac
    shift
done

get_farm_paths /opt/farm
HUB_PORT=10000
PROVIDER_PORT=10001
GATE_PORT=10002
RESTART_PORT=19999
MONGO_PORT=27017
HUB_URL="http://127.0.0.1:$HUB_PORT"
HUB_USER_NAME='blossom'
KEEP_USER_NAME='farm-keepalive'
NPM_PREFIX=$FARM_ROOT/npm
APPIUM_HOME_DIR=$FARM_ROOT/appium

# Secrets created in this run. They are printed once at the very end - also
# when a later step fails, so that a value the hub already holds is not lost.
NEW_HUB_PASSWORD=''
NEW_RESTART_SECRET=''
HAVE_SUMMARY=0
VALUES_SHOWN=0
ADMIN_PASSWORD=''
ADMIN_TOKEN=''
# 1 once Blossom has accepted this computer (a pairing code claimed in this
# run, or a pairing from an earlier run that Blossom still knows).
PAIRING=0
# 1 once Blossom has accepted the description of the farm in this run: the
# values are then not printed for copying.
SENT_TO_BLOSSOM=0
ACTIVE_IN_BLOSSOM=0

# Farm services that were running when the script started. Whatever happens
# (an error, a wrong password, Ctrl+C), the ones this run stopped are started
# again at the end: a re-run must never leave a working farm switched off.
WAS_RUNNING=' '
# Set when this run stopped the tunnel on purpose because something was unsafe.
LEAVE_TUNNEL_STOPPED=0
EXIT_CODE=1

# shellcheck disable=SC2329  # called from finish, which runs as a trap
restore_farm_services() {
    local name back='' down=''
    for name in $(get_farm_start_order); do
        case $WAS_RUNNING in *" $name "*) ;; *) continue ;; esac
        if [ "$name" = cloudflared ] && [ "$LEAVE_TUNNEL_STOPPED" = 1 ]; then continue; fi
        [ -f "$(farm_plist_path "$name")" ] || continue
        farm_service_running "$name" && continue
        if start_farm_service "$name" 20; then back="$back $name"; else down="$down $name"; fi
    done
    [ -n "$back" ] && write_color "$FK_YELLOW" "Started again (they were running before this script):$back."
    if [ -n "$down" ]; then
        write_color "$FK_RED" "These services were running before and could NOT be started again:$down."
        write_color "$FK_RED" 'Run   sudo bash install.sh   again to the end, or restart the Mac.'
    fi
    case $WAS_RUNNING in *' cloudflared '*)
        [ "$LEAVE_TUNNEL_STOPPED" = 1 ] && write_color "$FK_RED" 'The tunnel (service blossom-farm.cloudflared) was stopped on purpose and is left stopped: see the message above.'
        ;;
    esac
    return 0
}

show_final_values() {
    [ "$HAVE_SUMMARY" = 1 ] || return 0
    VALUES_SHOWN=1
    if [ "$SENT_TO_BLOSSOM" = 1 ]; then
        echo
        write_color "$FK_CYAN" '======================================================================'
        write_color "$FK_CYAN" ' Blossom CRM has this farm: nothing to copy'
        write_color "$FK_CYAN" '======================================================================'
        echo "   Sent to ................ $PAIR_ORIGIN${PAIR_WORKSPACE:+ (workspace \"$PAIR_WORKSPACE\")}"
        echo "   Hub address ............ https://$HUB_HOST"
        echo "   Provider address ....... https://$PROVIDER_HOST"
        echo "   Provider nickname ...... $NICKNAME"
        echo "   Hub user ............... $HUB_USER_NAME (Blossom has its password; it is not shown here)"
        echo "   Restart service address  https://$RESTART_HOST (Blossom has its secret; it is not shown here)"
        echo
        if [ "$ACTIVE_IN_BLOSSOM" = 1 ]; then
            write_color "$FK_YELLOW" ' The site is confirmed and active in Blossom. New passwords made later by'
            write_color "$FK_YELLOW" ' scripts/rotate-secrets.sh reach Blossom the same way. To see the pairing:'
            write_color "$FK_YELLOW" ' scripts/status.sh.'
        else
            write_color "$FK_YELLOW" ' The site becomes active when an admin has confirmed it in Blossom (Phone Farm'
            write_color "$FK_YELLOW" ' -> Farm setup). New passwords made later by scripts/rotate-secrets.sh reach'
            write_color "$FK_YELLOW" ' Blossom the same way. To see the pairing: scripts/status.sh.'
        fi
        echo
        return 0
    fi
    echo
    write_color "$FK_CYAN" '======================================================================'
    write_color "$FK_CYAN" ' Enter these in Blossom CRM -> Phone Farm -> Farm setup (the address form)'
    write_color "$FK_CYAN" '======================================================================'
    echo "   Hub address ............ https://$HUB_HOST"
    echo "   Provider address ....... https://$PROVIDER_HOST"
    echo "   Provider nickname ...... $NICKNAME"
    echo "   Hub user ............... $HUB_USER_NAME"
    if [ -n "$NEW_HUB_PASSWORD" ]; then echo "   Hub password ........... $NEW_HUB_PASSWORD"
    else echo '   Hub password ........... (unchanged - the one made earlier)'; fi
    echo "   Restart service address  https://$RESTART_HOST"
    if [ -n "$NEW_RESTART_SECRET" ]; then echo "   Restart secret ......... $NEW_RESTART_SECRET"
    else echo '   Restart secret ......... (unchanged - the one made earlier)'; fi
    echo
    if [ -n "$NEW_HUB_PASSWORD" ] || [ -n "$NEW_RESTART_SECRET" ]; then
        write_color "$FK_YELLOW" ' WARNING: the password and the secret above are shown ONCE.'
        write_color "$FK_YELLOW" ' Copy them into Blossom now (or into a password manager), then close this'
        write_color "$FK_YELLOW" ' window. They are not written to any log. Whoever has them controls your'
        write_color "$FK_YELLOW" ' phones. Lost them? scripts/rotate-secrets.sh makes new ones.'
    else
        write_color "$FK_YELLOW" ' Nothing secret was changed in this run. Lost a value? scripts/rotate-secrets.sh'
        write_color "$FK_YELLOW" ' makes new ones.'
    fi
    write_color "$FK_YELLOW" ' The form is behind "Connect a farm"; where Blossom offers "Connect a'
    write_color "$FK_YELLOW" ' computer", it is behind "Advanced: enter the addresses yourself", and'
    write_color "$FK_YELLOW" ' "Connect a computer" itself shows one command that does this without'
    write_color "$FK_YELLOW" ' copying; it keeps a farm that is already installed.'
    echo
}

set_hub_user_password() {
    # Gives the hub user Blossom signs in with a new random password. Sets
    # NEW_HUB_PASSWORD when the hub accepted it; status 1 otherwise.
    local candidate body
    candidate=$(new_random_secret 32 base64url)
    body="{\"username\":$(json_string "$HUB_USER_NAME"),\"password\":$(json_string "$candidate"),\"role\":\"admin\",\"workspace_ids\":[]}"
    hub_admin /admin/user PUT "$body"
    body=''
    [ "$HTTP_STATUS" -eq 200 ] || return 1
    NEW_HUB_PASSWORD=$candidate
    return 0
}

send_farm_to_blossom() {
    # The description of this farm, to the Blossom this computer is paired
    # with. The hub password goes along only when this run made one; the
    # restart secret is read from its file.
    local secret
    secret=$(tr -d '[:space:]' < "$FARM_RESTART_SECRET")
    pair_send_site "https://$HUB_HOST" "https://$PROVIDER_HOST" "$NICKNAME" "$HUB_USER_NAME" "$NEW_HUB_PASSWORD" "https://$RESTART_HOST" "$secret"
}

# shellcheck disable=SC2329  # runs as a trap
finish() {
    # Also reached after Ctrl+C and after stop_farm. Never leave a farm that
    # was working switched off, and never lose a secret that was created.
    trap - EXIT INT TERM HUP
    if [ "$EXIT_CODE" != 0 ] && [ "$VALUES_SHOWN" = 0 ] && { [ -n "$NEW_HUB_PASSWORD" ] || [ -n "$NEW_RESTART_SECRET" ]; }; then
        write_color "$FK_YELLOW" 'The script stopped, but it had already created new secrets. They are shown'
        write_color "$FK_YELLOW" 'below so that they are not lost. Running install.sh again keeps them.'
        if [ "$HAVE_SUMMARY" = 1 ]; then
            show_final_values
        else
            [ -n "$NEW_HUB_PASSWORD" ] && echo "   Hub user $HUB_USER_NAME, hub password: $NEW_HUB_PASSWORD"
            [ -n "$NEW_RESTART_SECRET" ] && echo "   Restart secret: $NEW_RESTART_SECRET"
            echo
        fi
    fi
    restore_farm_services
    farm_http_cleanup
    exit "$EXIT_CODE"
}
trap finish EXIT
trap 'echo; EXIT_CODE=130; exit 130' INT TERM HUP

read_hostname() {
    # read_hostname <prompt> <current> <example>   sets REPLY_HOST
    local prompt=$1 current=$2 example=$3 shown answer reason
    while true; do
        shown=$example
        [ -n "$current" ] && shown=$current
        if ! IFS= read -r -p "$prompt [$shown]: " answer < /dev/tty; then
            echo
            stop_farm 'Nothing could be read from the keyboard.' 'Run the script in a Terminal window, or give the three names with --hub-host, --provider-host and --restart-host.'
        fi
        [ -z "$answer" ] && [ -n "$current" ] && answer=$current
        answer=$(to_lower "$(trim_text "$answer")")
        answer=${answer#https://}
        while [ "$answer" != "${answer%/}" ]; do answer=${answer%/}; done
        reason=$(test_farm_hostname "$answer")
        if [ -z "$reason" ]; then REPLY_HOST=$answer; return 0; fi
        write_warn "$reason"
    done
}

hub_admin() {
    # hub_admin <path> [method] [body]
    # A call to the local hub with the admin token; stops with a clear message
    # when the hub does not answer.
    invoke_farm_http "$HUB_URL$1" --method "${2:-GET}" --body "${3:-}" --bearer "$ADMIN_TOKEN" --timeout 20
    if [ "$HTTP_STATUS" -eq 0 ]; then
        stop_farm "The GADS hub stopped answering ($HTTP_ERROR)." 'Read the end of /opt/farm/logs/hub.log, run scripts/status.sh, then run install.sh again.'
    fi
}

as_service() {
    # Runs a command as the farm's service account, with its environment.
    (cd "$FARM_VAR/home" && sudo -u "$FARM_SERVICE_USER" env "HOME=$FARM_VAR/home" "TMPDIR=$FARM_VAR/tmp" \
        "PATH=$NPM_PREFIX/bin:$FARM_NODE_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "APPIUM_HOME=$APPIUM_HOME_DIR" "NPM_CONFIG_PREFIX=$NPM_PREFIX" "$@")
}

find_brew() {
    local c
    for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$c" ]; then echo "$c"; return 0; fi
    done
    return 0
}

find_ffmpeg() {
    # The FFmpeg to use: the one named with --ffmpeg; else the one an earlier
    # run put into /opt/farm/bin/tools (a copy, or a link that still leads
    # to a program); else Homebrew's.
    local c
    for c in "$FFMPEG_OPTION" "$FARM_TOOLS_DIR/ffmpeg" /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
        if [ -n "$c" ] && [ -x "$c" ] && [ ! -d "$c" ]; then echo "$c"; return 0; fi
    done
    return 0
}

brew_install() {
    # brew_install <formula>   Homebrew refuses to run as root: it runs as the
    # person who called sudo. Status 1 when that is not possible or it fails.
    [ -n "$BREW" ] && [ -n "$RUN_USER" ] || return 1
    write_note "Installing $1 with Homebrew (as $RUN_USER)..."
    (cd /tmp && sudo -u "$RUN_USER" -H "$BREW" install "$1")
}

PROVIDER_PATH=''
APPIUM_ENV_XML=''

echo
write_color "$FK_CYAN" 'Blossom farm kit - installer (macOS)'
echo 'Safe to run again: it keeps what is already set up.'

# ----------------------------------------------------------------------
write_step '1/12  Checking this Mac'
# ----------------------------------------------------------------------
assert_macos_root
# The kit runs with full rights now and at every later maintenance run: it
# works from a folder only root can change (lib/farmkit.sh, "the kit folder").
use_protected_kit_folder install.sh ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
get_farm_arch
if [ -n "$PAIRING_CODE" ] || [ -n "$APP_ORIGIN" ]; then
    # A slip in the command is cheaper to find now than after the installation.
    if [ -z "$PAIRING_CODE" ] || [ -z "$APP_ORIGIN" ]; then
        stop_farm 'The options --pairing-code and --app-origin belong together, and one of them is missing.' 'Copy the whole command from Blossom (Phone Farm -> Farm setup -> Connect a computer) and run it again. To install without pairing, leave both out: the values to enter in Blossom are then shown at the end.'
    fi
    reason=$(test_app_origin "$APP_ORIGIN")
    [ -z "$reason" ] || stop_farm "--app-origin: $reason" 'Copy the whole command from Blossom (Phone Farm -> Farm setup -> Connect a computer) and run it again.'
    reason=$(test_pairing_code "$PAIRING_CODE")
    [ -z "$reason" ] || stop_farm "--pairing-code: $reason" 'Copy the whole command from Blossom (Phone Farm -> Farm setup -> Connect a computer) and run it again.'
fi
if [ -n "$DOMAIN" ]; then
    reason=$(test_farm_domain "$DOMAIN")
    [ -z "$reason" ] || stop_farm "--domain: $reason" 'Give the domain you added to Cloudflare, for example   --domain yourdomain.com'
fi
RUN_USER=${SUDO_USER:-}
[ "$RUN_USER" = root ] && RUN_USER=''
for needed in versions.json lib/json.awk services/restart-server.js services/provider-gate.js services/keep-available.sh \
    services/farm-run.sh services/farm-firewall.sh launchd/pf.rules.template \
    launchd/blossom-farm.mongodb.plist launchd/blossom-farm.hub.plist launchd/blossom-farm.provider.plist \
    launchd/blossom-farm.gate.plist launchd/blossom-farm.keep-available.plist launchd/blossom-farm.restart.plist \
    launchd/blossom-farm.cloudflared.plist launchd/blossom-farm.firewall.plist; do
    if [ ! -f "$KIT_ROOT/$needed" ]; then
        stop_farm "The kit is incomplete: $needed is missing." 'Download the complete kit again and run install.sh from inside the unpacked folder.'
    fi
done
# A kit downloaded with a browser carries the "quarantine" mark of macOS.
xattr -dr com.apple.quarantine "$KIT_ROOT" > /dev/null 2>&1
read_kit_versions "$KIT_ROOT"
MACOS_VERSION=$(sw_vers -productVersion 2> /dev/null)
MIN_MACOS=$(kit_version "macos.$FARM_ARCH.minimumMacOS")
if [ -z "$MIN_MACOS" ]; then
    stop_farm 'versions.json of the kit has no macOS entries.' 'Download the newest kit from its releases page.'
fi
if ! version_at_least "$MACOS_VERSION" "$MIN_MACOS"; then
    stop_farm "macOS $MACOS_VERSION is too old." "The farm programs this kit installs on this kind of Mac need macOS $MIN_MACOS or later. Update macOS (System Settings > General > Software Update), then run install.sh again."
fi
FREE_KB=$(df -Pk / | awk 'NR == 2 { print $4 }')
case $FREE_KB in '' | *[!0-9]*) FREE_KB=0 ;; esac
if [ "$FREE_KB" -lt 10485760 ]; then
    stop_farm "Only $((FREE_KB / 1048576)) GB free on the startup disk." 'Free at least 10 GB (the programs, the database and the logs need room), then run the script again.'
fi
for name in $(get_farm_service_names); do
    farm_service_alive "$name" && WAS_RUNNING="$WAS_RUNNING$name "
done
write_ok "macOS $MACOS_VERSION, $FARM_ARCH, $((FREE_KB / 1048576)) GB free, running as root."
if [ -z "$RUN_USER" ]; then
    write_warn 'The script was not started with sudo from a normal user account. Homebrew cannot be used from here: FFmpeg must already be installed (step 3).'
fi

# ----------------------------------------------------------------------
write_step '2/12  Folders and the service account'
# ----------------------------------------------------------------------
# Before anything in /opt/farm is read or run: a folder of that name that
# this kit did not create and lock is not adopted. Everything under it
# (secrets, pairing records of the phones, the tunnel credentials, logs) is
# for root and the farm's own service account only.
initialize_farm_root "$FARM_ROOT"
read_farm_config

if [ -z "$NICKNAME" ]; then
    NICKNAME='Provider1'
    [ -n "$FARM_CFG_NICKNAME" ] && NICKNAME=$FARM_CFG_NICKNAME
fi
[ "$FARM_CFG_WITH_APPIUM" = true ] && WITH_APPIUM=1
reason=$(test_provider_nickname "$NICKNAME")
[ -n "$reason" ] && stop_farm "The provider nickname \"$NICKNAME\" cannot be used." "$reason"

ensure_service_account
ensure_farm_layout "$NICKNAME"
copy_service_files
if ! { cp -f "$KIT_ROOT/versions.json" "$FARM_CONFIG/versions.json" && chown 0:0 "$FARM_CONFIG/versions.json" && chmod 600 "$FARM_CONFIG/versions.json"; }; then
    stop_farm "Could not write to $FARM_CONFIG." 'Run install.sh again with sudo.'
fi
write_ok "$FARM_ROOT is ready: root owns it, the service account $FARM_SERVICE_USER may read it, nobody else may open it."

# Pairing with Blossom starts here, before the long steps: the code is used
# within its 30 minutes, Blossom shows "Computer connected" while the rest
# runs, and a code that does not work is known now and not at the end. Only
# the code and the name of this computer are sent at this point; the farm's
# addresses and credentials follow at the very end, with the farm token.
read_farm_pairing
if [ -n "$PAIRING_CODE" ]; then
    write_note "Telling Blossom ($(normalize_app_origin "$APP_ORIGIN")) about this computer..."
    FK_REPLACE_PAIRING=$REPLACE_PAIRING
    if pair_claim "$APP_ORIGIN" "$PAIRING_CODE"; then
        PAIRING=1
        read_farm_pairing
        write_ok "Blossom knows this computer now${PAIR_WORKSPACE:+ (workspace \"$PAIR_WORKSPACE\")}. The farm is sent to it when the installation has finished."
    elif [ "$APP_KIND" = declined ]; then
        # Not a failure to work around: the person at the keyboard (or nobody)
        # did not agree to move the farm to another workspace.
        stop_farm 'The pairing of this computer was not changed.' "$APP_MESSAGE Nothing about the farm, its passwords or its pairing was changed in this run. If you did not get this command from your own Blossom yourself, do not run it again."
    else
        write_warn "Pairing with Blossom did not work: $APP_MESSAGE"
        write_warn "The installation continues. At the end the values are shown for you to enter in Blossom by hand; or get a new command there and run it afterwards. $FK_PAIR_HELP"
    fi
    PAIRING_CODE=''
elif [ "$FARM_IS_PAIRED" = 1 ]; then
    if pair_get_status; then
        case $PAIR_STATE in
            rejected | expired) write_warn "This computer was paired with Blossom, but the pairing was declined or ran out. The values are shown at the end for manual entry. $FK_PAIR_HELP" ;;
            *) PAIRING=1; write_ok "This computer is paired with Blossom ($PAIR_ORIGIN${PAIR_WORKSPACE:+, workspace \"$PAIR_WORKSPACE\"}). What changes in this run is sent there at the end." ;;
        esac
    elif [ "$APP_KIND" = refused ]; then
        write_warn "This computer was paired with Blossom ($PAIR_ORIGIN), but: $APP_MESSAGE The values are shown at the end for manual entry. $FK_PAIR_HELP"
    else
        PAIRING=1
        write_warn "Blossom could not be asked about the pairing of this computer right now ($APP_MESSAGE). It is tried again at the end."
    fi
fi

# ----------------------------------------------------------------------
write_step '3/12  Programs (pinned versions, checksums verified)'
# ----------------------------------------------------------------------
install_archive_program "$FARM_NODE_DIR" bin/node "$(kit_version "macos.$FARM_ARCH.node.url")" "$(kit_version "macos.$FARM_ARCH.node.sha256")" \
    "Node.js $(kit_version macos.node) (runs the restart service and the provider gate)"
install_archive_program "$FARM_MONGO_DIR" bin/mongod "$(kit_version "macos.$FARM_ARCH.mongodb.url")" "$(kit_version "macos.$FARM_ARCH.mongodb.sha256")" \
    "MongoDB $(kit_version macos.mongodb) (the database GADS uses)"

if [ -x "$FARM_CLOUDFLARED_EXE" ]; then
    write_ok "cloudflared (the tunnel) is already installed ($FARM_CLOUDFLARED_EXE)"
else
    write_note "Installing cloudflared $(kit_version macos.cloudflared) (the tunnel)..."
    archive=$FARM_DOWNLOADS/cloudflared.tgz
    get_verified_download "$(kit_version "macos.$FARM_ARCH.cloudflared.url")" "$(kit_version "macos.$FARM_ARCH.cloudflared.sha256")" "$archive" "cloudflared $(kit_version macos.cloudflared)"
    unpack=$FARM_DOWNLOADS/cloudflared-unpack
    rm -rf "$unpack"; mkdir "$unpack"
    # Cloudflare publishes the checksum of the program inside the archive.
    if ! tar -xzf "$archive" -C "$unpack" --no-same-owner 2> /dev/null || [ ! -f "$unpack/cloudflared" ] ||
        [ "$(get_file_sha256 "$unpack/cloudflared")" != "$(to_lower "$(kit_version "macos.$FARM_ARCH.cloudflared.exeSha256")")" ]; then
        rm -rf "$unpack"
        stop_farm 'cloudflared inside the downloaded archive does not have the expected SHA-256.' 'Do not use it. Delete /opt/farm/downloads and run install.sh again; if it repeats, report it on the kit repository.'
    fi
    install_one_file "$unpack/cloudflared" "$FARM_CLOUDFLARED_EXE"
    rm -rf "$unpack" "$archive"
    write_ok "cloudflared installed ($FARM_CLOUDFLARED_EXE), SHA-256 verified."
fi

# FFmpeg has no publisher's build for macOS; Homebrew is where it comes from.
BREW=$(find_brew)
if [ -n "$FFMPEG_OPTION" ] && { [ ! -f "$FFMPEG_OPTION" ] || [ ! -x "$FFMPEG_OPTION" ]; }; then
    stop_farm "--ffmpeg: $FFMPEG_OPTION is not a program." 'Give the full path of the FFmpeg program itself (the file called ffmpeg), or leave --ffmpeg out to use the one from Homebrew.'
fi
FFMPEG=$(find_ffmpeg)
if [ -z "$FFMPEG" ]; then
    if ! brew_install "$(kit_version macos.homebrew.ffmpeg)"; then
        stop_farm 'FFmpeg was not found, and Homebrew is not available to install it.' 'The provider encodes the live video with FFmpeg. Install Homebrew as your normal user (https://brew.sh shows the one command; it also installs Apple'"'"'s Command Line Tools), then run   sudo bash install.sh   again: it installs FFmpeg with it. If you have an FFmpeg program of your own that includes the libx264 encoder, name it:   sudo bash install.sh --ffmpeg /path/to/ffmpeg'
    fi
    FFMPEG=$(find_ffmpeg)
    [ -n "$FFMPEG" ] || stop_farm 'Homebrew ran, but FFmpeg is still not in /opt/homebrew/bin or /usr/local/bin.' 'Read Homebrew'"'"'s own message above, run   brew install ffmpeg   yourself as your normal user, then run install.sh again.'
fi
# The provider finds FFmpeg at one place in a folder root owns, not through
# the whole Homebrew folder. Homebrew's FFmpeg is linked there (it needs its
# libraries next to it, and "brew upgrade" keeps it current). A program named
# with --ffmpeg is COPIED there: the farm's service account cannot open a
# home folder, and a later run without the option must still find it.
ffmpeg_place=$FARM_TOOLS_DIR/ffmpeg
case $FFMPEG in
    "$ffmpeg_place") ffmpeg_shown="$ffmpeg_place, from an earlier run" ;;
    /opt/homebrew/bin/ffmpeg | /usr/local/bin/ffmpeg)
        ln -sfn "$FFMPEG" "$ffmpeg_place" || stop_farm "Could not create $ffmpeg_place." 'Run install.sh again with sudo.'
        ffmpeg_shown=$FFMPEG ;;
    *)
        install_one_file "$FFMPEG" "$ffmpeg_place"
        ffmpeg_shown="$ffmpeg_place, a copy of $FFMPEG" ;;
esac
if ! as_service "$ffmpeg_place" -version > /dev/null 2>&1; then
    write_warn "The farm's service account cannot run FFmpeg ($ffmpeg_shown). Without it the Control page shows no picture. If it is a program of your own: it must be built for this Mac's processor ($FARM_ARCH) and be one file that needs nothing next to it (a static build); name it again with   sudo bash install.sh --ffmpeg /path/to/ffmpeg   . If it is Homebrew's:   brew reinstall ffmpeg   as your normal user, then run install.sh again."
elif as_service "$ffmpeg_place" -hide_banner -encoders 2> /dev/null | grep -q libx264; then
    write_ok "FFmpeg with the libx264 encoder ($ffmpeg_shown; the provider encodes the live video with it)."
else
    write_warn "FFmpeg ($ffmpeg_shown) runs, but did not list the libx264 encoder when asked. Without it the Control page shows no picture. Homebrew's FFmpeg includes it:   brew install ffmpeg"
fi

if [ "$FARM_ARCH" = arm64 ]; then
    # GADS 6.0.0 signs WebDriverAgent with a helper (zsign) that it carries
    # inside the hub, and that helper loads OpenSSL from Homebrew's folder.
    if [ ! -f /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib ]; then
        brew_install "$(kit_version macos.homebrew.openssl)" || true
    fi
    if [ -f /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib ]; then
        write_ok 'OpenSSL 3 from Homebrew is present (the hub page needs it to sign WebDriverAgent).'
    else
        write_warn 'OpenSSL 3 from Homebrew (/opt/homebrew/opt/openssl@3) was not found. "Sign and upload" for WebDriverAgent in the hub page will not work until it is there:   brew install openssl@3   (docs/phones.md, section 0). The rest of the setup continues.'
    fi
else
    write_note 'On an Intel Mac the hub page cannot sign WebDriverAgent (GADS 6.0.0 carries its signing helper for Apple Silicon only). Sign it with zsign instead: docs/phones.md, "Signing outside the hub".'
fi

if [ "$WITH_APPIUM" = 1 ]; then
    # Installed under /opt/farm and by the service account, not by root: the
    # install scripts of several hundred npm packages run here.
    _fk_make_dir "$NPM_PREFIX" service-write
    _fk_make_dir "$APPIUM_HOME_DIR" service-write
    NPM="$FARM_NODE_DIR/bin/npm"
    APPIUM="$NPM_PREFIX/bin/appium"
    [ -x "$NPM" ] || stop_farm 'npm was not found next to node.' 'Delete /opt/farm/bin/node and run install.sh --with-appium again: it installs Node.js anew.'
    if [ ! -x "$APPIUM" ]; then
        write_note "Installing Appium $(kit_version npm.appium) (a few minutes)..."
        run_native as_service "$NPM" install --global --prefix "$NPM_PREFIX" --no-fund "appium@$(kit_version npm.appium)"
        if [ "$RUN_CODE" -ne 0 ] || [ ! -x "$APPIUM" ]; then
            stop_farm "npm could not install Appium: $(printf '%s\n' "$RUN_OUTPUT" | last_lines 3)" 'Check the internet connection and run install.sh --with-appium again. To continue without Appium, delete /opt/farm/npm and run install.sh without --with-appium.'
        fi
    fi
    if [ ! -d "$APPIUM_HOME_DIR/node_modules/appium-xcuitest-driver" ]; then
        write_note "Installing the Appium XCUITest driver $(kit_version npm.xcuitestDriver)..."
        run_native as_service "$APPIUM" driver install --source=npm "appium-xcuitest-driver@$(kit_version npm.xcuitestDriver)"
        if [ "$RUN_CODE" -ne 0 ]; then
            stop_farm "Appium could not install its iOS driver: $(printf '%s\n' "$RUN_OUTPUT" | last_lines 3)" 'Run install.sh --with-appium again. If it repeats, report the text above on the kit repository.'
        fi
    fi
    # The GADS provider installs its own Appium plugin (appium-gads) when it
    # starts and does not find it. Installing the version this GADS expects
    # here means the service finds it in place and fetches nothing by itself.
    PLUGIN=$(kit_version npm.gadsPlugin)
    run_native as_service "$NPM" list --global --prefix "$NPM_PREFIX" --depth=0 appium-gads
    case $RUN_OUTPUT in
        *"appium-gads@$PLUGIN"*) ;;
        *)
            write_note "Installing the GADS Appium plugin $PLUGIN..."
            run_native as_service "$NPM" install --global --prefix "$NPM_PREFIX" --no-fund "appium-gads@$PLUGIN"
            if [ "$RUN_CODE" -ne 0 ]; then
                stop_farm "npm could not install the GADS Appium plugin: $(printf '%s\n' "$RUN_OUTPUT" | last_lines 3)" 'Check the internet connection and run install.sh --with-appium again.'
            fi
            ;;
    esac
    run_native as_service "$APPIUM" plugin list --installed
    case $RUN_OUTPUT in
        *gads*) ;;
        *)
            run_native as_service "$APPIUM" plugin install --source=npm "appium-gads@$PLUGIN"
            [ "$RUN_CODE" -ne 0 ] && write_warn "Appium could not install the GADS plugin now ($(printf '%s\n' "$RUN_OUTPUT" | last_lines 2)). The provider will try again by itself when it starts."
            ;;
    esac
    write_ok "Appium $(kit_version npm.appium) with the XCUITest driver and the GADS plugin $PLUGIN is installed under /opt/farm."
    write_note 'Only the versions of these three packages are pinned. The packages they depend on are chosen by npm on the day of installation and are not checksum-pinned by this kit (docs/security.md, section 8).'
fi

if [ -S /var/run/usbmuxd ]; then
    write_ok "Apple's USB support for iPhones is part of macOS and is running (usbmuxd)."
else
    write_warn "Apple's USB support for iPhones (/var/run/usbmuxd) was not found. It is part of macOS; restart the Mac before plugging in phones. The rest of the setup continues."
fi

# ----------------------------------------------------------------------
write_step '4/12  GADS (hub from its publisher, patched provider from this kit'"'"'s release)'
# ----------------------------------------------------------------------
GADS_VERSION=$(kit_version gads.version)
DRAG_VERSION=$(kit_version gadsDrag.version)
HUB_HASH=$(to_lower "$(kit_version "macos.$FARM_ARCH.hub.exeSha256")")
PROVIDER_HASH=$(to_lower "$(kit_version "macos.$FARM_ARCH.provider.sha256")")
if [ -f "$FARM_HUB_EXE" ] && [ "$(get_file_sha256 "$FARM_HUB_EXE")" = "$HUB_HASH" ]; then
    :
else
    hub_zip=$FARM_DOWNLOADS/gads-mac.zip
    get_verified_download "$(kit_version "macos.$FARM_ARCH.hub.zipUrl")" "$(kit_version "macos.$FARM_ARCH.hub.zipSha256")" "$hub_zip" "GADS $GADS_VERSION for macOS (from github.com/shamanec/GADS)"
    unpack=$FARM_DOWNLOADS/gads-mac
    rm -rf "$unpack"; mkdir "$unpack"
    if ! unzip -q -o "$hub_zip" -d "$unpack" || [ ! -f "$unpack/GADS" ] || [ "$(get_file_sha256 "$unpack/GADS")" != "$HUB_HASH" ]; then
        rm -rf "$unpack"
        stop_farm 'GADS inside the downloaded archive does not have the expected SHA-256.' 'Do not use it. Delete /opt/farm/downloads and run install.sh again; if it repeats, report it on the kit repository.'
    fi
    stop_farm_service hub
    install_one_file "$unpack/GADS" "$FARM_HUB_EXE"
    rm -rf "$unpack" "$hub_zip"
fi
write_ok "GADS hub $GADS_VERSION in place, SHA-256 verified."
if [ -f "$FARM_PROVIDER_EXE" ] && [ "$(get_file_sha256 "$FARM_PROVIDER_EXE")" = "$PROVIDER_HASH" ]; then
    :
else
    tmp_provider=$FARM_DOWNLOADS/GADS-drag
    if [ -n "$PROVIDER_BINARY" ]; then
        # A file the customer brings is held to the same pinned checksum.
        [ -f "$PROVIDER_BINARY" ] || stop_farm "--provider-binary: file not found: $PROVIDER_BINARY" 'Give the full path of the GADS-drag program, or leave --provider-binary out to download it.'
        if [ "$(get_file_sha256 "$PROVIDER_BINARY")" != "$PROVIDER_HASH" ]; then
            stop_farm "--provider-binary: the file does not have the SHA-256 this kit pins for the provider $DRAG_VERSION on this kind of Mac ($PROVIDER_HASH)." "Use the GADS-drag program of exactly this version and for this processor (from the kit's gads-v... release, or built as patch/README.md describes), or leave --provider-binary out."
        fi
        cp -f "$PROVIDER_BINARY" "$tmp_provider" || stop_farm "Could not copy $PROVIDER_BINARY." 'Check the free space on the disk.'
    fi
    get_verified_download "$(kit_version "macos.$FARM_ARCH.provider.url")" "$PROVIDER_HASH" "$tmp_provider" "the patched GADS provider $DRAG_VERSION"
    stop_farm_service provider
    install_one_file "$tmp_provider" "$FARM_PROVIDER_EXE"
    rm -f "$tmp_provider"
fi
write_ok "GADS provider $DRAG_VERSION in place, SHA-256 verified."

# ----------------------------------------------------------------------
write_step '5/12  MongoDB'
# ----------------------------------------------------------------------
ensure_mongodb_service
# GADS keeps its users and passwords in MongoDB without encryption, and this
# MongoDB has no login: it must not listen on the network.
get_farm_listeners
exposed=$(printf '%s\n' "$FARM_LISTENERS" | awk -F '\t' -v p="$MONGO_PORT" '$4 == p && $3 !~ /^127\./ && $3 != "::1" { print $3; exit }')
if [ -n "$exposed" ]; then
    stop_farm "MongoDB listens on $exposed, not only on this Mac. Its data (hub passwords included) would be readable from the network." "Something else than the kit's MongoDB answers on port $MONGO_PORT. Stop it and run install.sh again."
fi
write_ok "MongoDB is running and listens on this Mac only (127.0.0.1:$MONGO_PORT)."

# ----------------------------------------------------------------------
write_step '6/12  GADS hub service and its administrator password'
# ----------------------------------------------------------------------
# On a re-run the hub is left running when nothing about it changed.
render_service hub "$FARM_HUB_EXE"
if ! start_farm_service hub 40 || ! wait_tcp_port "$HUB_PORT" 90; then
    stop_farm 'The GADS hub does not start.' 'Read the end of /opt/farm/logs/hub.log. If it says the port is in use, another program occupies port 10000: stop it, then run install.sh again.'
fi
write_ok "The hub is running on this Mac only ($HUB_URL)."

# GADS creates its administrator as "admin" with a published default
# password. Nothing is opened to the internet while that is still valid.
# This literal is GADS' own published default (its hub prints it at start).
# It is only used here to detect and replace it; the kit never sets it.
DEFAULT_PASSWORD='password'
connect_hub "$HUB_URL" admin "$DEFAULT_PASSWORD"
ADMIN_TOKEN=$HUB_TOKEN
if [ -n "$ADMIN_TOKEN" ]; then
    if farm_service_loaded cloudflared; then
        LEAVE_TUNNEL_STOPPED=1
        stop_farm_service cloudflared
        write_warn 'The tunnel was stopped: the hub administrator still had the default password.'
    fi
    echo
    write_color "$FK_YELLOW" '   The hub'"'"'s administrator is called "admin" and still has the default'
    write_color "$FK_YELLOW" '   password that everybody can look up. Choose a new one now. You will use'
    write_color "$FK_YELLOW" '   it to sign in to the hub'"'"'s own page; keep it in a password manager.'
    write_color "$FK_YELLOW" '   Rules: at least 14 characters, mixing three of lower case, upper case,'
    write_color "$FK_YELLOW" '   digits, other characters. Typing is hidden.'
    read_farm_password 'New hub administrator password'
    ADMIN_PASSWORD=$REPLY_SECRET; REPLY_SECRET=''
    hub_admin /change-password POST "{\"current_password\":$(json_string "$DEFAULT_PASSWORD"),\"new_password\":$(json_string "$ADMIN_PASSWORD")}"
    if [ "$HTTP_STATUS" -ne 200 ]; then
        stop_farm "The hub did not accept the new administrator password (HTTP $HTTP_STATUS)." 'Run install.sh again. Nothing has been opened to the internet.'
    fi
    connect_hub "$HUB_URL" admin "$DEFAULT_PASSWORD"
    if [ -n "$HUB_TOKEN" ]; then
        stop_farm 'The default administrator password still works after changing it.' 'Do not continue. Run install.sh again; if this repeats, report it on the kit repository. Nothing has been opened to the internet.'
    fi
    connect_hub "$HUB_URL" admin "$ADMIN_PASSWORD"
    ADMIN_TOKEN=$HUB_TOKEN
    [ -n "$ADMIN_TOKEN" ] || stop_farm 'The hub does not accept the new administrator password.' 'Run install.sh again. Nothing has been opened to the internet.'
    LEAVE_TUNNEL_STOPPED=0
    write_ok 'The default administrator password is gone.'
else
    write_note 'The hub administrator password was already changed. Enter it to continue (typing is hidden).'
    attempts=0
    while [ -z "$ADMIN_TOKEN" ]; do
        attempts=$((attempts + 1))
        if [ "$attempts" -gt 5 ]; then
            stop_farm 'The hub refused the administrator password five times.' 'Find the password of the hub user "admin" (the one chosen at the first installation). If it is lost for good, see README, section Troubleshooting, "Lost hub administrator password".'
        fi
        read_secret_line 'Hub administrator password (user admin)'
        ADMIN_PASSWORD=$REPLY_SECRET; REPLY_SECRET=''
        connect_hub "$HUB_URL" admin "$ADMIN_PASSWORD"
        ADMIN_TOKEN=$HUB_TOKEN
        [ -z "$ADMIN_TOKEN" ] && write_warn 'The hub refused that password.'
    done
    write_ok 'Signed in to the hub as its administrator.'
fi

# ----------------------------------------------------------------------
write_step '7/12  Hub users and the provider'
# ----------------------------------------------------------------------
# The default workspace (new phones land there).
hub_admin '/admin/workspaces?page=1&limit=100'
WORKSPACE_IDS=$(json_values "$HTTP_TEXT" 'result.workspaces.*.id' | awk 'NF')
if [ "$HTTP_STATUS" -ne 200 ] || [ -z "$WORKSPACE_IDS" ]; then
    stop_farm "The hub did not list its workspaces (HTTP $HTTP_STATUS)." 'Wait a minute and run install.sh again.'
fi
WORKSPACE_JSON=''
for id in $WORKSPACE_IDS; do WORKSPACE_JSON="$WORKSPACE_JSON,$(json_string "$id")"; done
WORKSPACE_JSON="[${WORKSPACE_JSON#,}]"

# "blossom": the login Blossom CRM uses. Admin role, because the product
# reads the device register and that needs it.
hub_admin /admin/users
hub_user_exists=0
if json_values "$HTTP_TEXT" 'result.*.username' | grep -Fxq "$HUB_USER_NAME"; then hub_user_exists=1; fi
# Blossom needs the password of this user, and it is stored nowhere on this
# Mac. The first time the farm is sent to Blossom through a pairing, a user
# that exists therefore gets a new one.
if [ "$PAIRING" = 1 ] && [ -z "$PAIR_SITE_SENT_AT" ] && [ "$hub_user_exists" = 1 ] && [ "$RESET_HUB_USER" = 0 ]; then
    RESET_HUB_USER=1
    write_note "Hub user \"$HUB_USER_NAME\" gets a new password: Blossom receives it through the pairing, and the one it had is not stored on this Mac."
fi
set_hub_user=1
[ "$hub_user_exists" = 1 ] && [ "$RESET_HUB_USER" = 0 ] && set_hub_user=0
if [ "$set_hub_user" = 1 ]; then
    candidate=$(new_random_secret 32 base64url)
    body="{\"username\":$(json_string "$HUB_USER_NAME"),\"password\":$(json_string "$candidate"),\"role\":\"admin\",\"workspace_ids\":[]}"
    if [ "$hub_user_exists" = 1 ]; then
        hub_admin /admin/user PUT "$body"
    else
        hub_admin /admin/user POST "$body"
        if [ "$HTTP_STATUS" -eq 400 ] && printf '%s' "$HTTP_TEXT" | grep -qi 'already exists'; then
            # the user list did not show it, but the hub has it
            if [ "$RESET_HUB_USER" = 1 ]; then hub_admin /admin/user PUT "$body"; else set_hub_user=0; fi
        fi
    fi
    if [ "$set_hub_user" = 1 ] && [ "$HTTP_STATUS" -ne 200 ]; then
        stop_farm "The hub did not create or update the user \"$HUB_USER_NAME\" (HTTP $HTTP_STATUS)." 'Run install.sh again. If it repeats, create the user by hand in the hub page (Admin -> Users, role admin) and run install.sh once more.'
    fi
    if [ "$set_hub_user" = 1 ]; then
        NEW_HUB_PASSWORD=$candidate
        if [ "$PAIRING" = 1 ]; then write_ok "Hub user \"$HUB_USER_NAME\" has a new random password (it goes to Blossom at the end)."
        else write_ok "Hub user \"$HUB_USER_NAME\" has a new random password (shown at the end)."; fi
    fi
    candidate=''; body=''
fi
if [ "$set_hub_user" = 0 ]; then
    write_ok "Hub user \"$HUB_USER_NAME\" exists; its password is left as it is (--reset-hub-user makes a new one)."
fi

# "farm-keepalive": the login of the keep-available service. Plain user
# role, new random password on every run (nobody needs to know it).
keep_password=$(new_random_secret 32 base64url)
body="{\"username\":$(json_string "$KEEP_USER_NAME"),\"password\":$(json_string "$keep_password"),\"role\":\"user\",\"workspace_ids\":$WORKSPACE_JSON}"
hub_admin /admin/user PUT "$body"
[ "$HTTP_STATUS" -eq 200 ] || hub_admin /admin/user POST "$body"
if [ "$HTTP_STATUS" -ne 200 ]; then
    stop_farm "The hub did not create or update the user \"$KEEP_USER_NAME\" (HTTP $HTTP_STATUS)." 'Run install.sh again.'
fi
write_secret_file "$FARM_KEEP_AVAILABLE" "{
  \"hubUrl\": $(json_string "$HUB_URL"),
  \"username\": $(json_string "$KEEP_USER_NAME"),
  \"password\": $(json_string "$keep_password")
}" service
keep_password=''; body=''
write_ok "Hub user \"$KEEP_USER_NAME\" (role user) is set up for the keep-available service."

# The provider's record in the hub. iOS is switched on later, in the hub
# page, once a signed WebDriverAgent has been uploaded (docs/phones.md):
# a provider with iOS on and no WebDriverAgent refuses to start.
appium_json=false
[ "$WITH_APPIUM" = 1 ] && appium_json=true
hub_admin /admin/providers
providers_text=$HTTP_TEXT
provider_index=$(json_find_index "$providers_text" 'result.*.nickname' "$NICKNAME")
if [ -n "$provider_index" ]; then
    existing_port=$(json_get "$providers_text" "result.$provider_index.port")
    existing_host=$(json_get "$providers_text" "result.$provider_index.host_address")
    if [ "$existing_port" != "$PROVIDER_PORT" ] || { [ "$existing_host" != 127.0.0.1 ] && [ "$existing_host" != localhost ]; }; then
        stop_farm "The hub already has a provider \"$NICKNAME\" on $existing_host:$existing_port. This kit needs it on 127.0.0.1:$PROVIDER_PORT." "In the hub page (Admin -> Providers) set its host address to 127.0.0.1 and its port to $PROVIDER_PORT, or run install.sh --nickname <another name>."
    fi
    # What the record says about Appium and about the system it runs on (a
    # farm moved here from a Windows PC still says "windows").
    changes=''
    [ "$WITH_APPIUM" = 1 ] && [ "$(json_get "$providers_text" "result.$provider_index.setup_appium_servers")" != true ] && changes='appium'
    [ "$(json_get "$providers_text" "result.$provider_index.os")" != darwin ] && changes="$changes os"
    if [ -n "$changes" ]; then
        body=$(printf '%s' "$providers_text" | "$FARM_NODE_EXE" -e '
            let text = ""
            process.stdin.on("data", d => { text += d }).on("end", () => {
              const record = JSON.parse(text).result[Number(process.argv[1])]
              record.os = "darwin"
              if (process.argv[2] === "true") record.setup_appium_servers = true
              process.stdout.write(JSON.stringify(record))
            })' "$provider_index" "$appium_json" 2> /dev/null)
        if [ -n "$body" ]; then hub_admin /admin/providers/update POST "$body"; else HTTP_STATUS=0; fi
        if [ "$HTTP_STATUS" -eq 200 ]; then
            write_ok "Provider \"$NICKNAME\": its record in the hub was brought up to date ($(trim_text "$changes"))."
        else
            write_warn "The hub did not update the record of the provider (HTTP $HTTP_STATUS). If you asked for Appium, switch it on in the hub page: Admin -> Providers -> \"Set up Appium servers\"."
        fi
        body=''
    fi
    write_ok "Provider \"$NICKNAME\" exists in the hub."
else
    body="{\"os\":\"darwin\",\"nickname\":$(json_string "$NICKNAME"),\"host_address\":\"127.0.0.1\",\"port\":$PROVIDER_PORT,\"provide_ios\":false,\"provide_android\":false,\"setup_appium_servers\":$appium_json,\"use_gads_ios_stream\":false,\"wda_bundle_id\":\"\"}"
    hub_admin /admin/providers/add POST "$body"
    if [ "$HTTP_STATUS" -ne 200 ]; then
        stop_farm "The hub did not create the provider \"$NICKNAME\" (HTTP $HTTP_STATUS)." 'Run install.sh again. If it repeats, create it in the hub page: Admin -> Providers -> New provider, OS darwin (macOS), host address 127.0.0.1, port 10001.'
    fi
    write_ok "Provider \"$NICKNAME\" created in the hub (127.0.0.1:$PROVIDER_PORT, iOS to be switched on after WebDriverAgent is uploaded)."
fi
providers_text=''

# ----------------------------------------------------------------------
write_step '8/12  Public host names'
# ----------------------------------------------------------------------
write_note 'Three host names under a domain that you own and that uses Cloudflare for its DNS.'
write_note 'Use direct sub-domains (farm-hub.yourdomain.com), not deeper ones (hub.farm.yourdomain.com):'
write_note 'Cloudflare'"'"'s free certificate covers one level only.'
# What is offered at each question: the names of the earlier installation.
offer_hub=$FARM_CFG_HUB_HOST; offer_provider=$FARM_CFG_PROVIDER_HOST; offer_restart=$FARM_CFG_RESTART_HOST
# A new farm: one question, the domain, and the three names follow from it.
domain_asked=0
if [ -z "$HUB_HOST$PROVIDER_HOST$RESTART_HOST$FARM_CFG_HUB_HOST" ]; then
    while [ -z "$DOMAIN" ]; do
        domain_asked=1
        if ! IFS= read -r -p 'Your domain at Cloudflare [for example yourdomain.com]: ' answer < /dev/tty; then
            echo
            stop_farm 'Nothing could be read from the keyboard.' 'Run the script in a Terminal window, or give the domain with --domain.'
        fi
        reason=$(test_farm_domain "$answer")
        if [ -z "$reason" ]; then DOMAIN=$answer; else write_warn "$reason"; fi
    done
fi
if [ -n "$DOMAIN" ]; then
    DOMAIN=$(normalize_farm_domain "$DOMAIN")
    proposed=$(get_default_farm_hostnames "$DOMAIN")
    default_hub=$(printf '%s\n' "$proposed" | sed -n 1p); default_provider=$(printf '%s\n' "$proposed" | sed -n 2p); default_restart=$(printf '%s\n' "$proposed" | sed -n 3p)
    if [ -z "$HUB_HOST$PROVIDER_HOST$RESTART_HOST" ]; then
        answer=''
        if [ "$domain_asked" = 1 ]; then
            write_note "Proposed:  $default_hub   $default_provider   $default_restart"
            IFS= read -r -p '   Press Enter to use these three names, or type n to choose each one: ' answer < /dev/tty || answer=''
        fi
        case $answer in
            [nN]*) offer_hub=$default_hub; offer_provider=$default_provider; offer_restart=$default_restart ;;
            *) HUB_HOST=$default_hub; PROVIDER_HOST=$default_provider; RESTART_HOST=$default_restart ;;
        esac
    else
        [ -n "$HUB_HOST" ] || HUB_HOST=$default_hub
        [ -n "$PROVIDER_HOST" ] || PROVIDER_HOST=$default_provider
        [ -n "$RESTART_HOST" ] || RESTART_HOST=$default_restart
    fi
fi
if [ -z "$HUB_HOST" ]; then read_hostname 'Host name for the hub' "$offer_hub" 'farm-hub.yourdomain.com'; HUB_HOST=$REPLY_HOST; fi
if [ -z "$PROVIDER_HOST" ]; then read_hostname 'Host name for the provider' "$offer_provider" 'farm-provider.yourdomain.com'; PROVIDER_HOST=$REPLY_HOST; fi
if [ -z "$RESTART_HOST" ]; then read_hostname 'Host name for the restart service' "$offer_restart" 'farm-restart.yourdomain.com'; RESTART_HOST=$REPLY_HOST; fi
HUB_HOST=$(to_lower "$(trim_text "$HUB_HOST")"); PROVIDER_HOST=$(to_lower "$(trim_text "$PROVIDER_HOST")"); RESTART_HOST=$(to_lower "$(trim_text "$RESTART_HOST")")
problems=$(test_farm_hostname_set "$HUB_HOST" "$PROVIDER_HOST" "$RESTART_HOST" | tr '\n' ' ')
if [ -n "$problems" ]; then
    stop_farm "The host names cannot be used: $problems" 'Run install.sh again and enter three different names such as farm-hub.yourdomain.com, farm-provider.yourdomain.com, farm-restart.yourdomain.com.'
fi
write_ok "$HUB_HOST, $PROVIDER_HOST, $RESTART_HOST"

# ----------------------------------------------------------------------
write_step '9/12  Cloudflare tunnel'
# ----------------------------------------------------------------------
TUNNEL_ID=''
if [ -f "$FARM_TUNNEL_CREDENTIALS" ]; then
    TUNNEL_ID=$(get_tunnel_id_from_text "$(json_file_get "$FARM_TUNNEL_CREDENTIALS" TunnelID)")
fi
routes_done=0
if [ -n "$TUNNEL_ID" ] && [ "$FARM_HAS_CONFIG" = 1 ] && [ "$OVERWRITE_DNS" = 0 ] &&
    [ "$FARM_CFG_TUNNEL_ID" = "$TUNNEL_ID" ] && [ "$FARM_CFG_HUB_HOST" = "$HUB_HOST" ] && [ "$FARM_CFG_PROVIDER_HOST" = "$PROVIDER_HOST" ] &&
    [ "$FARM_CFG_RESTART_HOST" = "$RESTART_HOST" ] && [ "$FARM_CFG_ROUTES_CREATED" = true ]; then
    routes_done=1
fi

if [ "$routes_done" = 0 ]; then
    if [ ! -f "$FARM_TUNNEL_CERT" ]; then
        # cloudflared writes the account certificate below the home folder; it
        # is given a private one inside /opt/farm for this.
        login_home=$FARM_VAR/login
        rm -rf "$login_home"
        (umask 077 && mkdir -p "$login_home") || stop_farm "Could not create $login_home." 'Run install.sh again with sudo.'
        echo
        write_color "$FK_YELLOW" '   A browser window opens now (or an address is printed: open it in any browser).'
        write_color "$FK_YELLOW" '   Sign in to Cloudflare, choose the domain of your host names, press Authorize.'
        write_color "$FK_YELLOW" '   No Cloudflare account yet? See docs/network.md first, then run install.sh again.'
        echo
        HOME=$login_home "$FARM_CLOUDFLARED_EXE" tunnel login
        code=$?
        if [ "$code" -ne 0 ] || [ ! -f "$login_home/.cloudflared/cert.pem" ]; then
            rm -rf "$login_home"
            stop_farm 'The Cloudflare sign-in did not finish.' 'Run install.sh again and complete the sign-in in the browser within a few minutes. The domain must already be added to your Cloudflare account (docs/network.md).'
        fi
        # The account certificate can create and delete tunnels and DNS
        # records. It is kept in the protected folder, for root only.
        mv -f "$login_home/.cloudflared/cert.pem" "$FARM_TUNNEL_CERT" || stop_farm "Could not move the account certificate to $FARM_TUNNEL_CERT." 'Run install.sh again.'
        rm -rf "$login_home"
        protect_farm_path "$FARM_TUNNEL_CERT" private
    fi
    export TUNNEL_ORIGIN_CERT=$FARM_TUNNEL_CERT

    if [ -z "$TUNNEL_ID" ]; then
        run_native "$FARM_CLOUDFLARED_EXE" tunnel create --credentials-file "$FARM_TUNNEL_CREDENTIALS" "$TUNNEL_NAME"
        if [ "$RUN_CODE" -ne 0 ] || [ ! -f "$FARM_TUNNEL_CREDENTIALS" ]; then
            text=$(printf '%s' "$RUN_OUTPUT" | tr '\n' ' ')
            if printf '%s' "$text" | grep -qi 'already exists'; then
                stop_farm "Your Cloudflare account already has a tunnel called \"$TUNNEL_NAME\", but its credentials are not on this Mac." "Either delete that tunnel in the Cloudflare dashboard (Zero Trust -> Networks -> Tunnels) and run install.sh again, or run   sudo bash install.sh --tunnel-name $TUNNEL_NAME-2   . When moving a farm to a new computer use scripts/export-farm and scripts/import-farm instead."
            fi
            stop_farm "cloudflared could not create the tunnel: $text" 'Check the internet connection and that the Cloudflare sign-in was done with an account that may manage the domain, then run install.sh again.'
        fi
        protect_farm_path "$FARM_TUNNEL_CREDENTIALS" service
        TUNNEL_ID=$(get_tunnel_id_from_text "$(json_file_get "$FARM_TUNNEL_CREDENTIALS" TunnelID)")
        if [ -z "$TUNNEL_ID" ]; then
            stop_farm 'The tunnel was created but its credentials file has no tunnel id.' 'Delete /opt/farm/config/cloudflared/tunnel-credentials.json, delete the tunnel in the Cloudflare dashboard, and run install.sh again.'
        fi
        write_ok "Tunnel \"$TUNNEL_NAME\" created."
    else
        write_ok 'The tunnel of the earlier installation is reused.'
    fi

    for name in "$HUB_HOST" "$PROVIDER_HOST" "$RESTART_HOST"; do
        if [ "$OVERWRITE_DNS" = 1 ]; then
            run_native "$FARM_CLOUDFLARED_EXE" tunnel route dns --overwrite-dns "$TUNNEL_ID" "$name"
        else
            run_native "$FARM_CLOUDFLARED_EXE" tunnel route dns "$TUNNEL_ID" "$name"
        fi
        text=$(printf '%s' "$RUN_OUTPUT" | tr '\n' ' ')
        if [ "$RUN_CODE" -ne 0 ] && ! printf '%s' "$text" | grep -qi 'already configured to route to your tunnel'; then
            if printf '%s' "$text" | grep -qi 'already exists'; then
                stop_farm "A DNS record for $name already exists in your Cloudflare zone." 'If the name is free to use for the farm, run   sudo bash install.sh --overwrite-dns   (it replaces the record). Otherwise choose another name.'
            fi
            stop_farm "cloudflared could not create the DNS record for $name: $text" 'Check that the name belongs to the domain you authorised in the Cloudflare sign-in. To sign in again, delete /opt/farm/config/cloudflared/cert.pem and run install.sh again.'
        fi
    done
    write_ok 'DNS records created for the three host names.'
else
    write_ok 'Tunnel and DNS records are already in place.'
fi
unset TUNNEL_ORIGIN_CERT
[ -f "$FARM_TUNNEL_CREDENTIALS" ] && protect_farm_path "$FARM_TUNNEL_CREDENTIALS" service

yml=$(get_cloudflared_config_text "$TUNNEL_ID" "$FARM_TUNNEL_CREDENTIALS" "$HUB_HOST" "$PROVIDER_HOST" "$RESTART_HOST" "$HUB_PORT" "$GATE_PORT" "$RESTART_PORT" 2> /dev/null)
[ -n "$yml" ] || stop_farm 'The tunnel configuration could not be written (the tunnel id or a host name is not valid).' 'Run install.sh again and enter the three host names again.'
if [ ! -f "$FARM_CLOUDFLARED_YML" ] || [ "$(cat "$FARM_CLOUDFLARED_YML")" != "$yml" ]; then
    printf '%s\n' "$yml" > "$FARM_CLOUDFLARED_YML" || stop_farm "Could not write $FARM_CLOUDFLARED_YML." 'Run install.sh again with sudo.'
fi
protect_farm_path "$FARM_CLOUDFLARED_YML" service
run_native "$FARM_CLOUDFLARED_EXE" tunnel --config "$FARM_CLOUDFLARED_YML" ingress validate
if [ "$RUN_CODE" -ne 0 ]; then
    stop_farm "cloudflared does not accept the tunnel configuration: $(printf '%s' "$RUN_OUTPUT" | tr '\n' ' ')" 'This is a fault in the kit, not in your setup: report it on the kit repository with the text above.'
fi
write_ok "Tunnel configuration written and validated ($FARM_CLOUDFLARED_YML)."

# the non-secret record of this installation
with_appium_json=false
[ "$WITH_APPIUM" = 1 ] && with_appium_json=true
record="{
  \"kit\": $(json_string "$(kit_version kit)"),
  \"platform\": \"macos\",
  \"installedAt\": $(json_string "$(date '+%Y-%m-%dT%H:%M:%S')"),
  \"nickname\": $(json_string "$NICKNAME"),
  \"hubHost\": $(json_string "$HUB_HOST"),
  \"providerHost\": $(json_string "$PROVIDER_HOST"),
  \"restartHost\": $(json_string "$RESTART_HOST"),
  \"hubUser\": $(json_string "$HUB_USER_NAME"),
  \"tunnelName\": $(json_string "$TUNNEL_NAME"),
  \"tunnelId\": $(json_string "$TUNNEL_ID"),
  \"routesCreated\": true,
  \"gads\": $(json_string "$GADS_VERSION"),
  \"gadsDrag\": $(json_string "$DRAG_VERSION"),
  \"withAppium\": $with_appium_json
}"
printf '%s\n' "$record" > "$FARM_JSON" || stop_farm "Could not write $FARM_JSON." 'Run install.sh again with sudo.'
protect_farm_path "$FARM_JSON" private

# ----------------------------------------------------------------------
write_step '10/12  Restart secret'
# ----------------------------------------------------------------------
have_secret=0
if [ -f "$FARM_RESTART_SECRET" ]; then
    existing=$(tr -d '[:space:]' < "$FARM_RESTART_SECRET")
    [ "${#existing}" -ge 32 ] && have_secret=1
    existing=''
fi
if [ "$have_secret" = 1 ]; then
    protect_farm_path "$FARM_RESTART_SECRET" private
    write_ok 'The restart secret of the earlier installation is kept.'
else
    NEW_RESTART_SECRET=$(new_random_secret 32 hex)
    [ "${#NEW_RESTART_SECRET}" -eq 64 ] || stop_farm 'The random generator of this Mac gave no secret.' 'Run install.sh again; if it repeats, report it on the kit repository.'
    write_secret_file "$FARM_RESTART_SECRET" "$NEW_RESTART_SECRET" private
    if [ "$PAIRING" = 1 ]; then write_ok 'A new random restart secret was generated (256 bits; it goes to Blossom at the end).'
    else write_ok 'A new random restart secret was generated (256 bits, shown at the end).'; fi
fi
HAVE_SUMMARY=1

# ----------------------------------------------------------------------
write_step '11/12  Services (launchd)'
# ----------------------------------------------------------------------
PROVIDER_PATH="$FARM_TOOLS_DIR:$FARM_NODE_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ "$WITH_APPIUM" = 1 ]; then
    PROVIDER_PATH="$NPM_PREFIX/bin:$PROVIDER_PATH"
    APPIUM_ENV_XML="        <key>APPIUM_HOME</key>
        <string>$(xml_escape "$APPIUM_HOME_DIR")</string>
        <key>NPM_CONFIG_PREFIX</key>
        <string>$(xml_escape "$NPM_PREFIX")</string>
"
fi

# The packet filter: for every iPhone the provider opens ports on all network
# addresses of this Mac (see services/farm-firewall.sh). The rule is loaded
# before the provider is started.
if [ "$SKIP_FIREWALL" = 1 ]; then
    write_warn 'Skipped the packet filter rule (--skip-firewall-rules). The ports the provider opens for each phone are then only as closed as your own firewall makes them (docs/security.md, section 1).'
else
    port_first=$(sysctl -n net.inet.ip.portrange.first 2> /dev/null)
    port_last=$(sysctl -n net.inet.ip.portrange.last 2> /dev/null)
    case $port_first in '' | *[!0-9]*) port_first=49152 ;; esac
    case $port_last in '' | *[!0-9]*) port_last=65535 ;; esac
    if [ "$port_first" -lt 1024 ] || [ "$port_last" -le "$port_first" ]; then port_first=49152; port_last=65535; fi
    rules=$(render_template "$KIT_ROOT/launchd/pf.rules.template" "PORT_FIRST=$port_first" "PORT_LAST=$port_last")
    if [ ! -f "$FARM_PF_RULES" ] || [ "$(cat "$FARM_PF_RULES")" != "$rules" ]; then
        printf '%s\n' "$rules" > "$FARM_PF_RULES" || stop_farm "Could not write $FARM_PF_RULES." 'Run install.sh again with sudo.'
    fi
    protect_farm_path "$FARM_PF_RULES" private
    render_service firewall "$FARM_PF_RULES" "$FARM_SERVICES/farm-firewall.sh"
    farm_service_loaded firewall || launchctl bootstrap system "$(farm_plist_path firewall)" > /dev/null 2>&1
    /bin/bash "$FARM_SERVICES/farm-firewall.sh" load > /dev/null 2>&1
    get_farm_firewall_state
    if firewall_covers_port "$port_first" && firewall_covers_port "$port_last"; then
        write_ok "The packet filter of macOS is on and refuses connections from other computers to the provider's per-phone ports ($port_first to $port_last)."
    elif [ "$FW_AVAILABLE" = 0 ]; then
        write_warn 'The packet filter of macOS (pf) could not be asked. If another firewall product manages this Mac, block incoming TCP connections to this Mac there (docs/security.md, section 1).'
    else
        write_warn "The packet filter rule could not be loaded. Other computers on your network may reach the ports the provider opens for each phone. Read /opt/farm/logs-root/firewall.log and docs/security.md, section 1; scripts/status.sh shows the state."
    fi
fi

render_service provider "$FARM_PROVIDER_EXE"
render_service gate "$FARM_SERVICES/provider-gate.js" "$FARM_NODE_EXE"
render_service keep-available "$FARM_SERVICES/keep-available.sh" "$FARM_SERVICES/json.awk" "$FARM_KEEP_AVAILABLE"
render_service restart "$FARM_SERVICES/restart-server.js" "$FARM_NODE_EXE" "$FARM_RESTART_SECRET"
render_service cloudflared "$FARM_CLOUDFLARED_EXE" "$FARM_CLOUDFLARED_YML" "$FARM_TUNNEL_CREDENTIALS"

# The logs are rotated by the wrapper that starts each service
# (services/farm-run.sh), as the account of that service. A rotation file an
# earlier kit wrote for macOS' own newsyslog is removed: newsyslog runs as
# root, and root does not work in a folder the service account can write to.
[ -f "$FARM_NEWSYSLOG_FILE" ] && rm -f "$FARM_NEWSYSLOG_FILE"
# The logs of the two root services are in /opt/farm/logs-root now.
rm -f "$FARM_LOGS"/restart-server.log "$FARM_LOGS"/restart-server.log.* "$FARM_LOGS"/firewall.log "$FARM_LOGS"/firewall.log.*

# The tunnel is started last, and only now: the default password is gone,
# the provider sits behind its gate, the restart service has its secret.
started=''
for name in $(get_farm_start_order); do
    if start_farm_service "$name" 40; then started="$started $name"
    else write_warn "The program of the service $(farm_label "$name") did not start within 40 seconds. See /opt/farm/logs."; fi
done
if ! wait_tcp_port "$GATE_PORT" 20; then
    stop_farm "The provider gate does not listen on 127.0.0.1:$GATE_PORT." 'Read the end of /opt/farm/logs/provider-gate.log, then run install.sh again.'
fi
if ! wait_tcp_port "$RESTART_PORT" 20; then
    stop_farm "The restart service does not listen on 127.0.0.1:$RESTART_PORT." 'Read the end of /opt/farm/logs-root/restart-server.log, then run install.sh again.'
fi
if ! wait_tcp_port "$PROVIDER_PORT" 30; then
    write_warn 'The GADS provider is not listening yet. Read /opt/farm/logs/provider.log; the self-test below will say more.'
fi
# The fixed ports of the farm may not listen on the network: everything is
# reached through the tunnel, which connects outwards. (The ports the
# provider opens per phone are a different matter: upstream GADS binds them
# to all addresses, and the packet filter rule above closes them.)
get_farm_listeners
open_line=$(printf '%s\n' "$FARM_LISTENERS" | awk -F '\t' -v a="$HUB_PORT" -v b="$PROVIDER_PORT" -v c="$GATE_PORT" -v d="$RESTART_PORT" \
    '($4 == a || $4 == b || $4 == c || $4 == d) && $3 !~ /^127\./ && $3 != "::1" { print $4 " listens on " $3; exit }')
if [ -n "$open_line" ]; then
    LEAVE_TUNNEL_STOPPED=1
    stop_farm_service cloudflared
    stop_farm "Port $open_line, which other computers on your network can reach. The tunnel was stopped." 'If it is the provider port: open the hub page (Admin -> Providers) and set the host address to 127.0.0.1. Then run install.sh again.'
fi
write_ok "Services installed and set to start with the Mac:$started."

if [ "$SKIP_POWER" = 0 ]; then
    pmset -a sleep 0 > /dev/null 2>&1
    pmset -a disksleep 0 > /dev/null 2>&1
    # Not every Mac has this setting (a MacBook has none); a refusal is fine.
    pmset -a autorestart 1 > /dev/null 2>&1
    write_ok 'Sleep is switched off, and the Mac starts by itself after a power cut where the model supports it (a sleeping computer is an offline farm).'
fi
if fdesetup status 2> /dev/null | grep -q 'FileVault is On'; then
    write_warn 'FileVault is on. After a restart or a power cut this Mac waits for somebody to type the password before it starts anything, the farm included. See README, "Check that it survives a restart".'
fi

# ----------------------------------------------------------------------
write_step '12/12  Self-test (the same checks as "Test connection" in Blossom)'
# ----------------------------------------------------------------------
if [ "$SKIP_SELF_TEST" = 1 ]; then
    write_note 'Skipped. Run scripts/self-test.sh later.'
else
    test_user='admin'; test_password=$ADMIN_PASSWORD
    if [ -n "$NEW_HUB_PASSWORD" ]; then
        test_user=$HUB_USER_NAME; test_password=$NEW_HUB_PASSWORD
    else
        write_note "The test signs in as \"admin\": the password of \"$HUB_USER_NAME\" is not stored on this Mac."
    fi
    restart_secret=$(tr -d '[:space:]' < "$FARM_RESTART_SECRET")
    try=1
    while true; do
        invoke_farm_self_test "$HUB_HOST" "$PROVIDER_HOST" "$RESTART_HOST" "$NICKNAME" "$test_user" "$test_password" "$restart_secret"
        if [ "$SELFTEST_FAILED" = 0 ] || [ "$try" -ge 6 ]; then break; fi
        try=$((try + 1))
        write_note "Not everything answers yet (new DNS records and a new tunnel need a moment). Trying again in 20 seconds ($try of 6)..."
        sleep 20
    done
    restart_secret=''; test_password=''
    write_self_test_report
    if [ "$SELFTEST_FAILED" = 0 ]; then
        write_ok 'The farm answers on its public addresses. ("CHECK" on Phones is expected until phones are added.)'
    else
        write_warn 'The self-test did not pass. The setup itself is complete; fix what the failed step says, then run scripts/self-test.sh.'
        write_warn 'This test ran from this Mac. "Test connection" in Blossom runs from Blossom'"'"'s servers and is the one that counts.'
    fi
fi
if [ "$PAIRING" = 1 ]; then
    write_step 'Blossom CRM'
    write_note "Sending the addresses and the credentials of this farm to $PAIR_ORIGIN..."
    if ! send_farm_to_blossom && [ "$APP_CODE" = credentials_required ] && [ -z "$NEW_HUB_PASSWORD" ]; then
        # Blossom holds no password for these addresses (they changed, or it
        # is another workspace). The one in use is stored nowhere on this
        # Mac, so the hub user gets a new one, and the farm is sent again.
        if set_hub_user_password; then
            write_note "Hub user \"$HUB_USER_NAME\" got a new password, because Blossom has none for these addresses."
            send_farm_to_blossom
        fi
    fi
    if [ "$APP_KIND" = ok ]; then
        SENT_TO_BLOSSOM=1
        write_ok 'Blossom received the farm.'
        if [ "$PAIR_NEEDS_CONFIRMATION" = true ] || [ "$PAIR_STATE" != active ]; then
            write_note 'Blossom now calls the farm from its servers, then asks an admin to confirm it (up to 10 minutes are waited here; closing this window does no harm).'
        fi
        pair_wait 600; waited=$?
        [ "$waited" = 0 ] && ACTIVE_IN_BLOSSOM=1
        if [ "$waited" = 2 ]; then
            write_note 'Not confirmed yet. Nothing is lost: confirm in Blossom (Phone Farm -> Farm setup) when you are ready. scripts/status.sh shows where the pairing stands.'
        fi
    else
        write_warn "The farm could not be sent to Blossom: $APP_MESSAGE"
        write_warn "The farm itself is set up. Enter the values below in Blossom by hand, or: $FK_PAIR_HELP"
    fi
fi
ADMIN_PASSWORD=''; ADMIN_TOKEN=''

show_final_values
if [ "$SENT_TO_BLOSSOM" = 1 ]; then
    write_color "$FK_CYAN" 'Next: prepare the phones - docs/phones.md. They appear in Blossom by themselves.'
else
    write_color "$FK_CYAN" 'Next: prepare the phones - docs/phones.md. Then press "Test connection" in Blossom.'
fi
echo
EXIT_CODE=0
exit 0
