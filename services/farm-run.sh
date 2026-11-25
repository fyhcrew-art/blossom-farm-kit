#!/bin/bash
# Blossom farm kit - starts one farm program under launchd.
#
#   farm-run.sh --log <file> [--wait <port>]... [--wait-seconds <n>]
#               [--log-max-kb <n>] [--log-keep <n>] -- <program> [arguments...]
#
# launchd starts everything at once and knows no "start after". This wrapper
# gives the farm its start order: it waits until the local ports named with
# --wait accept a connection (the hub waits for MongoDB, the provider and
# keep-available wait for the hub) and only then becomes the program. When a
# port does not open in time it ends with status 1, and launchd starts it
# again a few seconds later.
#
# It also gives the program its log: standard output and error are appended
# to --log line by line, opening the file for every line. When the file has
# grown past --log-max-kb it is put aside as <log>.1.gz (older ones move to
# .2.gz and so on; --log-keep of them are kept). The rotation is done here,
# by the account the program itself runs as, and by nothing with more rights:
# the log folder of the farm services can be written by their account, and a
# rotation run by root in such a folder could be led to another file.
#
# bash 3.2 (the bash of macOS). Nothing secret is passed to this script.

set -u
umask 027

log=''
wait_seconds=120
ports=''
log_max_kb=10240
log_keep=10
while [ $# -gt 0 ]; do
    case $1 in
        --log) log=${2:-}; shift 2 ;;
        --wait) ports="$ports ${2:-}"; shift 2 ;;
        --wait-seconds) wait_seconds=${2:-}; shift 2 ;;
        --log-max-kb) log_max_kb=${2:-}; shift 2 ;;
        --log-keep) log_keep=${2:-}; shift 2 ;;
        --) shift; break ;;
        *) echo "farm-run.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
if [ -z "$log" ] || [ $# -eq 0 ]; then
    echo 'usage: farm-run.sh --log <file> [--wait <port>]... [--wait-seconds <n>] [--log-max-kb <n>] [--log-keep <n>] -- <program> [arguments...]' >&2
    exit 2
fi
case $wait_seconds in '' | *[!0-9]*) wait_seconds=120 ;; esac
case $log_max_kb in '' | *[!0-9]* | 0) log_max_kb=10240 ;; esac
case $log_keep in '' | *[!0-9]* | 0) log_keep=10 ;; esac

rotate_log() {
    # Puts the log aside when it is larger than the limit.
    local size i
    size=$(wc -c < "$log" 2> /dev/null) || return 0
    size=${size//[!0-9]/}
    [ -n "$size" ] || return 0
    [ "$size" -ge $((log_max_kb * 1024)) ] || return 0
    rm -f "$log.$log_keep.gz"
    i=$((log_keep - 1))
    while [ "$i" -ge 1 ]; do
        [ -f "$log.$i.gz" ] && mv -f "$log.$i.gz" "$log.$((i + 1)).gz"
        i=$((i - 1))
    done
    mv -f "$log" "$log.1" 2> /dev/null || return 0
    gzip -f "$log.1" > /dev/null 2>&1
    return 0
}

# The log writer: a child of this process that ends when the program does.
exec > >(
    lines=0
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" >> "$log"
        lines=$((lines + 1))
        if [ "$lines" -ge 200 ]; then lines=0; rotate_log; fi
    done
) 2>&1

port_open() {
    if command -v nc > /dev/null 2>&1; then
        nc -z -w 2 127.0.0.1 "$1" > /dev/null 2>&1
    else
        (exec 3<> "/dev/tcp/127.0.0.1/$1") > /dev/null 2>&1
    fi
}

for port in $ports; do
    case $port in '' | *[!0-9]*) echo "farm-run.sh: not a port: $port"; exit 2 ;; esac
    waited=0
    until port_open "$port"; do
        if [ "$waited" -ge "$wait_seconds" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [farm-run] still waiting for 127.0.0.1:$port after ${wait_seconds} s; $(basename "$1") was not started, trying again"
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
done

exec "$@"
