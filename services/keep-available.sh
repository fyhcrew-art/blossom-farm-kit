#!/bin/bash
# Blossom farm kit - keep-available (macOS; the same job as keep-available.ps1).
#
# A GADS hub only marks a phone "available" while somebody is subscribed to its
# stream of available devices (the hub's own web page does that while it is
# open). A farm that is driven through Blossom CRM has nobody sitting on that
# page, and the hub then answers every tap with 422 "device is not available".
# This script stays subscribed, for every workspace its hub user can see.
#
# - Talks to the hub on this computer (http://127.0.0.1:<port>), never through
#   the public tunnel.
# - Reads the hub address and its own hub login from a file that only root and
#   the farm's service account can read. Nothing secret is passed on a command
#   line (curl gets it through its standard input) or written to the log.
# - Its hub login is a dedicated user with the plain "user" role (not admin).
# - Reconnects with a growing pause (2 s up to 60 s) when the hub is away.
#
# Runs as the launchd service blossom-farm.keep-available (created by
# install.sh), as the service account. bash 3.2 (the bash of macOS) and curl.
#
#   keep-available.sh [configuration file]
#   keep-available.sh --check-config <configuration file>   reads the file and stops

set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
JSON_AWK=$SELF_DIR/json.awk
[ -f "$JSON_AWK" ] || JSON_AWK=$SELF_DIR/../lib/json.awk

CHECK_ONLY=0
if [ "${1:-}" = '--check-config' ]; then CHECK_ONLY=1; shift; fi
CONFIG_FILE=${1:-/opt/farm/config/keep-available.json}

REFRESH_SECONDS=900   # new workspaces, and before the token gets old
STALL_SECONDS=60      # the hub writes every second; a long silence means a dead connection
POLL_SECONDS=5

HUB_URL=''; HUB_USER=''; HUB_PASSWORD=''
TOKEN=''
PIDS=''

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [keep-available] $1"; }

json_get() {
    # json_get <text> <path>
    printf '%s' "$1" | LC_ALL=C awk -f "$JSON_AWK" 2> /dev/null | LC_ALL=C awk -F '\t' -v p="$2" '$1 == p { sub(/^[^\t]*\t/, ""); print; exit }'
}

json_string() {
    local t=$1
    t=${t//\\/\\\\}
    t=${t//\"/\\\"}
    printf '"%s"' "$t"
}

config_quote() {
    # A value for curl's configuration syntax.
    local t=$1
    t=${t//\\/\\\\}
    t=${t//\"/\\\"}
    printf '"%s"' "$t"
}

read_config() {
    local text
    if [ ! -r "$CONFIG_FILE" ]; then
        log "configuration file not found or not readable: $CONFIG_FILE. Run install.sh (or scripts/rotate-secrets.sh --keep-available) to create it."
        return 1
    fi
    text=$(cat "$CONFIG_FILE")
    HUB_URL=$(json_get "$text" hubUrl)
    HUB_USER=$(json_get "$text" username)
    HUB_PASSWORD=$(json_get "$text" password)
    if [ -z "$HUB_URL" ] || [ -z "$HUB_USER" ] || [ -z "$HUB_PASSWORD" ]; then
        log "the configuration file $CONFIG_FILE must contain hubUrl, username and password."
        return 1
    fi
    HUB_URL=${HUB_URL%/}
    case $HUB_URL in
        http://127.0.0.1 | http://127.0.0.1:* | http://localhost | http://localhost:*) ;;
        *) log 'hubUrl must be the hub on this computer, for example http://127.0.0.1:10000 (not the public address).'; return 1 ;;
    esac
    case ${HUB_URL#http://} in */* | *[!A-Za-z0-9.:]*) log 'hubUrl must be the hub on this computer, for example http://127.0.0.1:10000 (not the public address).'; return 1 ;; esac
    return 0
}

hub_call() {
    # hub_call <curl configuration text>   prints the answer; the last line is the HTTP status
    printf '%s' "$1" | curl -q -sS --noproxy '*' --max-time 20 -w '\n%{http_code}' -K - 2> /dev/null
}

sign_in() {
    local answer status body
    TOKEN=''
    body="{\"username\":$(json_string "$HUB_USER"),\"password\":$(json_string "$HUB_PASSWORD")}"
    answer=$(hub_call "url = $(config_quote "$HUB_URL/authenticate")
request = \"POST\"
header = \"Content-Type: application/json\"
data-binary = $(config_quote "$body")
")
    status=${answer##*$'\n'}
    [ "$status" = 200 ] || return 1
    answer=${answer%$'\n'*}
    TOKEN=$(json_get "$answer" result.access_token)
    [ -n "$TOKEN" ] || TOKEN=$(json_get "$answer" access_token)
    [ -n "$TOKEN" ]
}

workspace_ids() {
    # Prints the ids of the workspaces the user can see, one per line.
    local answer status
    answer=$(hub_call "url = $(config_quote "$HUB_URL/workspaces?page=1&limit=100")
header = $(config_quote "Authorization: Bearer $TOKEN")
")
    status=${answer##*$'\n'}
    [ "$status" = 200 ] || return 0
    printf '%s' "${answer%$'\n'*}" | LC_ALL=C awk -f "$JSON_AWK" 2> /dev/null | LC_ALL=C awk -F '\t' '
        { n = split($1, p, ".")
          if (p[n] != "id" && p[n] != "_id") next
          if (!((n == 4 && p[1] == "result" && p[2] == "workspaces") || (n == 3 && p[1] == "result"))) next
          key = p[n - 1]
          if (!(key in seen) || p[n] == "id") { seen[key] = 1; id[key] = $2 } }
        END { for (k in id) if (id[k] != "") print id[k] }'
}

stop_streams() {
    local pid
    for pid in $PIDS; do kill "$pid" 2> /dev/null; done
    for pid in $PIDS; do wait "$pid" 2> /dev/null; done
    PIDS=''
}

# One pass: sign in, find the workspaces, hold one stream per workspace until
# one of them ends or the list of workspaces is due for a refresh. Status 0
# for a planned refresh.
subscribe() {
    local ids id count=0 pid started alive
    if ! sign_in; then log 'the hub refused the login of the keep-available user, or does not answer'; return 1; fi
    ids=$(workspace_ids)
    if [ -z "$ids" ]; then log 'the keep-available user sees no workspace'; return 1; fi
    PIDS=''
    for id in $ids; do
        case $id in *[!A-Za-z0-9_-]*) continue ;; esac
        # One stream of the hub, held open by curl and thrown away as it
        # arrives. --speed-time: curl itself ends a stream that carried no
        # data for a minute.
        printf 'url = %s\nheader = %s\n' "$(config_quote "$HUB_URL/available-devices?workspaceId=$id")" "$(config_quote "Authorization: Bearer $TOKEN")" |
            curl -q -sS -N --noproxy '*' --fail --speed-limit 1 --speed-time "$STALL_SECONDS" -o /dev/null -K - 2> /dev/null &
        PIDS="$PIDS $!"
        count=$((count + 1))
    done
    TOKEN=''
    if [ "$count" -eq 0 ]; then log 'the keep-available user sees no workspace'; return 1; fi
    log "subscribed to $count workspace(s)"
    started=$SECONDS
    while [ $((SECONDS - started)) -lt "$REFRESH_SECONDS" ]; do
        sleep "$POLL_SECONDS" &
        wait $!
        alive=0
        for pid in $PIDS; do kill -0 "$pid" 2> /dev/null && alive=$((alive + 1)); done
        if [ "$alive" -ne "$count" ]; then
            log "a stream ended (the hub closed it, or no data for $STALL_SECONDS s), reconnecting"
            stop_streams
            return 1
        fi
    done
    stop_streams
    return 0
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    read_config || exit 1
    log "configuration is readable: hub $HUB_URL, user $HUB_USER"
    exit 0
fi

trap 'stop_streams; exit 0' TERM INT
log 'starting'
pause=2
while true; do
    if read_config && subscribe; then
        pause=2
    else
        pause=$((pause * 2))
        [ "$pause" -gt 60 ] && pause=60
    fi
    HUB_PASSWORD=''
    sleep "$pause" &
    wait $!
done
