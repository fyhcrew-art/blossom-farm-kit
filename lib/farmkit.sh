# Blossom farm kit - shared functions for macOS (the mirror of lib/FarmKit.psm1).
#
# Sourced by install.sh and scripts/*.sh; never run by itself.
#
# Written for the bash that macOS ships, version 3.2: no associative arrays,
# no mapfile, no ${var,,}, no "wait -n", and an empty array is never expanded
# without the ${a[@]+"${a[@]}"} guard. ASCII only.
#
# The functions in the first half are pure (no system access) and are covered
# by tests/farmkit.test.sh. A function named like a PowerShell one does the
# same job: Test-FarmHostname -> test_farm_hostname, and so on.
#
# How results come back, since bash has no return values:
#   * pure functions print their result and never stop the script, so they are
#     safe inside $( );
#   * functions that touch the system set the variables named in their
#     comment, and may call stop_farm, which ends the script. Never call
#     those inside $( ): the "exit" would only leave the subshell.

# shellcheck shell=bash
# The variables set here are used by the scripts that source this file.
# shellcheck disable=SC2034

FARMKIT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FARMKIT_JSON_AWK=${FARMKIT_JSON_AWK:-$FARMKIT_LIB_DIR/json.awk}

FARM_SERVICE_USER='_blossomfarm'
FARM_SERVICE_GROUP='_blossomfarm'
FARM_LABEL_PREFIX='blossom-farm'
FARM_PF_ANCHOR='com.apple/blossom-farm'
FARM_LAUNCHD_DIR='/Library/LaunchDaemons'
FARM_NEWSYSLOG_FILE='/etc/newsyslog.d/blossom-farm.conf'

# ---------------------------------------------------------------------------
# Errors and output: every failure says what went wrong and what to do.
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    FK_RED=$'\033[31m'; FK_GREEN=$'\033[32m'; FK_YELLOW=$'\033[33m'; FK_CYAN=$'\033[36m'; FK_GRAY=$'\033[90m'; FK_OFF=$'\033[0m'
else
    FK_RED=''; FK_GREEN=''; FK_YELLOW=''; FK_CYAN=''; FK_GRAY=''; FK_OFF=''
fi

write_step() { printf '\n%s== %s ==%s\n' "$FK_CYAN" "$1" "$FK_OFF"; }
write_ok() { printf '%s   [ok]   %s%s\n' "$FK_GREEN" "$1" "$FK_OFF"; }
write_note() { printf '   %s\n' "$1"; }
write_warn() { printf '%s   [warn] %s%s\n' "$FK_YELLOW" "$1" "$FK_OFF"; }
write_color() { printf '%s%s%s\n' "$1" "$2" "$FK_OFF"; }

write_farm_failure() {
    # $1 problem, $2 what to do. Never prints secrets: callers must not put
    # any into these two texts.
    local what=$2
    if [ -z "$what" ]; then
        what='This error was not expected. Run the script again; it is safe to re-run. If it stops at the same place, copy the PROBLEM line and open an issue on the kit repository. If a log helps, add the output of scripts/status.sh --logs (it masks session tokens and host names); never post a file from /opt/farm/logs itself, and remove passwords first.'
    fi
    printf '\n%sPROBLEM:    %s%s\n' "$FK_RED" "$1" "$FK_OFF"
    printf '%sWHAT TO DO: %s%s\n\n' "$FK_YELLOW" "$what" "$FK_OFF"
}

stop_farm() {
    # Stops the running script with a message and a "what to do". The script's
    # EXIT trap (when it has one) still runs.
    write_farm_failure "$1" "${2:-}"
    exit 1
}

# ---------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------

new_random_secret() {
    # new_random_secret [bytes=32] [hex|base64url]
    # A secret from the operating system's cryptographic random generator.
    # Hex: 2 characters per byte. Base64Url: about 1.33 characters per byte.
    local bytes=${1:-32} format=${2:-hex}
    case $bytes in '' | *[!0-9]*) return 2 ;; esac
    if [ "$bytes" -lt 16 ] || [ "$bytes" -gt 128 ]; then return 2; fi
    case $format in
        hex) head -c "$bytes" /dev/urandom | od -An -v -tx1 | tr -d ' \n' ;;
        base64url) head -c "$bytes" /dev/urandom | base64 | tr -d '=\n' | tr '+/' '-_' ;;
        *) return 2 ;;
    esac
}

to_lower() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }

trim_text() {
    local t=$1
    t=${t#"${t%%[![:space:]]*}"}
    t=${t%"${t##*[![:space:]]}"}
    printf '%s' "$t"
}

test_password_strength() {
    # test_password_strength <password> [forbidden word...]
    # Prints one line per problem; no output means the password is accepted.
    local LC_ALL=C
    local password=$1; shift
    local classes=0 lower w wl i c seen='' distinct=0 re
    [ "${#password}" -lt 14 ] && echo 'It must be at least 14 characters long.'
    [ "${#password}" -gt 128 ] && echo 'It must be at most 128 characters long.'
    re='[a-z]'; [[ $password =~ $re ]] && classes=$((classes + 1))
    re='[A-Z]'; [[ $password =~ $re ]] && classes=$((classes + 1))
    re='[0-9]'; [[ $password =~ $re ]] && classes=$((classes + 1))
    re='[^a-zA-Z0-9]'; [[ $password =~ $re ]] && classes=$((classes + 1))
    [ "$classes" -lt 3 ] && echo 'It must mix at least three of: lower-case letters, upper-case letters, digits, other characters.'
    case $password in [[:space:]]* | *[[:space:]]) echo 'It must not start or end with a space.' ;; esac
    case $password in *[[:cntrl:]]*) echo 'It must not contain control characters.' ;; esac
    lower=$(to_lower "$password")
    for w in password admin gads blossom qwerty 123456 letmein welcome "$@"; do
        [ "${#w}" -ge 4 ] || continue
        wl=$(to_lower "$w")
        case $lower in *"$wl"*) echo "It must not contain \"$w\"." ;; esac
    done
    if [ "${#password}" -gt 0 ]; then
        i=0
        while [ "$i" -lt "${#password}" ] && [ "$distinct" -lt 8 ]; do
            c=${password:$i:1}
            case $seen in *"$c"*) ;; *) seen=$seen$c; distinct=$((distinct + 1)) ;; esac
            i=$((i + 1))
        done
        [ "$distinct" -lt 8 ] && echo 'It repeats too few different characters (at least 8 different ones).'
    fi
    return 0
}

test_farm_hostname() {
    # Prints nothing when the name can be used as a public tunnel host name,
    # otherwise the reason it cannot.
    local LC_ALL=C
    local n re label last rest count
    n=$(trim_text "$1")
    if [ -z "$n" ]; then echo 'The host name is empty.'; return 0; fi
    case $n in *://*) echo 'Enter the host name only, without https:// in front.'; return 0 ;; esac
    case $n in *[/\\?#@:[:space:]]*) echo 'Enter the host name only: no path, port, spaces or other characters.'; return 0 ;; esac
    case $n in *[A-Z]*) echo 'Use lower-case letters only.'; return 0 ;; esac
    if [ "${#n}" -gt 253 ]; then echo 'The host name is too long.'; return 0; fi
    re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
    if [[ $n =~ $re ]]; then echo 'An IP address cannot be used; a host name under your own domain is needed.'; return 0; fi
    count=1; rest=$n
    while [ "$rest" != "${rest#*.}" ]; do rest=${rest#*.}; count=$((count + 1)); done
    if [ "$count" -lt 3 ]; then echo 'Use a sub-domain of your domain, for example farm-hub.example.com (not the bare domain).'; return 0; fi
    rest=$n.
    re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
    while [ -n "$rest" ]; do
        label=${rest%%.*}; rest=${rest#*.}
        if [ "${#label}" -lt 1 ] || [ "${#label}" -gt 63 ]; then echo 'Every part between the dots must be 1 to 63 characters long.'; return 0; fi
        if ! [[ $label =~ $re ]]; then echo 'Only letters a-z, digits and hyphens are allowed, and no part may start or end with a hyphen.'; return 0; fi
    done
    last=${n##*.}
    re='^[0-9]+$'
    if [[ $last =~ $re ]]; then echo 'The last part of the host name cannot be a number.'; return 0; fi
    case $last in
        local | localhost | internal | lan | home | corp | intranet | test | invalid | example)
            echo 'This name only works inside a private network. Use a name under a real domain that you own.'; return 0 ;;
    esac
    re='(^|\.)example\.(com|net|org)$'
    if [[ $n =~ $re ]]; then echo 'example.com is a placeholder. Use a name under a domain that you own.'; return 0; fi
    case $n in *.cfargotunnel.com | *.trycloudflare.com) echo 'Use a name under your own domain, not a Cloudflare-internal name.'; return 0 ;; esac
    return 0
}

test_farm_hostname_set() {
    # test_farm_hostname_set <hub> <provider> <restart>
    # Checks the three names together. Prints one line per problem.
    local reason a b c
    reason=$(test_farm_hostname "$1"); [ -n "$reason" ] && echo "Hub host name: $reason"
    reason=$(test_farm_hostname "$2"); [ -n "$reason" ] && echo "Provider host name: $reason"
    reason=$(test_farm_hostname "$3"); [ -n "$reason" ] && echo "Restart service host name: $reason"
    a=$(trim_text "$1"); b=$(trim_text "$2"); c=$(trim_text "$3")
    if [ "$a" = "$b" ] || [ "$a" = "$c" ] || [ "$b" = "$c" ]; then
        echo 'The three host names must be different from each other.'
    fi
    return 0
}

test_provider_nickname() {
    # Prints nothing when usable, otherwise the reason.
    local LC_ALL=C
    local re='^[A-Za-z][A-Za-z0-9_-]{1,31}$'
    if ! [[ $1 =~ $re ]]; then
        echo 'Use 2 to 32 characters: letters, digits, "-" and "_", starting with a letter (for example Provider1). It becomes a folder name and part of an address.'
    fi
    return 0
}

_fk_ipv4_public() {
    # Status 0 when the dotted IPv4 address is a public internet address.
    local LC_ALL=C
    local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
    [[ $1 =~ $re ]] || return 1
    local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]})) c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
    if [ "$a" -gt 255 ] || [ "$b" -gt 255 ] || [ "$c" -gt 255 ] || [ "$d" -gt 255 ]; then return 1; fi
    if [ "$a" -eq 0 ] || [ "$a" -eq 10 ] || [ "$a" -eq 127 ]; then return 1; fi
    if [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then return 1; fi   # CGNAT
    if [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; then return 1; fi                       # link-local
    if [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; then return 1; fi
    if [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; then return 1; fi
    if [ "$a" -eq 192 ] && [ "$b" -eq 0 ] && [ "$c" -eq 0 ]; then return 1; fi
    if [ "$a" -eq 192 ] && [ "$b" -eq 0 ] && [ "$c" -eq 2 ]; then return 1; fi       # documentation
    if [ "$a" -eq 198 ] && { [ "$b" -eq 18 ] || [ "$b" -eq 19 ]; }; then return 1; fi # benchmarking
    if [ "$a" -eq 198 ] && [ "$b" -eq 51 ] && [ "$c" -eq 100 ]; then return 1; fi
    if [ "$a" -eq 203 ] && [ "$b" -eq 0 ] && [ "$c" -eq 113 ]; then return 1; fi
    if [ "$a" -ge 224 ]; then return 1; fi                                           # multicast and reserved
    return 0
}

_fk_ipv6_groups() {
    # Prints the eight 16-bit groups of an IPv6 address as decimal numbers,
    # separated by spaces; status 1 when the text is not an IPv6 address.
    local LC_ALL=C
    local addr=$1 head tail v4='' re part n=0 out='' hg tg fill i
    addr=${addr%%\%*}   # a zone id (fe80::1%en0)
    case $addr in *[!0-9a-fA-F:.]* | '') return 1 ;; esac
    case $addr in *:*) ;; *) return 1 ;; esac
    re='^(.*:)([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
    if [[ $addr =~ $re ]]; then
        if [ "${BASH_REMATCH[2]}" -gt 255 ] || [ "${BASH_REMATCH[3]}" -gt 255 ] || [ "${BASH_REMATCH[4]}" -gt 255 ] || [ "${BASH_REMATCH[5]}" -gt 255 ]; then return 1; fi
        v4=$(printf '%x:%x' $((10#${BASH_REMATCH[2]} * 256 + 10#${BASH_REMATCH[3]})) $((10#${BASH_REMATCH[4]} * 256 + 10#${BASH_REMATCH[5]})))
        addr=${BASH_REMATCH[1]}$v4
    fi
    case $addr in *:::* | *::*::*) return 1 ;; esac
    if [ "$addr" != "${addr/::/}" ]; then
        head=${addr%%::*}; tail=${addr#*::}
    else
        head=$addr; tail='-'
    fi
    hg=0; tg=0
    for part in ${head//:/ }; do hg=$((hg + 1)); done
    if [ "$tail" != '-' ]; then for part in ${tail//:/ }; do tg=$((tg + 1)); done; fi
    if [ "$tail" = '-' ]; then
        [ "$hg" -eq 8 ] || return 1
        fill=0
    else
        [ $((hg + tg)) -le 7 ] || return 1
        fill=$((8 - hg - tg))
    fi
    re='^[0-9a-fA-F]{1,4}$'
    for part in ${head//:/ }; do
        [[ $part =~ $re ]] || return 1
        out="$out $((16#$part))"; n=$((n + 1))
    done
    i=0
    while [ "$i" -lt "$fill" ]; do out="$out 0"; n=$((n + 1)); i=$((i + 1)); done
    if [ "$tail" != '-' ]; then
        for part in ${tail//:/ }; do
            [[ $part =~ $re ]] || return 1
            out="$out $((16#$part))"; n=$((n + 1))
        done
    fi
    [ "$n" -eq 8 ] || return 1
    printf '%s\n' "${out# }"
}

test_public_ip_address() {
    # Status 0 when the address is a public internet address (the product
    # refuses private, loopback, link-local, CGNAT, multicast and reserved
    # ranges). Anything that is not an address is "not public".
    local groups g
    case $1 in
        *:*)
            groups=$(_fk_ipv6_groups "$1") || return 1
            # shellcheck disable=SC2086
            set -- $groups
            # ::ffff:a.b.c.d (IPv4-mapped): judged as the IPv4 address
            if [ "$1" -eq 0 ] && [ "$2" -eq 0 ] && [ "$3" -eq 0 ] && [ "$4" -eq 0 ] && [ "$5" -eq 0 ] && [ "$6" -eq 65535 ]; then
                _fk_ipv4_public "$(($7 / 256)).$(($7 % 256)).$(($8 / 256)).$(($8 % 256))"
                return $?
            fi
            g=$1
            if [ "$1" -eq 0 ] && [ "$2" -eq 0 ] && [ "$3" -eq 0 ] && [ "$4" -eq 0 ] && [ "$5" -eq 0 ] && [ "$6" -eq 0 ] && [ "$7" -eq 0 ] && [ "$8" -le 1 ]; then return 1; fi   # :: and ::1
            if [ $((g & 0xfe00)) -eq $((0xfc00)) ]; then return 1; fi    # fc00::/7 unique local
            if [ $((g & 0xffc0)) -eq $((0xfe80)) ]; then return 1; fi    # fe80::/10 link-local
            if [ $((g & 0xff00)) -eq $((0xff00)) ]; then return 1; fi    # multicast
            if [ "$g" -eq $((0x2001)) ] && [ "$2" -eq $((0x0db8)) ]; then return 1; fi   # documentation
            return 0
            ;;
        *) _fk_ipv4_public "$1" ;;
    esac
}

get_tunnel_id_from_text() {
    # Prints the first UUID in the text, lower case; nothing when there is none.
    local LC_ALL=C
    local re='[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    if [[ $1 =~ $re ]]; then to_lower "${BASH_REMATCH[0]}"; echo; fi
    return 0
}

test_sha256_text() {
    local LC_ALL=C
    local re='^[0-9a-fA-F]{64}$'
    [[ $1 =~ $re ]]
}

get_cloudflared_config_text() {
    # get_cloudflared_config_text <tunnel id> <credentials file> <hub host> <provider host> <restart host> [hub port] [gate port] [restart port]
    # The tunnel configuration file. Every service is an address on this
    # computer; the last rule is the catch-all Cloudflare requires.
    # Status 1 (and a message on standard error) for a tunnel id that is not a
    # UUID or a host name that cannot be used.
    local LC_ALL=C
    local id=$1 cred=$2 hub=$3 provider=$4 restart=$5
    local hub_port=${6:-10000} gate_port=${7:-10002} restart_port=${8:-19999}
    local re='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' h reason q
    if ! [[ $id =~ $re ]]; then echo 'The tunnel id is not a UUID.' >&2; return 1; fi
    for h in "$hub" "$provider" "$restart"; do
        reason=$(test_farm_hostname "$h")
        if [ -n "$reason" ]; then echo "Host name \"$h\" cannot be used: $reason" >&2; return 1; fi
    done
    # Single-quoted YAML: a backslash is literal, a quote is doubled.
    q="'"
    cred=${cred//$q/$q$q}
    cred="'$cred'"
    cat <<YAML
# Written by the Blossom farm kit (install.sh). Re-running install.sh rewrites this file.
tunnel: $(to_lower "$id")
credentials-file: $cred

ingress:
  # GADS 6.0.0 does not check the login on hub paths that contain "appium".
  # Blossom never calls such a path, so they are refused here, before the hub.
  - hostname: $hub
    path: '(?i)appium'
    service: http_status:403
  # The provider reports to the hub on this path, locally. Never from outside.
  - hostname: $hub
    path: '^/provider-update'
    service: http_status:403
  # GADS 6.0.0 serves the provider record (an endless stream) on this path
  # without a login. Blossom never calls it; the hub page shows it locally.
  - hostname: $hub
    path: '^/admin/provider/[^/]+/info'
    service: http_status:403
  # GADS hub (has its own login)
  - hostname: $hub
    service: http://127.0.0.1:$hub_port
  # GADS provider, through the provider gate (the provider itself has no login)
  - hostname: $provider
    service: http://127.0.0.1:$gate_port
  # restart service (protected by the restart secret)
  - hostname: $restart
    service: http://127.0.0.1:$restart_port
  # everything else
  - service: http_status:404
YAML
}

_fk_sed_any_case() {
    # A literal text as a sed -E pattern that matches it in any letter case.
    local LC_ALL=C
    local text=$1 out='' c i=0 lower upper
    while [ "$i" -lt "${#text}" ]; do
        c=${text:$i:1}
        case $c in
            [a-zA-Z])
                lower=$(to_lower "$c"); upper=$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')
                out="${out}[$lower$upper]" ;;
            [0-9-]) out="$out$c" ;;
            *) out="${out}[$c]" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

hide_log_secret() {
    # hide_log_secret [name...]   (a filter: text on standard input)
    # Masks what must not leave the computer when a log line is shown or
    # posted: a session token in an address (?token=...), a bearer header,
    # anything shaped like a signed token (JWT), and the given names (the
    # farm's public host names). GADS writes every request address to its
    # log, and the hub accepts its session token in the address.
    local n
    local -a script
    script=(
        -e 's#([?&;]([Tt][Oo][Kk][Ee][Nn]|[Aa][Cc][Cc][Ee][Ss][Ss]_[Tt][Oo][Kk][Ee][Nn]|[Ii][Dd]_[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])=)[^&[:space:]"'"'"'<>]+#\1<hidden>#g'
        -e 's#(^|[^A-Za-z0-9_])([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[A-Za-z0-9._~+/=-]{8,}#\1\2<hidden>#g'
        -e 's#eyJ[A-Za-z0-9_-]{4,}[.][A-Za-z0-9_-]{4,}[.][A-Za-z0-9_-]*#<hidden-token>#g'
    )
    for n in "$@"; do
        [ "${#n}" -ge 4 ] || continue
        case $n in *[!A-Za-z0-9.-]*) continue ;; esac
        script=("${script[@]}" -e "s#$(_fk_sed_any_case "$n")#<host-name>#g")
    done
    LC_ALL=C sed -E "${script[@]}"
}

test_looks_down() {
    # test_looks_down <status> <text>
    # The product's rule: a 5xx status or an HTML page means "the tunnel
    # answers, but not the program behind it".
    local lower
    [ "$1" -ge 500 ] && return 0
    lower=$(to_lower "${2:0:4096}")
    case $lower in *'<!doctype'* | *'<html'*) return 0 ;; esac
    return 1
}

test_farm_root_trust() {
    # test_farm_root_trust <is folder 0|1> <is link 0|1> <is empty 0|1> <owner uid> <octal mode> <parent owner uid> <parent octal mode>
    # Decides what to do with a farm folder that ALREADY EXISTS before the kit
    # touches it. The services in this folder hold the farm's secrets and one
    # of them runs as root, so a folder somebody else prepared is not adopted.
    # Prints "use", "recreate" (empty: delete it and make a new one) or
    # "refuse: <reason>".
    local is_folder=$1 is_link=$2 is_empty=$3 owner=$4 mode=$5 parent_owner=${6:-0} parent_mode=${7:-755}
    if [ "$is_link" = 1 ]; then echo 'refuse: It is a link to another place, not a folder of its own.'; return 0; fi
    if [ "$is_folder" != 1 ]; then echo 'refuse: It is a file, not a folder.'; return 0; fi
    case $parent_mode in '' | *[!0-7]*) echo 'refuse: The folder that contains it cannot be examined.'; return 0 ;; esac
    if [ "$parent_owner" != 0 ] || [ $((0$parent_mode & 022)) -ne 0 ]; then
        echo 'refuse: The folder that contains it can be changed by accounts other than root, so it could be replaced at any time.'; return 0
    fi
    if [ "$is_empty" = 1 ]; then echo 'recreate'; return 0; fi
    case $mode in '' | *[!0-7]*) echo 'refuse: Its owner and permissions cannot be read.'; return 0 ;; esac
    if [ "$owner" != 0 ]; then
        echo 'refuse: It was not created by this kit: its owner is not root, so whoever made it can still change what is inside.'; return 0
    fi
    if [ $((0$mode & 022)) -ne 0 ]; then
        echo 'refuse: It was not locked by this kit: accounts other than root may write to it, so what is inside cannot be trusted.'; return 0
    fi
    echo 'use'
}

json_string() {
    # Prints the text as a JSON string, quotes included.
    local LC_ALL=C
    local t=$1
    t=${t//\\/\\\\}
    t=${t//\"/\\\"}
    t=${t//$'\n'/\\n}
    t=${t//$'\r'/\\r}
    t=${t//$'\t'/\\t}
    case $t in
        *[[:cntrl:]]*) t=$(printf '%s' "$t" | tr -d '\000-\010\013\014\016-\037\177') ;;
    esac
    printf '"%s"' "$t"
}

json_flatten() {
    # JSON on standard input -> "path<TAB>value" lines (see lib/json.awk).
    LC_ALL=C awk -f "$FARMKIT_JSON_AWK"
}

json_get() {
    # json_get <json text> <path>   prints the value at the path (nothing when absent)
    printf '%s' "$1" | json_flatten 2>/dev/null | LC_ALL=C awk -F '\t' -v p="$2" '$1 == p { sub(/^[^\t]*\t/, ""); print; exit }'
    return 0
}

json_values() {
    # json_values <json text> <path with * for "any one part">   prints every matching value, one per line
    printf '%s' "$1" | json_flatten 2>/dev/null | LC_ALL=C awk -F '\t' -v p="$2" '
        BEGIN { n = split(p, want, ".") }
        { m = split($1, have, "."); if (m != n) next
          for (i = 1; i <= n; i++) if (want[i] != "*" && want[i] != have[i]) next
          sub(/^[^\t]*\t/, ""); print }'
    return 0
}

json_find_index() {
    # json_find_index <json text> <path with one *> <value>
    # Prints what the * stands for in the first path whose value is <value>.
    printf '%s' "$1" | json_flatten 2>/dev/null | LC_ALL=C awk -F '\t' -v p="$2" -v v="$3" '
        BEGIN { n = split(p, want, ".") }
        { m = split($1, have, "."); if (m != n) next
          star = ""
          for (i = 1; i <= n; i++) { if (want[i] == "*") star = have[i]; else if (want[i] != have[i]) next }
          path = $1; sub(/^[^\t]*\t/, "")
          if ($0 == v) { print star; exit } }'
    return 0
}

json_file_get() {
    # json_file_get <file> <path>
    [ -r "$1" ] || return 0
    json_flatten < "$1" 2>/dev/null | LC_ALL=C awk -F '\t' -v p="$2" '$1 == p { sub(/^[^\t]*\t/, ""); print; exit }'
    return 0
}

curl_config_quote() {
    # A value for a curl configuration file (curl -K): inside double quotes,
    # with backslash, quote, tab and line breaks escaped.
    local t=$1
    t=${t//\\/\\\\}
    t=${t//\"/\\\"}
    t=${t//$'\n'/\\n}
    t=${t//$'\r'/\\r}
    t=${t//$'\t'/\\t}
    printf '"%s"' "$t"
}

xml_escape() {
    local t=$1
    t=${t//&/\&amp;}
    t=${t//</\&lt;}
    t=${t//>/\&gt;}
    printf '%s' "$t"
}

render_template() {
    # render_template <template file> NAME=value ...   (prints the result)
    # Replaces every @NAME@ in the template. Values are XML-escaped: the
    # templates are property lists. A value whose name ends in _XML is put in
    # as it is. Status 1 when a @NAME@ is left over.
    local template=$1 text pair name value
    shift
    text=$(cat "$template") || return 1
    for pair in "$@"; do
        name=${pair%%=*}; value=${pair#*=}
        case $name in *_XML) ;; *) value=$(xml_escape "$value") ;; esac
        text=${text//@$name@/"$value"}
    done
    if printf '%s\n' "$text" | grep -q '@[A-Z_][A-Z_]*@'; then
        printf '%s\n' "$text" | grep -o '@[A-Z_][A-Z_]*@' | head -n 1 >&2
        return 1
    fi
    printf '%s\n' "$text"
}

parse_lsof_listeners() {
    # The output of  lsof +c 0 -nP -iTCP -sTCP:LISTEN -F pcLn  on standard
    # input -> one line per listening socket:
    # pid<TAB>command<TAB>address<TAB>port<TAB>user   (address is * for "all
    # addresses"; user is empty when lsof gave none).
    LC_ALL=C awk '
        /^p/ { pid = substr($0, 2); user = ""; next }
        /^c/ { cmd = substr($0, 2); next }
        /^L/ { user = substr($0, 2); next }
        /^n/ { name = substr($0, 2)
               i = length(name)
               while (i > 0 && substr(name, i, 1) != ":") i--
               if (i == 0) next
               port = substr(name, i + 1); addr = substr(name, 1, i - 1)
               if (port !~ /^[0-9]+$/) next
               gsub(/[\[\]]/, "", addr)
               key = pid "\t" cmd "\t" addr "\t" port "\t" user
               if (!(key in seen)) { seen[key] = 1; print key } }'
}

test_loopback_address() {
    case $1 in 127.* | ::1 | localhost) return 0 ;; esac
    return 1
}

first_free_id() {
    # "name id" lines on standard input (dscl . -list /Users UniqueID and the
    # same for groups, together) -> the first id from <first> to <last> that
    # nobody has. Nothing when all are taken.
    LC_ALL=C awk -v first="${1:-300}" -v last="${2:-499}" '
        { used[$NF] = 1 }
        END { for (i = first; i <= last; i++) if (!(i in used)) { print i; exit } }'
}

version_at_least() {
    # version_at_least <have> <want>   (dotted numbers; status 0 when have >= want)
    local LC_ALL=C
    local have=$1 want=$2 h w i=0
    while [ "$i" -lt 4 ]; do
        h=${have%%.*}; w=${want%%.*}
        case $h in '' | *[!0-9]*) h=0 ;; esac
        case $w in '' | *[!0-9]*) w=0 ;; esac
        if [ $((10#$h)) -gt $((10#$w)) ]; then return 0; fi
        if [ $((10#$h)) -lt $((10#$w)) ]; then return 1; fi
        if [ "$have" = "${have#*.}" ]; then have=0; else have=${have#*.}; fi
        if [ "$want" = "${want#*.}" ]; then want=0; else want=${want#*.}; fi
        i=$((i + 1))
    done
    return 0
}

get_farm_service_names() {
    # In the order they are stopped (the reverse is the start order). MongoDB
    # and the firewall job are not in this list: they are never stopped by a
    # re-run.
    echo 'restart cloudflared keep-available gate provider hub'
}

get_farm_start_order() { echo 'hub provider gate keep-available restart cloudflared'; }

farm_label() { printf '%s.%s' "$FARM_LABEL_PREFIX" "$1"; }

farm_arch_key() {
    # The name versions.json uses for a processor: arm64 or x86_64.
    case $1 in arm64 | aarch64) echo arm64 ;; x86_64 | amd64) echo x86_64 ;; *) echo '' ;; esac
}

# ---------------------------------------------------------------------------
# System helpers
# ---------------------------------------------------------------------------

run_native() {
    # Runs a program; sets RUN_CODE and RUN_OUTPUT (standard output and error).
    RUN_OUTPUT=$("$@" 2>&1)
    RUN_CODE=$?
}

last_lines() {
    # last_lines <n>   (text on standard input) -> the last n lines on one line
    tail -n "$1" | tr '\n' ' '
}

assert_macos_root() {
    if [ "$(uname -s)" != 'Darwin' ]; then
        stop_farm 'This script is for macOS.' 'On a Windows PC use the .ps1 script of the same name (README, "Windows").'
    fi
    if [ "$(id -u)" != 0 ]; then
        stop_farm 'This script must run as root.' "Open Terminal, go to the kit folder and put sudo in front:   sudo bash ${0}   . It asks for the password of your Mac user, which must be an administrator."
    fi
}

_fk_stat_bsd() { stat -f '%u' / > /dev/null 2>&1; }

file_owner_uid() {
    if _fk_stat_bsd; then stat -f '%u' "$1" 2> /dev/null; else stat -c '%u' "$1" 2> /dev/null; fi
}

file_mode() {
    if _fk_stat_bsd; then stat -f '%Lp' "$1" 2> /dev/null; else stat -c '%a' "$1" 2> /dev/null; fi
}

file_size() {
    if _fk_stat_bsd; then stat -f '%z' "$1" 2> /dev/null; else stat -c '%s' "$1" 2> /dev/null; fi
}

get_file_sha256() {
    # Prints the SHA-256 of a file, lower case.
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        openssl dgst -sha256 -r "$1" | awk '{ print $1 }'
    fi
}

get_text_sha256() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/farmkit.XXXXXX") || return 1
    printf '%s' "$1" > "$tmp"
    get_file_sha256 "$tmp"
    rm -f "$tmp"
}

get_farm_paths() {
    # Sets the FARM_* path variables for a farm root (default /opt/farm).
    FARM_ROOT=${1:-/opt/farm}
    FARM_BIN=$FARM_ROOT/bin
    FARM_CONFIG=$FARM_ROOT/config
    FARM_LOGS=$FARM_ROOT/logs
    FARM_SERVICES=$FARM_ROOT/services
    FARM_DOWNLOADS=$FARM_ROOT/downloads
    FARM_DATA=$FARM_ROOT/data
    FARM_VAR=$FARM_ROOT/var
    FARM_JSON=$FARM_CONFIG/farm.json
    FARM_RESTART_SECRET=$FARM_CONFIG/restart-secret.txt
    FARM_KEEP_AVAILABLE=$FARM_CONFIG/keep-available.json
    FARM_MONGOD_CONF=$FARM_CONFIG/mongod.conf
    FARM_PF_RULES=$FARM_CONFIG/pf.rules
    FARM_CLOUDFLARED=$FARM_CONFIG/cloudflared
    FARM_CLOUDFLARED_YML=$FARM_CLOUDFLARED/config.yml
    FARM_TUNNEL_CREDENTIALS=$FARM_CLOUDFLARED/tunnel-credentials.json
    FARM_TUNNEL_CERT=$FARM_CLOUDFLARED/cert.pem
    FARM_HUB_EXE=$FARM_BIN/GADS
    FARM_PROVIDER_EXE=$FARM_BIN/GADS-drag
    FARM_NODE_DIR=$FARM_BIN/node
    FARM_NODE_EXE=$FARM_NODE_DIR/bin/node
    FARM_MONGO_DIR=$FARM_BIN/mongodb
    FARM_MONGOD_EXE=$FARM_MONGO_DIR/bin/mongod
    FARM_CLOUDFLARED_EXE=$FARM_BIN/cloudflared
    FARM_TOOLS_DIR=$FARM_BIN/tools
    FARM_FINGERPRINTS=$FARM_CONFIG/services
}

protect_farm_path() {
    # protect_farm_path <path> <private|service|service-write>
    #   private        root only                      (files 600, folders 700)
    #   service        root writes, the farm services read   (640 / 750)
    #   service-write  the farm services own it       (600 / 700, owner the service account)
    # The owner of everything the services run or read as configuration is
    # root: the service account cannot change its own programs or settings.
    local path=$1 kind=${2:-private} owner group fmode dmode
    [ -e "$path" ] || stop_farm "Path not found: $path" ''
    case $kind in
        private) owner=0; group=0; fmode=600; dmode=700 ;;
        service) owner=0; group=$FARM_SERVICE_GROUP; fmode=640; dmode=750 ;;
        service-write) owner=$FARM_SERVICE_USER; group=$FARM_SERVICE_GROUP; fmode=600; dmode=700 ;;
        *) stop_farm "protect_farm_path: unknown kind $kind" '' ;;
    esac
    if ! chown "$owner:$group" "$path" 2> /dev/null; then
        stop_farm "Could not set the owner of $path." 'Check that the disk is a Mac disk (APFS; permissions do not exist on FAT or exFAT) and that you run the script with sudo, then run it again.'
    fi
    if [ -d "$path" ]; then fmode=$dmode; fi
    chmod "$fmode" "$path" || stop_farm "Could not restrict access to $path." 'Run the script again with sudo.'
}

dir_is_empty() { [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print 2> /dev/null | head -n 1)" ]; }

get_farm_root_verdict() {
    # Prints the verdict of test_farm_root_trust for a farm folder that exists.
    local root=$1 parent is_folder=0 is_link=0 is_empty=0
    parent=$(dirname "$root")
    [ -L "$root" ] && is_link=1
    if [ -d "$root" ] && [ "$is_link" = 0 ]; then
        is_folder=1
        dir_is_empty "$root" && is_empty=1
    fi
    test_farm_root_trust "$is_folder" "$is_link" "$is_empty" "$(file_owner_uid "$root")" "$(file_mode "$root")" "$(file_owner_uid "$parent")" "$(file_mode "$parent")"
}

stop_farm_root_untrusted() {
    stop_farm "$1 already exists and cannot be used. $2" "Nothing was changed. If you know the folder (an earlier farm set up by hand), rename it:   sudo mv $1 $1-old   and run the script again. If you do not know where it comes from, do the same and have the Mac checked: the kit keeps secrets and programs that run with full rights in this folder. To move a kit-installed farm from another computer use scripts/export-farm and scripts/import-farm."
}

initialize_farm_root() {
    # Creates the farm folder, or takes over an existing one only when that is
    # safe. Called before anything in the folder is read or run. The group
    # and the final permissions are set by install.sh once the service
    # account exists; here the folder is root's alone.
    local root=$1 parent verdict created=0
    parent=$(dirname "$root")
    if [ ! -d "$parent" ]; then
        if ! { mkdir -p "$parent" && chown 0:0 "$parent" && chmod 755 "$parent"; }; then
            stop_farm "Could not create $parent." 'Run the script again with sudo.'
        fi
    fi
    if [ -e "$root" ] || [ -L "$root" ]; then
        verdict=$(get_farm_root_verdict "$root")
        case $verdict in
            refuse:*) stop_farm_root_untrusted "$root" "${verdict#refuse: }" ;;
            recreate) rmdir "$root" || stop_farm "Could not replace the empty folder $root." 'Remove it yourself (sudo rmdir) and run the script again.' ;;
        esac
    else
        verdict=$(test_farm_root_trust 1 0 1 0 700 "$(file_owner_uid "$parent")" "$(file_mode "$parent")")
        case $verdict in refuse:*) stop_farm_root_untrusted "$root" "${verdict#refuse: }" ;; esac
    fi
    if [ ! -d "$root" ]; then
        (umask 077 && mkdir "$root") || stop_farm "Could not create $root." 'Run the script again with sudo.'
        created=1
    fi
    if ! { chown 0:0 "$root" && chmod go-w "$root"; }; then
        stop_farm "Could not restrict access to $root." 'Run the script again with sudo.'
    fi
    if [ "$created" = 1 ] && ! dir_is_empty "$root"; then
        stop_farm_root_untrusted "$root" 'Something was put into it while it was being created.'
    fi
}

write_secret_file() {
    # write_secret_file <path> <text> [private|service]
    # Creates the file empty, restricts it, then writes the secret into it.
    local path=$1 kind=${3:-private}
    if [ ! -e "$path" ]; then (umask 077 && : > "$path") || stop_farm "Could not create $path." 'Run the script again with sudo.'; fi
    protect_farm_path "$path" "$kind"
    printf '%s' "$2" > "$path" || stop_farm "Could not write $path." 'Check the free space on the disk and run the script again.'
}

read_secret_line() {
    # read_secret_line <prompt>   sets REPLY_SECRET. Typing is hidden.
    REPLY_SECRET=''
    if ! IFS= read -r -s -p "$1: " REPLY_SECRET < /dev/tty; then
        echo
        stop_farm 'Nothing could be read from the keyboard.' 'Run the script in a Terminal window, not through a pipe or a remote tool without a terminal.'
    fi
    echo > /dev/tty
}

read_farm_password() {
    # read_farm_password <prompt> [forbidden word...]   sets REPLY_SECRET.
    # Asks twice, hidden, and repeats until the password passes the rules.
    local prompt=$1 first problems
    shift
    while true; do
        read_secret_line "$prompt"; first=$REPLY_SECRET
        problems=$(test_password_strength "$first" "$@")
        if [ -n "$problems" ]; then
            write_warn 'That password is not strong enough:'
            printf '%s\n' "$problems" | while IFS= read -r line; do write_note "  - $line"; done
            continue
        fi
        read_secret_line 'Type it again'
        if [ "$first" != "$REPLY_SECRET" ]; then write_warn 'The two entries differ. Try again.'; continue; fi
        REPLY_SECRET=$first
        return 0
    done
}

get_verified_download() {
    # get_verified_download <url> <sha256> <out file> <what>
    # Downloads to a temporary name, checks the SHA-256, and only then moves
    # the file into place. A file that is already there with the right hash is
    # kept. Nothing with a wrong hash is ever left at <out file>.
    local url=$1 want=$2 out=$3 what=$4 tmp got code
    if ! test_sha256_text "$want"; then
        stop_farm "No valid pinned SHA-256 for $what in versions.json." 'Download the kit again from its releases page; versions.json must not be edited by hand.'
    fi
    case $url in https://*) ;; *) stop_farm "The download address for $what is not https." 'Download the kit again from its releases page.' ;; esac
    want=$(to_lower "$want")
    if [ -f "$out" ] && [ "$(get_file_sha256 "$out")" = "$want" ]; then return 0; fi
    tmp=$out.download
    rm -f "$tmp"
    code=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 -sS -L --max-redirs 5 --connect-timeout 30 --max-time 1800 -o "$tmp" -w '%{http_code}' "$url" 2> "$tmp.err")
    if [ "$code" != 200 ]; then
        got=$(tr '\n' ' ' < "$tmp.err" 2> /dev/null)
        rm -f "$tmp" "$tmp.err"
        if [ "$code" = 404 ]; then
            stop_farm "$what is not at its download address (HTTP 404): $url" "The file was not published yet, or it was withdrawn. Check the kit's releases page for a newer kit and use that. If there is none, report it on the kit repository. This is not a fault of your Mac or your connection."
        fi
        stop_farm "Downloading $what failed (HTTP $code) $got" "Check the internet connection of this Mac and run the script again. Address: $url"
    fi
    rm -f "$tmp.err"
    got=$(get_file_sha256 "$tmp")
    if [ "$got" != "$want" ]; then
        rm -f "$tmp"
        stop_farm "$what was downloaded but its SHA-256 is wrong (expected $want, got $got). The file was deleted." 'Do not continue with this file. Run the script again; if the hash is wrong again, the download is being altered on the way or the published file changed: report it on the kit repository.'
    fi
    mv -f "$tmp" "$out" || stop_farm "Could not move the download to $out." 'Check the free space on the disk and run the script again.'
}

_fk_http_dir() {
    if [ -z "${FK_HTTP_DIR:-}" ] || [ ! -d "$FK_HTTP_DIR" ]; then
        FK_HTTP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/farmkit-http.XXXXXX") || stop_farm 'Could not create a temporary folder.' 'Check the free space on the disk.'
    fi
}

farm_http_cleanup() {
    if [ -n "${FK_HTTP_DIR:-}" ] && [ -d "$FK_HTTP_DIR" ]; then rm -rf "$FK_HTTP_DIR"; fi
    FK_HTTP_DIR=''
}

invoke_farm_http() {
    # invoke_farm_http <url> [--method M] [--body TEXT] [--bearer TOKEN] [--timeout S] [--like-blossom]
    # One HTTP call that never fails for an HTTP status and never follows a
    # redirect. Sets HTTP_STATUS (0 = no HTTP answer), HTTP_TEXT (at most 1 MB),
    # HTTP_ERROR and HTTP_CHALLENGE (1 when Cloudflare answered instead).
    #
    # Nothing secret is put on a command line: the address, the headers and
    # the body go to curl through its standard input.
    #
    # --like-blossom sends what Blossom's servers send: no User-Agent and no
    # Accept header. Cloudflare treats a request without a User-Agent
    # differently (Browser Integrity Check), so the self-test must look the same.
    local url=$1 method=GET body='' bearer='' timeout=15 like=0 config code
    shift
    while [ $# -gt 0 ]; do
        case $1 in
            --method) method=$2; shift 2 ;;
            --body) body=$2; shift 2 ;;
            --bearer) bearer=$2; shift 2 ;;
            --timeout) timeout=$2; shift 2 ;;
            --like-blossom) like=1; shift ;;
            *) shift ;;
        esac
    done
    HTTP_STATUS=0; HTTP_TEXT=''; HTTP_ERROR=''; HTTP_CHALLENGE=0
    _fk_http_dir
    : > "$FK_HTTP_DIR/body"; : > "$FK_HTTP_DIR/headers"; : > "$FK_HTTP_DIR/error"
    config="url = $(curl_config_quote "$url")
request = $(curl_config_quote "$method")
max-time = $timeout
connect-timeout = $timeout
silent
show-error
globoff
proto = \"=http,https\"
output = $(curl_config_quote "$FK_HTTP_DIR/body")
dump-header = $(curl_config_quote "$FK_HTTP_DIR/headers")
write-out = \"%{http_code}\"
"
    if [ "$like" = 1 ]; then
        config="${config}header = \"User-Agent:\"
header = \"Accept:\"
header = \"Accept-Encoding: identity\"
"
    else
        config="${config}user-agent = \"blossom-farm-kit\"
header = \"Accept: application/json\"
"
    fi
    case $url in http://127.0.0.1:* | http://localhost:*) config="${config}noproxy = \"*\"
" ;; esac
    if [ -n "$bearer" ]; then config="${config}header = $(curl_config_quote "Authorization: Bearer $bearer")
"; fi
    if [ -n "$body" ]; then
        config="${config}header = \"Content-Type: application/json\"
data-binary = $(curl_config_quote "$body")
"
    elif [ "$method" != GET ] && [ "$method" != HEAD ]; then
        config="${config}header = \"Content-Length: 0\"
"
    fi
    code=$(printf '%s' "$config" | curl -q -K - 2> "$FK_HTTP_DIR/error")
    case $code in '' | *[!0-9]*) code=0 ;; esac
    HTTP_STATUS=$((10#$code))
    if [ "$HTTP_STATUS" -eq 0 ]; then
        HTTP_ERROR=$(sed -e 's/^curl: ([0-9]*) //' "$FK_HTTP_DIR/error" | tr '\n' ' ')
        [ -n "$HTTP_ERROR" ] || HTTP_ERROR='no answer'
        return 0
    fi
    HTTP_TEXT=$(head -c 1048576 "$FK_HTTP_DIR/body" | LC_ALL=C tr -d '\000')
    # Cloudflare marks an answer that is its own challenge or block page.
    if LC_ALL=C grep -qi '^cf-mitigated:' "$FK_HTTP_DIR/headers"; then HTTP_CHALLENGE=1; fi
    if [ "$HTTP_STATUS" -eq 403 ]; then
        code=$(to_lower "${HTTP_TEXT:0:65536}")
        case $code in
            *'<html'* | *'<!doctype'*) case $code in *cloudflare*) HTTP_CHALLENGE=1 ;; esac ;;
        esac
    fi
    : > "$FK_HTTP_DIR/body"; : > "$FK_HTTP_DIR/headers"
    return 0
}

read_farm_config() {
    # Sets FARM_HAS_CONFIG (0|1) and, when there is an installation record,
    # FARM_CFG_* from it. Nothing is read from a farm folder that somebody
    # else prepared.
    local verdict text
    FARM_HAS_CONFIG=0
    FARM_CFG_KIT=''; FARM_CFG_INSTALLED_AT=''; FARM_CFG_NICKNAME=''; FARM_CFG_HUB_HOST=''; FARM_CFG_PROVIDER_HOST=''
    FARM_CFG_RESTART_HOST=''; FARM_CFG_HUB_USER=''; FARM_CFG_TUNNEL_NAME=''; FARM_CFG_TUNNEL_ID=''; FARM_CFG_ROUTES_CREATED=''
    FARM_CFG_WITH_APPIUM=''
    if [ -e "$FARM_ROOT" ] || [ -L "$FARM_ROOT" ]; then
        verdict=$(get_farm_root_verdict "$FARM_ROOT")
        case $verdict in refuse:*) stop_farm_root_untrusted "$FARM_ROOT" "${verdict#refuse: }" ;; esac
    fi
    [ -f "$FARM_JSON" ] || return 0
    text=$(cat "$FARM_JSON")
    if ! printf '%s' "$text" | json_flatten > /dev/null 2>&1; then
        stop_farm "$FARM_JSON cannot be read as JSON." 'Run install.sh again; it rewrites the file.'
    fi
    FARM_HAS_CONFIG=1
    FARM_CFG_KIT=$(json_get "$text" kit)
    FARM_CFG_INSTALLED_AT=$(json_get "$text" installedAt)
    FARM_CFG_NICKNAME=$(json_get "$text" nickname)
    FARM_CFG_HUB_HOST=$(json_get "$text" hubHost)
    FARM_CFG_PROVIDER_HOST=$(json_get "$text" providerHost)
    FARM_CFG_RESTART_HOST=$(json_get "$text" restartHost)
    FARM_CFG_HUB_USER=$(json_get "$text" hubUser)
    FARM_CFG_TUNNEL_NAME=$(json_get "$text" tunnelName)
    FARM_CFG_TUNNEL_ID=$(json_get "$text" tunnelId)
    FARM_CFG_ROUTES_CREATED=$(json_get "$text" routesCreated)
    FARM_CFG_WITH_APPIUM=$(json_get "$text" withAppium)
}

read_kit_versions() {
    # read_kit_versions <kit root>   sets KIT_VERSIONS (the text of versions.json)
    local file=$1/versions.json
    if [ ! -f "$file" ]; then
        stop_farm 'versions.json is missing from the kit folder.' 'Download the complete kit again (the whole folder, not single files) and run the script from inside it.'
    fi
    KIT_VERSIONS=$(cat "$file")
    if ! printf '%s' "$KIT_VERSIONS" | json_flatten > /dev/null 2>&1; then
        stop_farm 'versions.json of the kit cannot be read as JSON.' 'Download the complete kit again; versions.json must not be edited by hand.'
    fi
}

kit_version() { json_get "$KIT_VERSIONS" "$1"; }

get_farm_arch() {
    # Sets FARM_ARCH (arm64 or x86_64). Stops under Rosetta and on anything else.
    local machine
    machine=$(uname -m)
    FARM_ARCH=$(farm_arch_key "$machine")
    if [ -z "$FARM_ARCH" ]; then
        stop_farm "This Mac reports the processor type \"$machine\", which the kit does not know." 'The kit installs programs for Apple Silicon (arm64) and for Intel (x86_64) Macs.'
    fi
    if [ "$(sysctl -n sysctl.proc_translated 2> /dev/null)" = 1 ]; then
        stop_farm 'This Terminal runs under Rosetta (Intel emulation) on an Apple Silicon Mac.' 'Close it. In Finder, select Terminal (Applications > Utilities), press Command-I, untick "Open using Rosetta", open Terminal again and run the script again.'
    fi
}

# --- the service account and the folders -----------------------------------

ensure_service_account() {
    # A hidden account without a password, a shell or a home folder. Every
    # farm program except the restart service runs as this account, so a flaw
    # in one of them is not a flaw with root rights.
    local ids id=''
    if ! dscl . -read "/Groups/$FARM_SERVICE_GROUP" PrimaryGroupID > /dev/null 2>&1; then
        ids=$({ dscl . -list /Users UniqueID; dscl . -list /Groups PrimaryGroupID; } 2> /dev/null)
        id=$(printf '%s\n' "$ids" | first_free_id 300 499)
        [ -n "$id" ] || stop_farm 'No free account number between 300 and 499 was found on this Mac.' 'Report this on the kit repository with the output of:   dscl . -list /Users UniqueID'
        if ! { dscl . -create "/Groups/$FARM_SERVICE_GROUP" &&
            dscl . -create "/Groups/$FARM_SERVICE_GROUP" PrimaryGroupID "$id" &&
            dscl . -create "/Groups/$FARM_SERVICE_GROUP" RealName 'Blossom farm services' &&
            dscl . -create "/Groups/$FARM_SERVICE_GROUP" Password '*'; }; then
            stop_farm "Could not create the group $FARM_SERVICE_GROUP." 'Run the script again with sudo.'
        fi
    fi
    FARM_SERVICE_GID=$(dscl . -read "/Groups/$FARM_SERVICE_GROUP" PrimaryGroupID 2> /dev/null | awk '{ print $NF }')
    if ! dscl . -read "/Users/$FARM_SERVICE_USER" UniqueID > /dev/null 2>&1; then
        ids=$({ dscl . -list /Users UniqueID; } 2> /dev/null)
        id=$(printf '%s\n' "$ids" | first_free_id "$FARM_SERVICE_GID" "$FARM_SERVICE_GID")
        if [ -z "$id" ]; then
            ids=$({ dscl . -list /Users UniqueID; dscl . -list /Groups PrimaryGroupID; } 2> /dev/null)
            id=$(printf '%s\n' "$ids" | first_free_id 300 499)
        fi
        [ -n "$id" ] || stop_farm 'No free account number between 300 and 499 was found on this Mac.' 'Report this on the kit repository with the output of:   dscl . -list /Users UniqueID'
        if ! { dscl . -create "/Users/$FARM_SERVICE_USER" &&
            dscl . -create "/Users/$FARM_SERVICE_USER" UniqueID "$id" &&
            dscl . -create "/Users/$FARM_SERVICE_USER" PrimaryGroupID "$FARM_SERVICE_GID" &&
            dscl . -create "/Users/$FARM_SERVICE_USER" UserShell /usr/bin/false &&
            dscl . -create "/Users/$FARM_SERVICE_USER" NFSHomeDirectory /var/empty &&
            dscl . -create "/Users/$FARM_SERVICE_USER" RealName 'Blossom farm services' &&
            dscl . -create "/Users/$FARM_SERVICE_USER" Password '*' &&
            dscl . -create "/Users/$FARM_SERVICE_USER" IsHidden 1; }; then
            stop_farm "Could not create the account $FARM_SERVICE_USER." 'Run the script again with sudo.'
        fi
    fi
}

remove_service_account() {
    dscl . -delete "/Users/$FARM_SERVICE_USER" > /dev/null 2>&1
    dscl . -delete "/Groups/$FARM_SERVICE_GROUP" > /dev/null 2>&1
    return 0
}

_fk_make_dir() {
    # _fk_make_dir <path> <kind for protect_farm_path>
    if [ ! -d "$1" ]; then
        (umask 077 && mkdir -p "$1") || stop_farm "Could not create $1." 'Run the script again with sudo.'
    fi
    protect_farm_path "$1" "$2"
}

ensure_farm_layout() {
    # ensure_farm_layout [nickname]
    # The folders of a farm and who may do what in them. Everything the
    # services run or read as configuration belongs to root; the service
    # account may read it and writes only to logs, data, var and its own
    # provider folder.
    local d
    protect_farm_path "$FARM_ROOT" service
    for d in "$FARM_BIN" "$FARM_TOOLS_DIR" "$FARM_SERVICES" "$FARM_CONFIG" "$FARM_CLOUDFLARED"; do _fk_make_dir "$d" service; done
    for d in "$FARM_DOWNLOADS" "$FARM_FINGERPRINTS"; do _fk_make_dir "$d" private; done
    for d in "$FARM_DATA" "$FARM_DATA/mongodb" "$FARM_VAR" "$FARM_VAR/home" "$FARM_VAR/tmp" "$FARM_VAR/hub-files"; do _fk_make_dir "$d" service-write; done
    if [ -n "${1:-}" ]; then _fk_make_dir "$FARM_ROOT/$1" service-write; fi
    # Logs: the services append to them (the restart service as root).
    if [ ! -d "$FARM_LOGS" ]; then mkdir "$FARM_LOGS" || stop_farm "Could not create $FARM_LOGS." 'Run the script again with sudo.'; fi
    if ! { chown "0:$FARM_SERVICE_GROUP" "$FARM_LOGS" && chmod 770 "$FARM_LOGS"; }; then
        stop_farm "Could not restrict access to $FARM_LOGS." 'Run the script again with sudo.'
    fi
}

# --- launchd ----------------------------------------------------------------

farm_plist_path() { printf '%s/%s.plist' "$FARM_LAUNCHD_DIR" "$(farm_label "$1")"; }

farm_service_loaded() { launchctl print "system/$(farm_label "$1")" > /dev/null 2>&1; }

farm_service_running() {
    launchctl print "system/$(farm_label "$1")" 2> /dev/null | LC_ALL=C grep -q '^[[:space:]]*state = running'
}

stop_farm_service() {
    # Unloads a service and waits until launchd no longer knows it.
    local name=$1 i=0
    farm_service_loaded "$name" || return 0
    launchctl bootout "system/$(farm_label "$name")" > /dev/null 2>&1
    while farm_service_loaded "$name" && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
    ! farm_service_loaded "$name"
}

start_farm_service() {
    # start_farm_service <name> [wait seconds=30]   status 0 when it runs
    local name=$1 wait_sec=${2:-30} plist i=0
    plist=$(farm_plist_path "$name")
    if [ ! -f "$plist" ]; then
        stop_farm "The service $(farm_label "$name") does not exist ($plist is missing)." 'Run install.sh again.'
    fi
    if ! farm_service_loaded "$name"; then launchctl bootstrap system "$plist" > /dev/null 2>&1; fi
    farm_service_running "$name" || launchctl kickstart "system/$(farm_label "$name")" > /dev/null 2>&1
    while [ "$i" -lt $((wait_sec * 2)) ]; do
        farm_service_running "$name" && return 0
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

wait_tcp_port() {
    # wait_tcp_port <port> [wait seconds=30]   status 0 when 127.0.0.1:<port> accepts a connection
    local port=$1 wait_sec=${2:-30} i=0
    while [ "$i" -lt $((wait_sec * 2)) ]; do
        if nc -z -w 2 127.0.0.1 "$port" > /dev/null 2>&1; then return 0; fi
        sleep 0.5; i=$((i + 1))
    done
    return 1
}

set_farm_service() {
    # set_farm_service <name> <rendered plist file> [watched file...]
    # Creates or updates one launchd service. Idempotent. A service that is
    # running and already configured exactly as asked is left alone, running:
    # status 1. Any other is unloaded, its property list replaced, and left
    # unloaded for start_farm_service: status 0.
    # The watched files are what the program reads when it starts (its
    # script, its configuration): when one of them changed, the service is
    # restarted even though its settings are the same.
    local name=$1 rendered=$2 plist fingerprint_file fingerprint f
    shift 2
    plist=$(farm_plist_path "$name")
    fingerprint_file=$FARM_FINGERPRINTS/$name.sha256
    fingerprint=$(get_file_sha256 "$rendered")
    for f in "$@"; do
        [ -f "$f" ] && fingerprint="$fingerprint $(get_file_sha256 "$f")"
    done
    fingerprint=$(get_text_sha256 "$fingerprint")
    if farm_service_running "$name" && [ -f "$plist" ] && cmp -s "$rendered" "$plist" &&
        [ -f "$fingerprint_file" ] && [ "$(cat "$fingerprint_file")" = "$fingerprint" ]; then
        rm -f "$rendered"
        return 1
    fi
    if ! stop_farm_service "$name"; then
        stop_farm "The service $(farm_label "$name") did not stop." 'Restart the Mac and run the script again.'
    fi
    rm -f "$fingerprint_file"
    if ! { cp "$rendered" "$plist" && chown 0:0 "$plist" && chmod 644 "$plist"; }; then
        stop_farm "Could not write $plist." 'Run the script again with sudo.'
    fi
    rm -f "$rendered"
    printf '%s' "$fingerprint" > "$fingerprint_file"
    chmod 600 "$fingerprint_file"
    return 0
}

remove_farm_service() {
    # Unloads a service and deletes its property list. Status 1 when there was none.
    local name=$1 plist
    plist=$(farm_plist_path "$name")
    if [ ! -f "$plist" ] && ! farm_service_loaded "$name"; then return 1; fi
    stop_farm_service "$name"
    rm -f "$plist" "$FARM_FINGERPRINTS/$name.sha256"
    return 0
}

# --- installing programs ----------------------------------------------------

lock_program_tree() {
    # A program folder below /opt/farm/bin: root owns it, the service account
    # may read and run it, nobody else may do anything.
    if ! { chown -R "0:$FARM_SERVICE_GROUP" "$1" && chmod -R u=rwX,g=rX,o= "$1"; }; then
        stop_farm "Could not set the permissions of $1." 'Run install.sh again with sudo.'
    fi
}

install_archive_program() {
    # install_archive_program <folder> <program inside it> <url> <sha256> <what>
    # Unpacks a publisher's .tar.gz into a folder below /opt/farm/bin. A
    # program that is already there is kept as it is.
    local dir=$1 program=$2 url=$3 sha=$4 what=$5 archive
    if [ -x "$dir/$program" ]; then write_ok "$what is already installed ($dir/$program)"; return 0; fi
    write_note "Installing $what..."
    archive=$FARM_DOWNLOADS/$(basename "$dir").tar.gz
    get_verified_download "$url" "$sha" "$archive" "$what"
    rm -rf "$dir.new"
    mkdir "$dir.new" || stop_farm "Could not create $dir.new." 'Check the free space on the disk and run install.sh again.'
    if ! tar -xzf "$archive" -C "$dir.new" --strip-components=1 --no-same-owner 2> /dev/null || [ ! -x "$dir.new/$program" ]; then
        rm -rf "$dir.new"
        stop_farm "The archive of $what could not be unpacked." 'Check the free space on the disk, delete /opt/farm/downloads and run install.sh again.'
    fi
    lock_program_tree "$dir.new"
    rm -rf "$dir"
    mv "$dir.new" "$dir" || stop_farm "Could not move $what into place." 'Run install.sh again.'
    rm -f "$archive"
    write_ok "$what installed ($dir/$program), SHA-256 verified."
}

install_one_file() {
    # install_one_file <source> <destination>   (root owns it; the service account may run it)
    if ! { cp -f "$1" "$2" && chown "0:$FARM_SERVICE_GROUP" "$2" && chmod 750 "$2"; }; then
        stop_farm "Could not write $2." 'A farm program may still hold the file. Restart the Mac and run install.sh again.'
    fi
}

install_mongodb_tools() {
    # mongodump and mongorestore, from the publisher's archive at the pinned
    # version. Needed only to move a farm (export, import).
    local dir=$FARM_BIN/mongodb-tools archive unpack tool
    if [ -x "$dir/bin/mongodump" ] && [ -x "$dir/bin/mongorestore" ]; then
        write_ok "MongoDB Database Tools are already installed ($dir/bin)"
        return 0
    fi
    write_note "Installing MongoDB Database Tools $(kit_version macos.mongodbTools) (mongodump, mongorestore)..."
    archive=$FARM_DOWNLOADS/mongodb-tools.zip
    get_verified_download "$(kit_version "macos.$FARM_ARCH.mongodbTools.url")" "$(kit_version "macos.$FARM_ARCH.mongodbTools.sha256")" "$archive" "MongoDB Database Tools $(kit_version macos.mongodbTools)"
    unpack=$FARM_DOWNLOADS/mongodb-tools-unpack
    rm -rf "$unpack" "$dir.new"
    mkdir -p "$unpack" "$dir.new/bin" || stop_farm "Could not create $dir.new." 'Check the free space on the disk and run the script again.'
    if ! unzip -q -o -j "$archive" '*/bin/mongodump' '*/bin/mongorestore' -d "$unpack" 2> /dev/null; then
        rm -rf "$unpack" "$dir.new"
        stop_farm 'The archive of the MongoDB Database Tools could not be unpacked.' 'Check the free space on the disk, delete /opt/farm/downloads and run the script again.'
    fi
    for tool in mongodump mongorestore; do
        if ! { [ -f "$unpack/$tool" ] && cp -f "$unpack/$tool" "$dir.new/bin/$tool" && chmod 755 "$dir.new/bin/$tool"; }; then
            rm -rf "$unpack" "$dir.new"
            stop_farm "The archive of the MongoDB Database Tools does not contain $tool." 'Report this on the kit repository.'
        fi
    done
    lock_program_tree "$dir.new"
    rm -rf "$dir" "$unpack" "$archive"
    mv "$dir.new" "$dir" || stop_farm 'Could not move the MongoDB Database Tools into place.' 'Run the script again.'
    write_ok "MongoDB Database Tools installed ($dir/bin), SHA-256 verified."
}

render_service() {
    # render_service <name> [watched file...]   fills in the template of a
    # service and hands it to set_farm_service. Status 0: (re)configured and
    # left unloaded; 1: left alone, running.
    local name=$1 rendered
    shift
    rendered=$FARM_FINGERPRINTS/$name.plist.new
    if ! render_template "$KIT_ROOT/launchd/$(farm_label "$name").plist" "FARM_ROOT=$FARM_ROOT" "SERVICE_USER=$FARM_SERVICE_USER" \
        "SERVICE_GROUP=$FARM_SERVICE_GROUP" "NICKNAME=${NICKNAME:-}" "PROVIDER_PATH=${PROVIDER_PATH:-}" "APPIUM_ENV_XML=${APPIUM_ENV_XML:-}" > "$rendered"; then
        stop_farm "The service description launchd/$(farm_label "$name").plist of the kit is damaged." 'Download the complete kit again and run install.sh from inside it.'
    fi
    set_farm_service "$name" "$rendered" "$FARM_SERVICES/farm-run.sh" "$@"
}

ensure_mongodb_service() {
    # The kit's own MongoDB: its configuration, its launchd service, started
    # and answering on this Mac.
    local port=27017 conf
    if ! farm_service_loaded mongodb && nc -z -w 2 127.0.0.1 "$port" > /dev/null 2>&1; then
        stop_farm "Another program already uses port $port on this Mac (another MongoDB?)." 'The kit runs its own MongoDB with its data under /opt/farm. Stop the other one (with Homebrew:   brew services stop mongodb-community   ) and run the script again.'
    fi
    conf="# Written by the Blossom farm kit (install.sh). Re-running install.sh rewrites this file.
storage:
  dbPath: $FARM_DATA/mongodb
net:
  bindIp: 127.0.0.1
  port: $port"
    if [ ! -f "$FARM_MONGOD_CONF" ] || [ "$(cat "$FARM_MONGOD_CONF")" != "$conf" ]; then
        printf '%s\n' "$conf" > "$FARM_MONGOD_CONF" || stop_farm "Could not write $FARM_MONGOD_CONF." 'Run the script again with sudo.'
    fi
    protect_farm_path "$FARM_MONGOD_CONF" service
    render_service mongodb "$FARM_MONGOD_CONF" "$FARM_MONGOD_EXE"
    if ! start_farm_service mongodb 60 || ! wait_tcp_port "$port" 60; then
        stop_farm "MongoDB does not start or does not listen on 127.0.0.1:$port." 'Read the end of /opt/farm/logs/mongodb.log. A frequent cause is a full disk.'
    fi
}

copy_service_files() {
    # The service scripts of this kit folder, into /opt/farm/services.
    local file
    for file in restart-server.js provider-gate.js keep-available.sh farm-run.sh farm-firewall.sh; do
        if ! { cp -f "$KIT_ROOT/services/$file" "$FARM_SERVICES/$file" && chown "0:$FARM_SERVICE_GROUP" "$FARM_SERVICES/$file" && chmod 640 "$FARM_SERVICES/$file"; }; then
            stop_farm "Could not write $FARM_SERVICES/$file." 'Run the script again with sudo.'
        fi
    done
    if ! { cp -f "$KIT_ROOT/lib/json.awk" "$FARM_SERVICES/json.awk" && chown "0:$FARM_SERVICE_GROUP" "$FARM_SERVICES/json.awk" && chmod 640 "$FARM_SERVICES/json.awk"; }; then
        stop_farm "Could not write $FARM_SERVICES/json.awk." 'Run the script again with sudo.'
    fi
}

# --- the packet filter (pf) --------------------------------------------------

get_farm_firewall_state() {
    # Sets FW_AVAILABLE (pf could be asked), FW_ENABLED (pf is switched on),
    # FW_FIRST and FW_LAST (the port range the kit's rule refuses; empty when
    # the rule is not loaded).
    local info rules re
    FW_AVAILABLE=0; FW_ENABLED=0; FW_FIRST=''; FW_LAST=''
    info=$(pfctl -s info 2> /dev/null) || return 0
    FW_AVAILABLE=1
    case $info in *'Status: Enabled'*) FW_ENABLED=1 ;; esac
    rules=$(pfctl -a "$FARM_PF_ANCHOR" -s rules 2> /dev/null)
    re='block drop in quick on ! lo0 proto tcp from any to any port ([0-9]+):([0-9]+)'
    if [[ $rules =~ $re ]]; then FW_FIRST=${BASH_REMATCH[1]}; FW_LAST=${BASH_REMATCH[2]}; fi
}

firewall_covers_port() {
    # Status 0 when the kit's rule is loaded, pf is on and the port is in its range.
    [ "$FW_ENABLED" = 1 ] && [ -n "$FW_FIRST" ] && [ "$1" -ge "$FW_FIRST" ] && [ "$1" -le "$FW_LAST" ]
}

remove_farm_firewall_block() {
    # Empties the kit's pf anchor. pf itself is left as it is.
    pfctl -a "$FARM_PF_ANCHOR" -F all > /dev/null 2>&1
}

get_farm_listeners() {
    # Sets FARM_LISTENERS: pid<TAB>command<TAB>address<TAB>port<TAB>user per listening TCP socket.
    FARM_LISTENERS=$(lsof +c 0 -nP -iTCP -sTCP:LISTEN -F pcLn 2> /dev/null | parse_lsof_listeners)
}

# --- the hub ----------------------------------------------------------------

connect_hub() {
    # connect_hub <hub url> <user name> <password>   sets HUB_TOKEN (empty when
    # the hub refuses the login). Stops when the hub does not answer at all.
    local body
    HUB_TOKEN=''
    body="{\"username\":$(json_string "$2"),\"password\":$(json_string "$3")}"
    invoke_farm_http "$1/authenticate" --method POST --body "$body" --timeout 15
    if [ "$HTTP_STATUS" -eq 0 ]; then
        stop_farm "The GADS hub does not answer at $1 ($HTTP_ERROR)." 'Check the services with scripts/status.sh. Read the end of /opt/farm/logs/hub.log. Then run the script again.'
    fi
    [ "$HTTP_STATUS" -eq 200 ] || return 0
    HUB_TOKEN=$(json_get "$HTTP_TEXT" result.access_token)
    [ -n "$HUB_TOKEN" ] || HUB_TOKEN=$(json_get "$HTTP_TEXT" access_token)
    return 0
}

url_encode() {
    # Percent-encodes everything except unreserved characters.
    local LC_ALL=C
    local text=$1 out='' c i=0
    while [ "$i" -lt "${#text}" ]; do
        c=${text:$i:1}
        case $c in
            [a-zA-Z0-9._~-]) out=$out$c ;;
            *) out=$out$(printf '%%%02X' "'$c") ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

farm_resolve() {
    # Prints the addresses a host name resolves to, one per line, as this Mac's
    # own resolver gives them (hosts file and local overrides included).
    if command -v dscacheutil > /dev/null 2>&1; then
        dscacheutil -q host -a name "$1" 2> /dev/null | awk '/^ip(v6)?_address:/ { print $2 }' | sort -u
    elif command -v getent > /dev/null 2>&1; then
        getent ahosts "$1" 2> /dev/null | awk '{ print $1 }' | sort -u
    fi
}

_fk_step() {
    # Adds a self-test step: id, state (ok, warn, fail), detail, fix.
    SELFTEST_STEPS="${SELFTEST_STEPS}$1	$2	$3	$4
"
    [ "$2" = fail ] && SELFTEST_FAILED=1
    return 0
}

invoke_farm_self_test() {
    # invoke_farm_self_test <hub host> <provider host> <restart host> <nickname> <hub user> <hub password> <restart secret>
    # The same walk the product's "Test connection" takes, from this computer,
    # against the public host names. Sets SELFTEST_STEPS (one line per step:
    # id, state, detail and fix, separated by tabs) and SELFTEST_FAILED. The
    # requests carry the headers Blossom's servers send (in particular: no
    # User-Agent), so that Cloudflare treats both alike.
    local hub_host=$1 provider_host=$2 restart_host=$3 nickname=$4 hub_user=$5 hub_password=$6 restart_secret=$7
    local hub="https://$1" provider="https://$2" restart="https://$3"
    local bad name addresses private a token body probe leaks registered sync udids live count path off k challenge_fix
    SELFTEST_STEPS=''; SELFTEST_FAILED=0

    # 1 addresses
    bad=$(test_farm_hostname_set "$hub_host" "$provider_host" "$restart_host" | tr '\n' ' ')
    if [ -n "$bad" ]; then _fk_step address fail "$bad" 'Run install.sh again and enter valid host names.'; return 0; fi
    _fk_step address ok 'The three addresses are well formed https addresses.' ''

    # 2 DNS: public addresses only
    for name in "$hub_host" "$provider_host" "$restart_host"; do
        addresses=$(farm_resolve "$name")
        if [ -z "$addresses" ]; then
            _fk_step dns fail "$name does not resolve yet." 'A new DNS record can take a few minutes. Wait, then run scripts/self-test.sh. If it stays like this, look at the DNS records of your domain in the Cloudflare dashboard: there must be a CNAME for this name pointing at <tunnel id>.cfargotunnel.com.'
            return 0
        fi
        private=''
        for a in $addresses; do test_public_ip_address "$a" || private="$private $a"; done
        if [ -n "$private" ]; then
            _fk_step dns fail "$name resolves to a private address ($(trim_text "$private")). Blossom refuses such names." 'Remove any hosts-file entry or local DNS override for this name; it must resolve to Cloudflare.'
            return 0
        fi
    done
    _fk_step dns ok 'All three names resolve to public addresses.' ''

    # 3 reach + TLS
    invoke_farm_http "$hub/health" --like-blossom --timeout 15
    if [ "$HTTP_STATUS" -eq 0 ]; then
        _fk_step reach fail "The hub address could not be reached: $HTTP_ERROR" 'Check that the tunnel service is running (scripts/status.sh) and read /opt/farm/logs/cloudflared.log.'
        return 0
    fi
    challenge_fix="Cloudflare is answering instead of the farm. Blossom's servers send plain API requests without a browser's User-Agent and cannot pass a challenge. In the Cloudflare dashboard of your domain: Security -> Settings, switch \"Browser Integrity Check\" off (it is on by default), or add a rule that skips it for the three farm host names; and remove any Access application, \"Under Attack\" mode, managed challenge or bot rule for them (docs/network.md, section 5)."
    if [ "$HTTP_CHALLENGE" = 1 ]; then
        _fk_step reach fail "Cloudflare blocked or challenged the request (HTTP $HTTP_STATUS) before it reached the hub." "$challenge_fix"
        return 0
    fi
    if test_looks_down "$HTTP_STATUS" "$HTTP_TEXT"; then
        _fk_step reach fail "The address answers (HTTP $HTTP_STATUS), but not the hub behind it." 'Check that the hub service is running (scripts/status.sh).'
        return 0
    fi
    if [ "$HTTP_STATUS" -ge 300 ] && [ "$HTTP_STATUS" -lt 400 ]; then
        _fk_step reach fail "The hub address answers with a redirect (HTTP $HTTP_STATUS). Blossom does not follow redirects." 'Remove redirect rules and any Cloudflare Access application in front of this host name (docs/security.md).'
        return 0
    fi
    _fk_step reach ok "Connected to $hub_host with a valid certificate." ''

    # 4 sign-in
    body="{\"username\":$(json_string "$hub_user"),\"password\":$(json_string "$hub_password")}"
    invoke_farm_http "$hub/authenticate" --like-blossom --method POST --body "$body" --timeout 15
    token=$(json_get "$HTTP_TEXT" result.access_token)
    [ -n "$token" ] || token=$(json_get "$HTTP_TEXT" access_token)
    if [ "$HTTP_CHALLENGE" = 1 ]; then
        _fk_step signin fail "Cloudflare blocked or challenged the sign-in request (HTTP $HTTP_STATUS) before it reached the hub." "$challenge_fix"
        return 0
    fi
    if [ "$HTTP_STATUS" -eq 401 ] || [ "$HTTP_STATUS" -eq 403 ]; then
        _fk_step signin fail 'The hub refused the user name or password.' 'Reset the login with scripts/rotate-secrets.sh --hub-user and enter the new password in Blossom.'
        return 0
    fi
    if [ -z "$token" ]; then
        _fk_step signin fail "The address answers (HTTP $HTTP_STATUS), but its sign-in did not return a token." 'Check that the hub host name points at the hub (port 10000) in /opt/farm/config/cloudflared/config.yml.'
        return 0
    fi
    _fk_step signin ok 'The hub accepted the user name and password.' ''

    # 5 hub endpoints
    invoke_farm_http "$hub/admin/devices" --like-blossom --bearer "$token" --timeout 15
    registered=''
    if [ "$HTTP_STATUS" -eq 200 ] && printf '%s' "$HTTP_TEXT" | json_flatten > /dev/null 2>&1; then
        registered=$(json_values "$HTTP_TEXT" 'result.devices.*.udid')
        _fk_step hub ok 'The hub serves its device register (/admin/devices).' ''
    elif [ "$HTTP_STATUS" -eq 401 ] || [ "$HTTP_STATUS" -eq 403 ]; then
        _fk_step hub fail 'The user signs in but may not read the device register.' 'The hub user Blossom uses needs the admin role (hub page, Admin, Users).'
        return 0
    else
        _fk_step hub fail "The hub did not serve /admin/devices (HTTP $HTTP_STATUS)." 'Read /opt/farm/logs/hub.log.'
        return 0
    fi

    # extra check, not part of the product's test: GADS 6.0.0 skips its login
    # for hub paths containing "appium"; the tunnel must refuse them (403).
    # (cloudflared matches the rule against the decoded path, the same form
    # the hub checks, so a percent-encoded spelling is refused as well.)
    leaks=''
    for probe in /device/kit-selftest/appium/status /device/kit-selftest/APPIUM/status /device/kit-selftest/appiumSource; do
        invoke_farm_http "$hub$probe" --like-blossom --timeout 15
        [ "$HTTP_STATUS" -eq 403 ] || leaks="$leaks$probe -> HTTP $HTTP_STATUS; "
    done
    if [ -n "$leaks" ]; then
        _fk_step hub-appium fail "Hub paths containing \"appium\" are not refused by the tunnel: ${leaks%; }." 'GADS does not check the login on these paths. If Appium is switched on for the provider, stop the tunnel (sudo launchctl bootout system/blossom-farm.cloudflared) and report this on the kit repository; see docs/security.md, section 3.'
    else
        _fk_step hub-appium ok 'Hub paths containing "appium" are refused at the tunnel (403), as they must be.' ''
    fi

    # extra check, not part of the product's test: GADS 6.0.0 serves the
    # provider record as an endless stream on this path without a login.
    invoke_farm_http "$hub/admin/provider/$(url_encode "$nickname")/info" --like-blossom --timeout 8
    if [ "$HTTP_STATUS" -eq 403 ]; then
        _fk_step hub-provider-info ok 'The provider record of the hub is refused at the tunnel (403), as it must be.' ''
    else
        _fk_step hub-provider-info fail "The hub path /admin/provider/<nickname>/info is not refused by the tunnel (HTTP $HTTP_STATUS). GADS serves it without a login." 'Run install.sh again: it rewrites the tunnel configuration and restarts the tunnel. If it stays like this, report it on the kit repository (privately: Security -> Report a vulnerability); see docs/security.md, section 3.'
    fi

    # 6 phones
    invoke_farm_http "$hub/provider/$(url_encode "$nickname")/devices" --like-blossom --bearer "$token" --timeout 15
    sync=''; live=0
    if [ "$HTTP_STATUS" -eq 200 ]; then
        sync=$(json_values "$HTTP_TEXT" 'result.*.udid')
        live=$(printf '%s' "$HTTP_TEXT" | json_flatten 2> /dev/null | LC_ALL=C awk -F '\t' '
            { n = split($1, p, "."); if (n != 3 || p[1] != "result") next
              if (p[3] == "connected" && $2 == "true") c[p[2]] = 1
              if (p[3] == "provider_state" && $2 == "live") l[p[2]] = 1 }
            END { n = 0; for (i in c) if (i in l) n++; print n }')
    fi
    udids=$(printf '%s\n%s\n' "$registered" "$sync" | awk 'NF' | sort -u)
    count=$(printf '%s\n' "$udids" | awk 'NF' | wc -l | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        _fk_step devices warn 'The connection works, but no phone is registered on the hub yet.' 'Normal for a new farm. Continue with docs/phones.md.'
    elif [ "${live:-0}" -eq 0 ]; then
        _fk_step devices warn "$count phone(s) registered, none live right now." 'Check the provider, the cables, and WebDriverAgent (docs/phones.md).'
    else
        _fk_step devices ok "$count phone(s) registered, $live live right now." ''
    fi

    # 7 provider (through the gate)
    path=/
    if [ "$count" -gt 0 ]; then path="/device/$(url_encode "$(printf '%s\n' "$udids" | head -n 1)")/info"; fi
    invoke_farm_http "$provider$path" --like-blossom --bearer "$token" --timeout 15
    if [ "$HTTP_STATUS" -eq 0 ]; then
        _fk_step provider fail "The provider address could not be reached: $HTTP_ERROR" 'Check the tunnel service and the provider host name in the tunnel configuration.'
    elif [ "$HTTP_STATUS" -eq 401 ]; then
        _fk_step provider fail 'The provider gate refused a token the hub had just issued.' 'Check that the gate and hub services run (scripts/status.sh) and read /opt/farm/logs/provider-gate.log.'
    elif test_looks_down "$HTTP_STATUS" "$HTTP_TEXT"; then
        _fk_step provider fail "The provider address answers (HTTP $HTTP_STATUS), but not the provider behind it." 'Check that the provider and gate services run (scripts/status.sh) and read /opt/farm/logs/provider.log.'
    else
        _fk_step provider ok "The provider answers at $provider_host. (Live video is opened by a browser and is not part of this test.)" ''
    fi
    # extra check, not part of the product's test: the provider must NOT answer without a token
    invoke_farm_http "$provider/devices" --like-blossom --timeout 15
    if [ "$HTTP_STATUS" -eq 200 ]; then
        _fk_step provider-locked fail 'The provider address answers WITHOUT a login. Anyone who learns this host name could control the phones.' 'The provider host name must point at the provider gate (port 10002), never at the provider itself (port 10001). Run install.sh again to rewrite the tunnel configuration.'
    elif [ "$HTTP_STATUS" -eq 401 ]; then
        _fk_step provider-locked ok 'Without a hub token the provider address answers 401, as it must.' ''
    else
        _fk_step provider-locked warn "Without a token the provider address answered HTTP $HTTP_STATUS (expected 401)." 'Run scripts/status.sh and check the gate service.'
    fi

    # 8 restart service
    invoke_farm_http "$restart/status" --like-blossom --bearer "$restart_secret" --timeout 15
    if [ "$HTTP_STATUS" -eq 0 ]; then
        _fk_step restart fail "The restart service could not be reached: $HTTP_ERROR" 'Check the tunnel and restart services (scripts/status.sh).'
    elif [ "$HTTP_STATUS" -eq 401 ] || [ "$HTTP_STATUS" -eq 403 ]; then
        _fk_step restart fail 'The restart service refused the secret.' 'Run scripts/rotate-secrets.sh --restart-secret and enter the new secret in Blossom.'
    elif test_looks_down "$HTTP_STATUS" "$HTTP_TEXT" || [ "$HTTP_STATUS" -ne 200 ] || ! printf '%s' "$HTTP_TEXT" | json_flatten > /dev/null 2>&1; then
        _fk_step restart fail "The restart service did not answer its status (HTTP $HTTP_STATUS)." 'Check the restart service and read /opt/farm/logs/restart-server.log.'
    else
        off=''
        for k in hub provider cloudflare keep_available mongodb; do
            [ "$(json_get "$HTTP_TEXT" "$k")" = true ] || off="$off$k, "
        done
        if [ -n "$off" ]; then _fk_step restart warn "Answers. Reported as not running: ${off%, }." 'Run scripts/status.sh.'
        else _fk_step restart ok 'Answers, and reports every program as running.' ''; fi
    fi
    invoke_farm_http "$restart/status" --like-blossom --timeout 15
    if [ "$HTTP_STATUS" -ne 401 ]; then
        _fk_step restart-locked fail "Without the secret the restart service answered HTTP $HTTP_STATUS (expected 401)." 'Do not use this farm until this is understood: read /opt/farm/logs/restart-server.log and docs/security.md.'
    else
        _fk_step restart-locked ok 'Without the secret the restart service answers 401, as it must.' ''
    fi
    return 0
}

_fk_step_title() {
    case $1 in
        address) echo 'Addresses' ;;
        dns) echo 'DNS' ;;
        reach) echo 'Secure connection (TLS)' ;;
        signin) echo 'Hub sign-in' ;;
        hub) echo 'Hub answers like GADS' ;;
        hub-appium) echo 'Hub refuses unauthenticated Appium paths' ;;
        hub-provider-info) echo 'Hub refuses the open provider record' ;;
        devices) echo 'Phones' ;;
        provider) echo 'Provider' ;;
        provider-locked) echo 'Provider refuses strangers' ;;
        restart) echo 'Restart service' ;;
        restart-locked) echo 'Restart service refuses strangers' ;;
        *) echo "$1" ;;
    esac
}

write_self_test_report() {
    # Prints SELFTEST_STEPS; status 0 when nothing failed.
    local id state detail fix color mark all_ok=0 reached=' '
    while IFS='	' read -r id state detail fix; do
        [ -n "$id" ] || continue
        reached="$reached$id "
        color=$FK_GREEN; mark='OK    '
        [ "$state" = warn ] && { color=$FK_YELLOW; mark='CHECK '; }
        [ "$state" = fail ] && { color=$FK_RED; mark='FAILED'; all_ok=1; }
        printf '%s   %s  %s: %s%s\n' "$color" "$mark" "$(_fk_step_title "$id")" "$detail" "$FK_OFF"
        [ -n "$fix" ] && printf '           What to do: %s\n' "$fix"
    done <<EOF
$SELFTEST_STEPS
EOF
    for id in address dns reach signin hub devices provider restart; do
        case $reached in *" $id "*) ;; *) printf '%s   NOT RUN %s: an earlier step failed.%s\n' "$FK_GRAY" "$(_fk_step_title "$id")" "$FK_OFF" ;; esac
    done
    return "$all_ok"
}
