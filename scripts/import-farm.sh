#!/bin/bash
# Blossom farm kit - restores a farm from an archive made by export-farm, on a
# new Mac.
#
#     sudo bash scripts/import-farm.sh --archive /Volumes/STICK/farm-export-20260101-1200.zip
#
# The archive may come from a Mac (scripts/export-farm.sh) or from a Windows
# PC (scripts\export-farm.ps1). Restored are: the GADS database, the
# configuration with its secrets, the tunnel credentials and the provider's
# cached phone pairings. Then it tells you to run install.sh, which installs
# the programs and services around them. The host names, the hub passwords
# and the restart secret stay the same, so nothing has to be changed in
# Blossom CRM.
#
# The pairing records that Windows keeps for Apple's own software
# (C:\ProgramData\Apple\Lockdown) are not used on a Mac. A phone that does
# not accept the provider's cached pairing asks "Trust This Computer?" once.
#
# The old computer must not run the farm any more (same tunnel).
#   --archive PATH   The archive written by export-farm.
#   --force          Overwrite an installation that already exists on this Mac.

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"
SCRIPT_ARGS=("$@")

ARCHIVE=''; FORCE=0
while [ $# -gt 0 ]; do
    case $1 in
        --archive=*) ARCHIVE=${1#*=} ;;
        --archive) [ $# -ge 2 ] || stop_farm '--archive needs a path.' 'Give the full path of the .zip file written by export-farm.'; ARCHIVE=$2; shift ;;
        --force) FORCE=1 ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) stop_farm "Unknown option: $1" 'Use --archive PATH and, to replace an existing installation, --force.' ;;
    esac
    shift
done

STAGE=''
# shellcheck disable=SC2329  # runs as a trap
cleanup() { trap - EXIT; [ -n "$STAGE" ] && rm -rf "$STAGE"; farm_http_cleanup; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

assert_macos_root
use_protected_kit_folder "scripts/import-farm.sh" ${SCRIPT_ARGS[@]+"${SCRIPT_ARGS[@]}"}
get_farm_arch
[ -n "$ARCHIVE" ] || stop_farm 'No archive was named.' 'Run:   sudo bash scripts/import-farm.sh --archive <path of the .zip file written by export-farm>'
[ -f "$ARCHIVE" ] || stop_farm "Archive not found: $ARCHIVE" 'Give the full path of the .zip file written by export-farm.'
get_farm_paths /opt/farm
# A /opt/farm that this kit did not create and lock is not adopted.
initialize_farm_root "$FARM_ROOT"
if [ -f "$FARM_JSON" ] && [ "$FORCE" = 0 ]; then
    stop_farm 'This Mac already has a farm installation.' 'To replace it with the archive, run the same command with --force. Its database, secrets and tunnel settings will be overwritten.'
fi
read_kit_versions "$KIT_ROOT"
min_macos=$(kit_version "macos.$FARM_ARCH.minimumMacOS")
if [ -n "$min_macos" ] && ! version_at_least "$(sw_vers -productVersion 2> /dev/null)" "$min_macos"; then
    stop_farm "macOS $(sw_vers -productVersion 2> /dev/null) is too old." "The farm programs this kit installs on this kind of Mac need macOS $min_macos or later."
fi

write_step '1/5  Programs needed for the restore'
ensure_service_account
ensure_farm_layout ''
copy_service_files
install_archive_program "$FARM_MONGO_DIR" bin/mongod "$(kit_version "macos.$FARM_ARCH.mongodb.url")" "$(kit_version "macos.$FARM_ARCH.mongodb.sha256")" "MongoDB $(kit_version macos.mongodb)"
install_mongodb_tools
MONGORESTORE=$FARM_BIN/mongodb-tools/bin/mongorestore

write_step '2/5  Unpacking'
STAGE=$FARM_ROOT/import-stage
rm -rf "$STAGE"
(umask 077 && mkdir "$STAGE") || stop_farm "Could not create $STAGE." 'Check the free space on the disk.'
umask 077
if ! unzip -q -o "$ARCHIVE" -d "$STAGE" > /dev/null 2>&1; then
    # unzip also ends with a warning status for archives it unpacked; what
    # counts is checked below.
    :
fi
# Archives written by Windows PowerShell 5.1 name their entries with
# backslashes ("config\farm.json"); put such files where they belong.
find "$STAGE" -name '*\\*' -print 2> /dev/null | while IFS= read -r entry; do
    relative=${entry#"$STAGE"/}
    case $relative in *..*) continue ;; esac
    # shellcheck disable=SC1003  # a single backslash, for tr
    target=$STAGE/$(printf '%s' "$relative" | tr '\\' '/')
    if [ -d "$entry" ]; then mkdir -p "$target"; rmdir "$entry" 2> /dev/null; continue; fi
    mkdir -p "$(dirname "$target")" && mv -f "$entry" "$target"
done
if [ ! -f "$STAGE/manifest.json" ] || [ ! -s "$STAGE/gads.archive.gz" ] || [ ! -f "$STAGE/config/farm.json" ]; then
    stop_farm 'This file is not an archive written by export-farm (manifest, database dump or configuration missing).' 'Run export-farm on the old computer again and use the file it writes.'
fi
nickname=$(json_file_get "$STAGE/manifest.json" nickname)
exported_at=$(json_file_get "$STAGE/manifest.json" exportedAt)
platform=$(json_file_get "$STAGE/manifest.json" platform)
[ -n "$platform" ] || platform=windows
reason=$(test_provider_nickname "$nickname")
if [ -n "$reason" ] || [ -z "$(json_file_get "$STAGE/config/farm.json" hubHost)" ]; then
    stop_farm 'The archive cannot be read (its manifest or its installation record is damaged).' 'Run export-farm on the old computer again and use the file it writes.'
fi
write_ok "Archive of $exported_at, provider \"$nickname\", written on $platform."

write_step '3/5  Database'
for name in cloudflared keep-available restart gate provider hub; do stop_farm_service "$name"; done
ensure_mongodb_service
run_native "$MONGORESTORE" --host 127.0.0.1:27017 "--archive=$STAGE/gads.archive.gz" --gzip --drop --nsInclude 'gads.*'
if [ "$RUN_CODE" -ne 0 ]; then
    stop_farm "mongorestore failed: $(printf '%s\n' "$RUN_OUTPUT" | last_lines 3)" 'Check the free space on the disk and run this script again. If the old computer ran a newer MongoDB than this kit installs, use a newer kit here.'
fi
write_ok 'Database "gads" restored.'

write_step '4/5  Configuration, secrets and pairings'
# Only the files the kit knows are taken from the archive, each with the
# permissions install.sh gives it. The tunnel configuration file and the
# pinned versions are written anew by install.sh.
restore_file() {
    # restore_file <name below config> <kind for protect_farm_path>
    [ -f "$STAGE/config/$1" ] || return 0
    if ! cp -f "$STAGE/config/$1" "$FARM_CONFIG/$1"; then stop_farm "Could not write $FARM_CONFIG/$1." 'Check the free space on the disk.'; fi
    protect_farm_path "$FARM_CONFIG/$1" "$2"
}
restore_file farm.json private
restore_file restart-secret.txt private
restore_file keep-available.json service
# the pairing with Blossom moves with the farm: the new computer speaks for the same site
restore_file pairing.json private
restore_file cloudflared/tunnel-credentials.json service
restore_file cloudflared/cert.pem private
write_ok '/opt/farm/config restored (host names, restart secret, tunnel credentials).'
if [ -d "$STAGE/pair_records" ]; then
    _fk_make_dir "$FARM_ROOT/$nickname" service-write
    target=$FARM_ROOT/$nickname/pair_records
    _fk_make_dir "$target" service-write
    for f in "$STAGE"/pair_records/*.json; do
        [ -f "$f" ] || continue
        cp -f "$f" "$target/$(basename "$f")" && protect_farm_path "$target/$(basename "$f")" service-write
    done
    write_ok "The provider's cached phone pairings restored (a phone that does not accept its pairing asks \"Trust This Computer?\" once: tap Trust)."
fi
if [ -d "$STAGE/Lockdown" ]; then
    write_note "The archive also holds the pairing records of Apple's software on Windows. They are not used on a Mac."
fi
rm -rf "$STAGE"; STAGE=''

write_step '5/5  Next'
write_note 'Now run the installer. It finds the restored configuration, asks for the hub administrator'
write_note 'password you already had, and installs the programs and services around it:'
write_note '   sudo bash install.sh'
write_color "$FK_YELLOW" '   Make sure the old computer no longer runs the farm, and delete the archive when done.'
exit 0
