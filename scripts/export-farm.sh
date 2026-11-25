#!/bin/bash
# Blossom farm kit - packs a farm into one archive, to move it to another computer.
#
#     sudo bash scripts/export-farm.sh
#     sudo bash scripts/export-farm.sh --out-file /Volumes/STICK/farm.zip
#
# The archive holds: the GADS database (phones, users, uploaded
# WebDriverAgent), the farm's configuration (the restart secret, the tunnel
# credentials, the host names) and the provider's cached phone pairings. No
# secret is written into this script or into a log; they are in the archive.
#
# The archive can be imported on a Mac (scripts/import-farm.sh) or on a
# Windows PC (scripts\import-farm.ps1): the format is the same.
#
# TREAT THE ARCHIVE LIKE A MASTER KEY. It is not encrypted. Whoever gets it
# can run your tunnel, sign in to your hub and control your phones. Carry it
# on an encrypted disk (Disk Utility: erase the stick as "APFS (Encrypted)")
# or inside an encrypted archive, and delete it from both computers when the
# move is done.
#
# Then switch this computer's farm off (scripts/uninstall.sh): two computers
# must not run the same tunnel.
#   --out-file PATH   Where to write the archive (default /opt/farm/export/farm-export-<date>.zip,
#                     a folder only root can read). On a Mac disk the file is restricted to root
#                     before anything is written into it. A stick formatted FAT32 or exFAT has no
#                     file permissions at all: the script says so and asks before writing there.

set -u
KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/farmkit.sh
. "$KIT_ROOT/lib/farmkit.sh"

OUT_FILE=''
while [ $# -gt 0 ]; do
    case $1 in
        --out-file=*) OUT_FILE=${1#*=} ;;
        --out-file) [ $# -ge 2 ] || stop_farm '--out-file needs a path.' 'For example:  --out-file /Volumes/STICK/farm.zip'; OUT_FILE=$2; shift ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) stop_farm "Unknown option: $1" 'Use --out-file PATH, or no option.' ;;
    esac
    shift
done

STAGE=''; PACKED=''; WRITTEN=0; DONE=0
# shellcheck disable=SC2329  # runs as a trap
cleanup() {
    # Never leave a half-written or unprotected archive behind.
    trap - EXIT
    [ -n "$PACKED" ] && rm -f "$PACKED"
    [ -n "$STAGE" ] && rm -rf "$STAGE"
    if [ "$DONE" = 0 ] && [ "$WRITTEN" = 1 ] && [ -n "$OUT_FILE" ]; then rm -f "$OUT_FILE"; fi
    farm_http_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

assert_macos_root
get_farm_arch
get_farm_paths /opt/farm
read_farm_config
[ "$FARM_HAS_CONFIG" = 1 ] || stop_farm 'This Mac has no farm installation.' 'There is nothing to export. Run this on the computer that runs the farm.'
reason=$(test_provider_nickname "$FARM_CFG_NICKNAME")
[ -z "$reason" ] || stop_farm 'The installation record names no usable provider nickname.' 'Run install.sh again; it rewrites the record.'
read_kit_versions "$KIT_ROOT"
if [ -z "$OUT_FILE" ]; then
    _fk_make_dir "$FARM_ROOT/export" private
    OUT_FILE=$FARM_ROOT/export/farm-export-$(date '+%Y%m%d-%H%M').zip
fi
case $OUT_FILE in /*) ;; *) OUT_FILE=$PWD/$OUT_FILE ;; esac
if [ -e "$OUT_FILE" ]; then
    kept=$OUT_FILE; OUT_FILE=''
    stop_farm "$kept already exists." 'Delete it or choose another name with --out-file.'
fi
out_dir=$(dirname "$OUT_FILE")
if [ ! -d "$out_dir" ]; then
    OUT_FILE=''
    stop_farm "The folder for the archive does not exist: $out_dir" 'Create it, or choose another place with --out-file.'
fi

# File permissions exist on Mac disks (APFS, HFS+) only; a stick formatted
# FAT32 or exFAT has none. Decided before anything secret is written: the
# destination is created empty and restricted to root now, and what the disk
# then reports is believed. Either the file is protected before the first
# secret goes into it, or the person is told plainly that this medium cannot
# protect it.
if ! (set -C; : > "$OUT_FILE") 2> /dev/null; then
    kept=$OUT_FILE; OUT_FILE=''
    stop_farm "Could not create $kept." 'Check that the disk is not read-only, or choose another place with --out-file.'
fi
WRITTEN=1
can_restrict=0
if chown 0:0 "$OUT_FILE" 2> /dev/null && chmod 600 "$OUT_FILE" 2> /dev/null &&
    [ "$(file_owner_uid "$OUT_FILE")" = 0 ] && [ "$(file_mode "$OUT_FILE")" = 600 ]; then
    can_restrict=1
fi
if [ "$can_restrict" = 0 ]; then
    write_warn "$OUT_FILE is on a disk without file permissions."
    write_warn 'Everybody who can read that disk can read the archive, with every secret of this farm. Only continue if the disk itself is encrypted.'
    answer=''
    IFS= read -r -p 'Type YES to write the archive there anyway: ' answer < /dev/tty
    if [ "$answer" != YES ]; then write_note 'Nothing was written.'; exit 0; fi
fi

write_step '1/4  Database tools'
install_mongodb_tools
MONGODUMP=$FARM_BIN/mongodb-tools/bin/mongodump

write_step '2/4  Collecting'
STAGE=$FARM_ROOT/export-stage
rm -rf "$STAGE"
(umask 077 && mkdir "$STAGE") || stop_farm "Could not create $STAGE." 'Check the free space on the disk.'
umask 077

run_native "$MONGODUMP" --host 127.0.0.1:27017 --db gads "--archive=$STAGE/gads.archive.gz" --gzip
if [ "$RUN_CODE" -ne 0 ] || [ ! -s "$STAGE/gads.archive.gz" ]; then
    stop_farm "mongodump failed: $(printf '%s\n' "$RUN_OUTPUT" | last_lines 3)" 'Check that MongoDB is running (scripts/status.sh) and that the disk has free space, then run the export again.'
fi
write_ok 'Database "gads" dumped.'

mkdir -p "$STAGE/config/cloudflared"
for f in farm.json restart-secret.txt keep-available.json versions.json cloudflared/config.yml cloudflared/tunnel-credentials.json cloudflared/cert.pem; do
    if [ -f "$FARM_CONFIG/$f" ]; then cp -f "$FARM_CONFIG/$f" "$STAGE/config/$f" || stop_farm "Could not copy $FARM_CONFIG/$f." 'Check the free space on the disk.'; fi
done
write_ok 'Configuration and secrets copied.'

pair_cache=$FARM_ROOT/$FARM_CFG_NICKNAME/pair_records
if [ -d "$pair_cache" ] && ! dir_is_empty "$pair_cache"; then
    cp -R "$pair_cache" "$STAGE/pair_records" || stop_farm "Could not copy $pair_cache." 'Check the free space on the disk.'
    write_ok "The provider's cached phone pairings copied."
else
    write_note 'No cached phone pairings yet (the phones will ask "Trust This Computer?" on the new computer).'
fi
write_note "The pairing records macOS itself keeps (/var/db/lockdown) stay on this Mac: macOS does not hand them out."

printf '{\n  "exportedAt": %s,\n  "kit": %s,\n  "nickname": %s,\n  "platform": "macos",\n  "format": 1\n}\n' \
    "$(json_string "$(date '+%Y-%m-%dT%H:%M:%S')")" "$(json_string "$(kit_version kit)")" "$(json_string "$FARM_CFG_NICKNAME")" > "$STAGE/manifest.json"

write_step '3/4  Packing'
# The archive is built inside /opt/farm (root only). The destination is
# created empty and restricted BEFORE the bytes are copied into it, so the
# secrets never sit in a file that others can open.
PACKED=$FARM_ROOT/export-$(new_random_secret 16 hex).zip
if ! (cd "$STAGE" && zip -q -r -X "$PACKED" .); then
    stop_farm 'The archive could not be packed.' 'Check the free space on the disk and run the export again.'
fi
cat "$PACKED" > "$OUT_FILE" || stop_farm "Could not write $OUT_FILE." 'Check the free space on that disk and run the export again.'
size_kb=$(($(file_size "$OUT_FILE") / 1024))
size="$((size_kb / 1024)) MB"
[ "$size_kb" -lt 1024 ] && size="$size_kb KB"
DONE=1
if [ "$can_restrict" = 1 ]; then write_ok "$OUT_FILE written ($size), readable by root only."
else write_warn "$OUT_FILE written ($size). It is NOT protected by file permissions: anyone with the disk can read it."; fi

write_step '4/4  Next'
write_color "$FK_YELLOW" '   THE ARCHIVE IS NOT ENCRYPTED AND CONTAINS EVERY SECRET OF THIS FARM.'
write_color "$FK_YELLOW" '   Move it on an encrypted medium, never by e-mail or chat, and delete it afterwards.'
write_note 'On the new computer: unpack the kit, then'
write_note "   on a Mac:         sudo bash scripts/import-farm.sh --archive <path to $(basename "$OUT_FILE")>"
write_note "   on a Windows PC:  powershell -ExecutionPolicy Bypass -File .\\scripts\\import-farm.ps1 -Archive <path to $(basename "$OUT_FILE")>"
write_note 'Before starting the farm there, stop it here:  sudo bash scripts/uninstall.sh'
write_note 'Copy the archive to the encrypted medium first: uninstall.sh --remove-data deletes /opt/farm with everything in it.'
exit 0
