#!/bin/bash
# Blossom farm kit - the first file of the one-command setup (macOS).
#
# Blossom CRM shows a command that downloads this file from a kit release,
# compares its SHA-256 with the value Blossom printed, and only then runs it:
#
#     sudo bash blossom-bootstrap.sh --app-origin https://... --pairing-code XXXX-XXXX-XXXX-XXXX-XXXX
#
# What this file does, in order:
#   1. downloads SHA256SUMS of the same kit release and compares its SHA-256
#      with the value written into this file when the release was made;
#   2. downloads the kit archive and compares its SHA-256 with the one in
#      SHA256SUMS;
#   3. unpacks the kit to /opt/blossom-farm-kit (a kit that was there before
#      is kept as /opt/blossom-farm-kit.previous);
#   4. starts install.sh from there with the options it was given.
# So the command pins this file, this file pins SHA256SUMS, and SHA256SUMS
# pins the archive. A file that fails its check is deleted, never unpacked,
# never run.
#
# Options:
#   --dest FOLDER   Where the kit is unpacked (default /opt/blossom-farm-kit).
# Every other option is handed to install.sh unchanged (see its first lines).
#
# The copy of this file in the source tree is a template: the four values
# below are filled in when a kit release is made (docs/RELEASING.md), and the
# template refuses to run. Written for the bash that macOS ships (3.2).

set -u
KIT_TAG='@KIT_TAG@'
KIT_BASE_URL='@KIT_BASE_URL@'
KIT_ARCHIVE='@KIT_ARCHIVE@'
KIT_SUMS_SHA256='@KIT_SUMS_SHA256@'

fail() {
    printf '\nPROBLEM:    %s\n' "$1" >&2
    printf 'WHAT TO DO: %s\n\n' "$2" >&2
    exit 1
}

DEST='/opt/blossom-farm-kit'
ARGS=()
while [ $# -gt 0 ]; do
    case $1 in
        --dest=*) DEST=${1#*=} ;;
        --dest) [ $# -ge 2 ] || fail 'The option --dest needs a folder.' 'Leave it out to use /opt/blossom-farm-kit.'; DEST=$2; shift ;;
        *) ARGS=(${ARGS[@]+"${ARGS[@]}"} "$1") ;;
    esac
    shift
done

AGAIN='In Blossom open Phone Farm -> Farm setup -> Connect a computer and copy the command again.'
case $KIT_SUMS_SHA256 in
    '' | *[!0-9a-f]*) fail 'This is the template of the bootstrap file, not the one of a kit release.' "$AGAIN If you have the kit folder already, run   sudo bash install.sh   inside it." ;;
esac
[ "${#KIT_SUMS_SHA256}" -eq 64 ] || fail 'This bootstrap file is damaged.' "$AGAIN"
case $KIT_BASE_URL in https://*) ;; *) fail 'This bootstrap file names a download address that is not https.' "$AGAIN" ;; esac
case $KIT_ARCHIVE in '' | */* | *..*) fail 'This bootstrap file is damaged.' "$AGAIN" ;; esac
case $DEST in /*) ;; *) fail "The folder for the kit must be a full path: $DEST" 'Leave --dest out to use /opt/blossom-farm-kit.' ;; esac
for tool in curl unzip; do
    command -v "$tool" > /dev/null 2>&1 || fail "The program $tool was not found." 'It is part of macOS. Run the command in Terminal on the Mac.'
done

sha256_of() {
    if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1" | awk '{ print $1 }'
    elif command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
    else openssl dgst -sha256 -r "$1" | awk '{ print $1 }'; fi
}

fetch() {
    # fetch <file name of the release> <where to put it>
    local code
    code=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 -sS -L --max-redirs 5 --connect-timeout 30 --max-time 900 -o "$2" -w '%{http_code}' "$KIT_BASE_URL/$1" 2> "$STAGE/curl.err")
    if [ "$code" != 200 ]; then
        rm -f "$2"
        fail "Downloading $1 of the kit release $KIT_TAG failed (HTTP ${code:-0}) $(tr '\n' ' ' < "$STAGE/curl.err")" "Check the internet connection of this Mac and run the command again. Address: $KIT_BASE_URL/$1"
    fi
}

PARENT=$(dirname "$DEST")
if [ ! -d "$PARENT" ]; then
    mkdir -p "$PARENT" 2> /dev/null || fail "Could not create $PARENT." 'Put sudo in front of the command, as Blossom shows it.'
fi
STAGE=$(umask 077 && mktemp -d "$PARENT/.blossom-kit.XXXXXX" 2> /dev/null) || fail "Could not write to $PARENT." 'Put sudo in front of the command, as Blossom shows it.'
# shellcheck disable=SC2329  # runs as a trap
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo
echo "Blossom farm kit - fetching the kit ($KIT_TAG)"
fetch SHA256SUMS "$STAGE/SHA256SUMS"
got=$(sha256_of "$STAGE/SHA256SUMS")
if [ "$got" != "$KIT_SUMS_SHA256" ]; then
    fail "The list of checksums of the kit release is not the one this file expects (expected $KIT_SUMS_SHA256, got $got). Nothing was unpacked or run." "Do not work around it. Run the command again; if it repeats, the download is being altered on the way or the release was changed: report it on the kit repository."
fi
want=$(awk -v f="$KIT_ARCHIVE" '$2 == f || $2 == "*" f { print $1; exit }' "$STAGE/SHA256SUMS")
case $want in '' | *[!0-9a-f]*) fail "The list of checksums of the kit release does not name $KIT_ARCHIVE." 'Report it on the kit repository.' ;; esac
fetch "$KIT_ARCHIVE" "$STAGE/kit.zip"
got=$(sha256_of "$STAGE/kit.zip")
if [ "$got" != "$want" ]; then
    rm -f "$STAGE/kit.zip"
    fail "The kit archive was downloaded but its SHA-256 is wrong (expected $want, got $got). The file was deleted; nothing was unpacked or run." "Do not work around it. Run the command again; if it repeats, the download is being altered on the way or the release was changed: report it on the kit repository."
fi
echo "   [ok]   $KIT_ARCHIVE downloaded, SHA-256 verified."

mkdir "$STAGE/unpacked" || fail "Could not write to $STAGE." 'Check the free space on the disk.'
unzip -q "$STAGE/kit.zip" -d "$STAGE/unpacked" || fail 'The kit archive could not be unpacked.' 'Check the free space on the disk and run the command again.'
TOP=''
for d in "$STAGE/unpacked"/*; do
    [ -d "$d" ] && [ -f "$d/install.sh" ] && TOP=$d
done
[ -n "$TOP" ] || fail 'The kit archive does not contain install.sh.' 'Report it on the kit repository.'
if [ "$(id -u)" = 0 ]; then
    # Root runs these scripts: nobody else may change them.
    if ! { chown -R 0:0 "$TOP" && chmod -R u=rwX,go=rX "$TOP"; }; then
        fail 'Could not set the permissions of the kit folder.' 'Run the command again.'
    fi
fi
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    rm -rf "$DEST.previous"
    mv "$DEST" "$DEST.previous" || fail "Could not move the kit that is in $DEST out of the way." "Rename it yourself:   sudo mv $DEST $DEST.old   and run the command again."
fi
mv "$TOP" "$DEST" || fail "Could not put the kit into $DEST." 'Run the command again.'
cleanup
trap - EXIT
echo "   [ok]   The kit is in $DEST. Keep the folder: the maintenance scripts are in it."

exec /bin/bash "$DEST/install.sh" ${ARGS[@]+"${ARGS[@]}"}
