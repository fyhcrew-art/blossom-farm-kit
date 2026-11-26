#!/bin/bash
# Blossom farm kit - the first file of the one-command setup (macOS).
#
# Blossom CRM shows a command that downloads this file from the kit
# repository at one exact commit, compares its SHA-256 with the value Blossom
# printed, and only then runs it:
#
#     sudo bash blossom-bootstrap.sh --kit-commit <40 hex digits> --app-origin https://... --pairing-code XXXX-XXXX-XXXX-XXXX-XXXX
#
# What this file does, in order:
#   1. downloads the archive GitHub makes of the kit at that same commit;
#   2. looks at the list of what is in the archive before unpacking it
#      (nothing may lie outside the kit's own folder, nothing may be a link),
#      and unpacks it into a private folder;
#   3. compares the SHA-256 of MANIFEST.sha256 in it with the value written
#      below, and then the SHA-256 of every unpacked file with that list.
#      A file that is missing, changed or not on the list stops everything,
#      and so does a folder that holds no file of the list;
#   4. puts the kit into /opt/blossom-farm-kit (a kit that was there before
#      is kept as /opt/blossom-farm-kit.previous);
#   5. starts install.sh from there with the options it was given.
# So the command pins this file, this file pins the list, and the list pins
# every file of the kit. The archive itself has no pinned checksum (GitHub
# does not promise the same bytes each time); what is inside it has. When a
# check fails, everything downloaded is deleted and nothing is run.
#
# Options:
#   --kit-commit COMMIT   The commit of the kit to fetch (the command from
#                         Blossom carries it). Needed.
#   --dest FOLDER         Where the kit is put (default /opt/blossom-farm-kit).
#   --verify-only         Download, unpack into a temporary folder, check
#                         everything, say so and stop: nothing is installed
#                         and no administrator rights are needed.
# Every other option is handed to install.sh unchanged (see its first lines).
#
# The value of KIT_MANIFEST_SHA256 is written by tools/make-manifest.sh.
# Written for the bash that macOS ships (3.2).

set -u
KIT_REPOSITORY='fyhcrew-art/blossom-farm-kit'
KIT_ARCHIVE_URL='https://github.com/fyhcrew-art/blossom-farm-kit/archive'
KIT_MANIFEST_SHA256='c003825f8a505b51b1068fadadc207ba68285aad8b8d918830ec0883b1630dab'

fail() {
    printf '\nPROBLEM:    %s\n' "$1" >&2
    printf 'WHAT TO DO: %s\n\n' "$2" >&2
    exit 1
}

DEST='/opt/blossom-farm-kit'
KIT_COMMIT=''
VERIFY_ONLY=0
ARGS=()
while [ $# -gt 0 ]; do
    case $1 in
        --dest=*) DEST=${1#*=} ;;
        --dest) [ $# -ge 2 ] || fail 'The option --dest needs a folder.' 'Leave it out to use /opt/blossom-farm-kit.'; DEST=$2; shift ;;
        --kit-commit=*) KIT_COMMIT=${1#*=} ;;
        --kit-commit) [ $# -ge 2 ] || fail 'The option --kit-commit needs a commit.' 'Copy the command from Blossom again.'; KIT_COMMIT=$2; shift ;;
        --verify-only) VERIFY_ONLY=1 ;;
        *) ARGS=(${ARGS[@]+"${ARGS[@]}"} "$1") ;;
    esac
    shift
done

AGAIN='In Blossom open Phone Farm -> Farm setup -> Connect a computer and copy the command again.'
REPORT='Do not work around it. Run the command again; if it repeats, the download is being altered on the way or does not belong to this file: report it on the kit repository.'
case $KIT_MANIFEST_SHA256 in '' | *[!0-9a-f]*) fail 'This bootstrap file is damaged.' "$AGAIN" ;; esac
[ "${#KIT_MANIFEST_SHA256}" -eq 64 ] || fail 'This bootstrap file is damaged.' "$AGAIN"
case $KIT_ARCHIVE_URL in https://*) ;; *) fail 'This bootstrap file names a download address that is not https.' "$AGAIN" ;; esac
case $KIT_COMMIT in
    '') fail 'The command does not say which commit of the kit to fetch (--kit-commit).' "$AGAIN If you have the kit folder already, run   sudo bash install.sh   inside it." ;;
    *[!0-9a-f]*) fail 'The value of --kit-commit is not a commit: it must be 40 digits and letters a to f.' "$AGAIN" ;;
esac
[ "${#KIT_COMMIT}" -eq 40 ] || fail 'The value of --kit-commit is not a commit: it must be 40 digits and letters a to f.' "$AGAIN"
case $DEST in /*) ;; *) fail "The folder for the kit must be a full path: $DEST" 'Leave --dest out to use /opt/blossom-farm-kit.' ;; esac
for tool in curl tar awk find sort sed comm grep head; do
    command -v "$tool" > /dev/null 2>&1 || fail "The program $tool was not found." 'It is part of macOS. Run the command in Terminal on the Mac.'
done

sha256_of() {
    if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1" | awk '{ print $1 }'
    elif command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
    else openssl dgst -sha256 -r "$1" | awk '{ print $1 }'; fi
}

TOP="${KIT_REPOSITORY##*/}-$KIT_COMMIT"
URL="$KIT_ARCHIVE_URL/$KIT_COMMIT.tar.gz"

if [ "$VERIFY_ONLY" = 1 ]; then
    STAGE=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/blossom-kit.XXXXXX" 2> /dev/null) || fail 'Could not create a temporary folder.' 'Check the free space on the disk.'
else
    PARENT=$(dirname "$DEST")
    if [ ! -d "$PARENT" ]; then
        mkdir -p "$PARENT" 2> /dev/null || fail "Could not create $PARENT." 'Put sudo in front of the command, as Blossom shows it.'
    fi
    STAGE=$(umask 077 && mktemp -d "$PARENT/.blossom-kit.XXXXXX" 2> /dev/null) || fail "Could not write to $PARENT." 'Put sudo in front of the command, as Blossom shows it.'
fi
# shellcheck disable=SC2329  # runs as a trap
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo
echo "Blossom farm kit - fetching the kit (commit $KIT_COMMIT)"
code=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 -sS -L --max-redirs 5 --connect-timeout 30 --max-time 900 -o "$STAGE/kit.tar.gz" -w '%{http_code}' "$URL" 2> "$STAGE/curl.err")
status=$?
if [ "$status" -ne 0 ] || [ "$code" != 200 ]; then
    what="Downloading the kit failed (HTTP ${code:-0}) $(tr '\n' ' ' < "$STAGE/curl.err")"
    todo="Check the internet connection of this Mac and run the command again. Address: $URL"
    [ "$code" = 404 ] && todo="The kit repository does not have this commit. $AGAIN Address: $URL"
    fail "$what" "$todo"
fi

# The list of the archive, before anything is unpacked: only files and
# folders, all of them inside the one folder that belongs to this commit.
if ! tar -tzf "$STAGE/kit.tar.gz" > "$STAGE/names" 2> /dev/null || ! tar -tvzf "$STAGE/kit.tar.gz" > "$STAGE/listing" 2> /dev/null || [ ! -s "$STAGE/names" ]; then
    fail 'The kit archive is incomplete or damaged (the download was cut short?). Nothing was unpacked or run.' 'Run the command again.'
fi
bad=$(awk -v top="$TOP" '
    $0 == top || $0 == top "/" { next }
    index($0, top "/") != 1 { print; exit }
    /(^|\/)\.\.(\/|$)/ { print; exit }' "$STAGE/names") || fail 'The list of the kit archive could not be read. Nothing was unpacked or run.' 'Run the command again.'
[ -z "$bad" ] || fail "The kit archive holds something outside the folder of this commit ($bad). Nothing was unpacked or run." "$REPORT"
bad=$(awk '{ t = substr($0, 1, 1); if (t != "-" && t != "d") { print; exit } }' "$STAGE/listing") || fail 'The list of the kit archive could not be read. Nothing was unpacked or run.' 'Run the command again.'
[ -z "$bad" ] || fail 'The kit archive holds something that is neither a file nor a folder. Nothing was unpacked or run.' "$REPORT"

mkdir "$STAGE/unpacked" || fail "Could not write to $STAGE." 'Check the free space on the disk.'
tar -xzf "$STAGE/kit.tar.gz" -o -C "$STAGE/unpacked" 2> /dev/null || fail 'The kit archive could not be unpacked. Nothing was run.' 'Check the free space on the disk and run the command again.'
KIT="$STAGE/unpacked/$TOP"
[ -d "$KIT" ] || fail 'The kit archive does not hold the folder of this commit. Nothing was run.' "$REPORT"

# Every file against the list, and the list against the value in this file.
[ -f "$KIT/MANIFEST.sha256" ] || fail 'The kit that was downloaded has no MANIFEST.sha256: it is not a kit this file can check. Nothing was run.' "$AGAIN"
got=$(sha256_of "$KIT/MANIFEST.sha256")
if [ "$got" != "$KIT_MANIFEST_SHA256" ]; then
    fail "The list of files of the kit that was downloaded is not the one this file expects (expected $KIT_MANIFEST_SHA256, got $got): the kit is not the one of this command, or it was changed. Nothing was run." "$REPORT"
fi
if LC_ALL=C grep -q -v -E '^[0-9a-f]{64}  [A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' "$KIT/MANIFEST.sha256" || LC_ALL=C grep -q -E '(^|[ /])\.\.?(/|$)' "$KIT/MANIFEST.sha256"; then
    fail 'The list of files of the kit has a line that is not a checksum and a file name. Nothing was run.' "$REPORT"
fi
if [ -n "$(cd "$KIT" && find . ! -type f ! -type d -print | head -n 1)" ]; then
    fail 'The kit that was unpacked holds something that is neither a file nor a folder. Nothing was run.' "$REPORT"
fi
count=0
while read -r want name; do
    if [ ! -f "$KIT/$name" ]; then
        fail "The kit that was downloaded lacks the file $name. Nothing was run." "$REPORT"
    fi
    got=$(sha256_of "$KIT/$name")
    if [ "$got" != "$want" ]; then
        fail "The file $name of the kit that was downloaded is not the one the list names (expected SHA-256 $want, got $got). Nothing was run." "$REPORT"
    fi
    count=$((count + 1))
done < "$KIT/MANIFEST.sha256"
# Nothing may be there that the list does not name: no file, and no folder
# that holds no file of the list. Four files cannot be on the list
# (tools/make-manifest.sh says why); they are not part of the installed kit
# and are removed. A step that cannot be carried out stops everything: it
# never counts as "nothing found".
cannot_compare() { fail 'The files of the kit that was downloaded could not be compared with its list. Nothing was run.' 'Check the free space on the disk and run the command again.'; }
{ awk '{ print $2 }' "$KIT/MANIFEST.sha256" && printf 'MANIFEST.sha256\nbootstrap.sh\nbootstrap.ps1\npairing.json\n'; } > "$STAGE/list.names" || cannot_compare
LC_ALL=C sort -u "$STAGE/list.names" > "$STAGE/allowed" || cannot_compare
(cd "$KIT" && find . -type f -print) > "$STAGE/found" || cannot_compare
sed 's|^\./||' "$STAGE/found" > "$STAGE/found.names" || cannot_compare
LC_ALL=C sort "$STAGE/found.names" > "$STAGE/found.sorted" || cannot_compare
LC_ALL=C comm -23 "$STAGE/found.sorted" "$STAGE/allowed" > "$STAGE/extra" || cannot_compare
extra=$(head -n 1 "$STAGE/extra")
[ -z "$extra" ] || fail "The kit that was downloaded holds a file that its list does not name: $extra. Nothing was run." "$REPORT"
awk '{ n = split($2, part, "/"); d = ""; for (i = 1; i < n; i++) { d = (i == 1 ? part[i] : d "/" part[i]); print d } }' "$KIT/MANIFEST.sha256" > "$STAGE/list.names" || cannot_compare
LC_ALL=C sort -u "$STAGE/list.names" > "$STAGE/allowed" || cannot_compare
(cd "$KIT" && find . -type d -print) > "$STAGE/found" || cannot_compare
sed -e '/^\.$/d' -e 's|^\./||' "$STAGE/found" > "$STAGE/found.names" || cannot_compare
LC_ALL=C sort "$STAGE/found.names" > "$STAGE/found.sorted" || cannot_compare
LC_ALL=C comm -23 "$STAGE/found.sorted" "$STAGE/allowed" > "$STAGE/extra" || cannot_compare
extra=$(head -n 1 "$STAGE/extra")
[ -z "$extra" ] || fail "The kit that was downloaded holds a folder that its list names no file for: $extra. Nothing was run." "$REPORT"
rm -f "$KIT/bootstrap.sh" "$KIT/bootstrap.ps1" "$KIT/pairing.json"
echo "   [ok]   The kit was downloaded and every one of its $count files has the SHA-256 this command pins."

if [ "$VERIFY_ONLY" = 1 ]; then
    echo '   [ok]   Checked only (--verify-only): nothing was installed or changed.'
    exit 0
fi

[ -f "$KIT/install.sh" ] || fail 'The kit does not contain install.sh.' 'Report it on the kit repository.'
if [ "$(id -u)" = 0 ]; then
    # Root runs these scripts: nobody else may change them.
    if ! { chown -R 0:0 "$KIT" && chmod -R u=rwX,go=rX "$KIT"; }; then
        fail 'Could not set the permissions of the kit folder.' 'Run the command again.'
    fi
fi
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    rm -rf "$DEST.previous"
    mv "$DEST" "$DEST.previous" || fail "Could not move the kit that is in $DEST out of the way." "Rename it yourself:   sudo mv $DEST $DEST.old   and run the command again."
fi
mv "$KIT" "$DEST" || fail "Could not put the kit into $DEST." 'Run the command again.'
cleanup
trap - EXIT
echo "   [ok]   The kit is in $DEST. Keep the folder: the maintenance scripts are in it."

exec /bin/bash "$DEST/install.sh" ${ARGS[@]+"${ARGS[@]}"}
