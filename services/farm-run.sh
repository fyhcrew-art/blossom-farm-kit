#!/bin/bash
# Blossom farm kit - starts one farm program under launchd.
#
#   farm-run.sh --log <file> [--wait <port>]... [--wait-seconds <n>] -- <program> [arguments...]
#
# launchd starts everything at once and knows no "start after". This wrapper
# gives the farm its start order: it waits until the local ports named with
# --wait accept a connection (the hub waits for MongoDB, the provider and
# keep-available wait for the hub) and only then becomes the program. When a
# port does not open in time it ends with status 1, and launchd starts it
# again a few seconds later.
#
# It also gives the program its log: standard output and error are appended
# to --log line by line, opening the file for every line. newsyslog can
# therefore rotate the file at any time without the program being restarted.
#
# bash 3.2 (the bash of macOS). Nothing secret is passed to this script.

set -u
umask 027

log=''
wait_seconds=120
ports=''
while [ $# -gt 0 ]; do
    case $1 in
        --log) log=${2:-}; shift 2 ;;
        --wait) ports="$ports ${2:-}"; shift 2 ;;
        --wait-seconds) wait_seconds=${2:-}; shift 2 ;;
        --) shift; break ;;
        *) echo "farm-run.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
if [ -z "$log" ] || [ $# -eq 0 ]; then
    echo 'usage: farm-run.sh --log <file> [--wait <port>]... [--wait-seconds <n>] -- <program> [arguments...]' >&2
    exit 2
fi
case $wait_seconds in '' | *[!0-9]*) wait_seconds=120 ;; esac

# The log writer: a child of this process that ends when the program does.
exec > >(while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "$line" >> "$log"; done) 2>&1

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
