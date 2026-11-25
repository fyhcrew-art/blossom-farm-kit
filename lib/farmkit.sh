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
# Written by an earlier kit (log rotation by macOS); removed when found.
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
        return 0
    fi
    # The nickname becomes a folder below the farm folder, and the disk of a
    # Mac does not tell upper case from lower case: "Services" IS "services".
    case $(to_lower "$1") in
        bin | config | logs | logs-root | services | downloads | data | var | npm | appium | export | previous | export-stage | import-stage)
            echo 'It is the name of a folder the kit itself uses. Choose another, for example Provider1.' ;;
    esac
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

# --- pairing with Blossom CRM: the checks that need no network ---------------

normalize_pairing_code() {
    # Prints a pairing code as it is sent: upper case, without the hyphens and
    # spaces it is shown with, and with the letters people mistype put right
    # (O is 0, I and L are 1: the alphabet of a code has none of them).
    local LC_ALL=C
    printf '%s' "$1" | tr -d ' \t\r\n-' | tr '[:lower:]' '[:upper:]' | tr 'OIL' '011'
}

test_pairing_code() {
    # Prints nothing when the text is shaped like a pairing code, otherwise
    # the reason. A code is 20 characters of 0-9 and A-Z without I, L, O, U
    # (100 random bits), shown in five groups of four.
    local LC_ALL=C
    local code re='^[0-9A-HJKMNP-TV-Z]{20}$'
    code=$(normalize_pairing_code "$1")
    if [ -z "$code" ]; then echo 'The pairing code is empty.'; return 0; fi
    if ! [[ $code =~ $re ]]; then
        echo 'A pairing code has 20 letters and digits in five groups of four, like K7QM-2XVD-9HTR-4BWN-6CPA. Copy the whole command from Blossom again.'
    fi
    return 0
}

normalize_app_origin() {
    # The address of Blossom as it is stored and compared: lower case, no
    # slash at the end.
    local o
    o=$(to_lower "$(trim_text "$1")")
    while [ "$o" != "${o%/}" ]; do o=${o%/}; done
    printf '%s' "$o"
}

test_app_origin() {
    # Prints nothing when the text is an https origin (https://host or
    # https://host:port, nothing else), otherwise the reason. The farm's
    # credentials are sent to this address and to no other.
    local LC_ALL=C
    local o rest host port re
    o=$(normalize_app_origin "$1")
    if [ -z "$o" ]; then echo 'The address of Blossom is missing.'; return 0; fi
    case $o in
        http://*) echo 'The address of Blossom must start with https://. The passwords of the farm are never sent over a connection that is not encrypted.'; return 0 ;;
        https://*) ;;
        *) echo 'The address of Blossom must look like https://<the address you open Blossom at>.'; return 0 ;;
    esac
    rest=${o#https://}
    case $rest in
        '' | *[/?#@\\[:space:]]* | *'['* | *']'*) echo 'Give the address of Blossom only: https:// and the host name, with nothing after it.'; return 0 ;;
    esac
    host=${rest%%:*}
    if [ "$rest" != "$host" ]; then
        port=${rest#*:}
        case $port in '' | *[!0-9]*) echo 'The port in the address of Blossom is not a number.'; return 0 ;; esac
        if [ "${#port}" -gt 5 ] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then echo 'The port in the address of Blossom is not a number.'; return 0; fi
    fi
    re='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'
    if [ "${#host}" -gt 253 ] || ! [[ $host =~ $re ]]; then echo 'The host name in the address of Blossom is not valid.'; return 0; fi
    case $host in *..*) echo 'The host name in the address of Blossom is not valid.' ;; esac
    return 0
}

test_farm_token() {
    # Status 0 when the text is shaped like a farm token: "bft_" and 32 random
    # bytes in URL-safe base64.
    local LC_ALL=C
    local re='^bft_[A-Za-z0-9_-]{43}$'
    [[ $1 =~ $re ]]
}

new_farm_token() { printf 'bft_%s' "$(new_random_secret 32 base64url)"; }

test_farm_domain() {
    # Prints nothing when the three default host names can be made under this
    # domain, otherwise the reason.
    local d reason
    d=$(normalize_farm_domain "$1")
    if [ -z "$d" ]; then echo 'The domain is empty.'; return 0; fi
    case $d in *.*) ;; *) echo 'Enter the domain itself, for example yourdomain.com.'; return 0 ;; esac
    reason=$(test_farm_hostname "farm-hub.$d")
    [ -n "$reason" ] && echo "$reason"
    return 0
}

normalize_farm_domain() {
    # "https://YourDomain.com/" -> "yourdomain.com"
    local d
    d=$(to_lower "$(trim_text "$1")")
    d=${d#https://}; d=${d#http://}
    while [ "$d" != "${d%/}" ]; do d=${d%/}; done
    while [ "$d" != "${d#.}" ]; do d=${d#.}; done
    printf '%s' "$d"
}

get_default_farm_hostnames() {
    # get_default_farm_hostnames <domain>   prints the three proposed names:
    # hub, provider, restart service, one per line.
    local d
    d=$(normalize_farm_domain "$1")
    printf 'farm-hub.%s\nfarm-provider.%s\nfarm-restart.%s\n' "$d" "$d" "$d"
}

clean_computer_label() {
    # The name of this computer as Blossom shows it: plain ASCII, at most 64
    # characters, never empty.
    local LC_ALL=C
    local t
    t=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._-')
    t=$(trim_text "${t:0:64}")
    [ -n "$t" ] || t='farm computer'
    printf '%s' "$t"
}

clean_remote_text() {
    # A text that came from the network, made safe to print: one line of plain
    # ASCII, at most 300 characters.
    local LC_ALL=C
    local t
    t=$(printf '%s' "$1" | tr '\r\n\t' '   ' | tr -cd '\040-\176')
    printf '%s' "${t:0:300}"
}

get_pairing_message() {
    # get_pairing_message <error code of Blossom> <its text>
    # What an answer of Blossom's pairing API means, for the person reading.
    case $1 in
        pairing_code_unknown) echo 'Blossom does not know this pairing code. A code works once and only as it is shown.' ;;
        pairing_code_expired) echo 'This pairing code has expired. A code is valid for 30 minutes.' ;;
        pairing_code_used) echo 'This pairing code was already used by another computer. If that was not you, do not confirm anything in Blossom: decline that computer there.' ;;
        rate_limited) echo 'Blossom is receiving too many pairing attempts at the moment.' ;;
        farm_token_invalid | farm_token_revoked) echo 'Blossom no longer accepts this computer: it was unpaired there, or its site was removed.' ;;
        pairing_rejected) echo 'This computer was declined in Blossom.' ;;
        pairing_expired) echo 'The pairing was not confirmed in Blossom in time.' ;;
        credentials_required) echo 'Blossom has no hub password or restart secret for these addresses and needs them sent again.' ;;
        *) if [ -n "$2" ]; then clean_remote_text "$2"; echo; else echo 'Blossom refused the request.'; fi ;;
    esac
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

file_mode_bits() {
    # Like file_mode, with the sticky, set-user and set-group bits (1777).
    if _fk_stat_bsd; then stat -f '%Mp%Lp' "$1" 2> /dev/null | sed 's/^0*\([0-7]\)/\1/'; else stat -c '%a' "$1" 2> /dev/null; fi
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
    FARM_ROOT_LOGS=$FARM_ROOT/logs-root
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
    FARM_PAIRING=$FARM_CONFIG/pairing.json
    FARM_PAIRING_NEW=$FARM_CONFIG/pairing.new.json
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

# --- the kit folder itself ----------------------------------------------------
# install.sh and the scripts run as root, today and at every later maintenance
# run. Whoever can change a file of the kit, or put another folder in its
# place, therefore becomes root the next time. The command from Blossom
# unpacks the kit to /opt/blossom-farm-kit, owned by root; a kit that was
# unpacked by hand (into a home folder, say) is moved to the same place.

FARM_KIT_HOME='/opt/blossom-farm-kit'

test_kit_folder_trust() {
    # "<what> <owner uid> <octal mode> <path>" lines on standard input, where
    # <what> is: kit (the kit folder), above (a folder that contains it, up
    # to /), inside (a file or folder in it), link (a link in it).
    # Prints nothing when only root can change the kit or replace it,
    # otherwise the first reason why not.
    LC_ALL=C awk '
        function open_to_others(mode,   n, g, o) {
            n = length(mode); g = substr(mode, n - 1, 1); o = substr(mode, n, 1)
            return (g ~ /[2367]/ || o ~ /[2367]/)
        }
        function sticky(mode) { return (length(mode) == 4 && substr(mode, 1, 1) ~ /[1357]/) }
        {
            what = $1; uid = $2; mode = $3; path = $0
            sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", path)
            if (what == "link") { print path " is a link to another place."; exit }
            if (uid !~ /^[0-9]+$/ || mode !~ /^[0-7]+$/) { print path " cannot be examined."; exit }
            if (uid != 0) { print path " belongs to an account other than root."; exit }
            # a folder above the kit may be open to others when it is "sticky"
            # (like /tmp): there, only root can rename or delete what root owns
            if (open_to_others(mode) && !(what == "above" && sticky(mode))) { print path " can be changed by accounts other than root."; exit }
        }'
}

list_kit_folder() {
    # list_kit_folder <folder>   prints the lines test_kit_folder_trust reads.
    local dir=$1 f
    printf 'kit %s %s %s\n' "$(file_owner_uid "$dir")" "$(file_mode_bits "$dir")" "$dir"
    f=$dir
    while [ "$f" != / ]; do
        f=$(dirname "$f")
        printf 'above %s %s %s\n' "$(file_owner_uid "$f")" "$(file_mode_bits "$f")" "$f"
    done
    find "$dir" -mindepth 1 \( -type l -o ! -user 0 -o -perm -020 -o -perm -002 \) -print 2> /dev/null | head -n 20 | while IFS= read -r f; do
        if [ -L "$f" ]; then printf 'link 0 0 %s\n' "$f"
        else printf 'inside %s %s %s\n' "$(file_owner_uid "$f")" "$(file_mode_bits "$f")" "$f"; fi
    done
}

use_protected_kit_folder() {
    # use_protected_kit_folder <this script, relative to the kit folder> [its arguments...]
    # Called by install.sh and by every script, as root, before they do
    # anything else. Returns when the kit folder is one only root can change.
    # A kit in /opt/blossom-farm-kit with wrong owners is put right. A kit
    # anywhere else is copied to /opt/blossom-farm-kit, and the script starts
    # again from there: this call then does not return.
    local entry=$1 here problem
    shift
    here=$(cd -P "$KIT_ROOT" 2> /dev/null && pwd -P) || stop_farm "The kit folder $KIT_ROOT cannot be opened." 'Run the script from inside the unpacked kit folder.'
    problem=$(list_kit_folder "$here" | test_kit_folder_trust)
    [ -z "$problem" ] && return 0
    if [ "$here" = "$FARM_KIT_HOME" ]; then
        chown -R 0:0 "$here" 2> /dev/null && chmod -R go-w "$here" 2> /dev/null
        problem=$(list_kit_folder "$here" | test_kit_folder_trust)
        if [ -n "$problem" ]; then
            stop_farm "The kit folder $here cannot be protected: $problem" "The scripts of the kit run with full rights, so nobody but root may be able to change them. Download the kit again and unpack it to a new folder, then run the script from there: it moves itself to $FARM_KIT_HOME."
        fi
        write_note "The kit folder $here was locked: only root can change it now."
        return 0
    fi
    write_note "This kit folder is not protected ($problem)"
    write_note "The scripts of the kit run with full rights, now and at every later maintenance run, so the kit is copied to $FARM_KIT_HOME, which only root can change."
    if [ ! -d "$(dirname "$FARM_KIT_HOME")" ]; then
        if ! { mkdir -p "$(dirname "$FARM_KIT_HOME")" && chown 0:0 "$(dirname "$FARM_KIT_HOME")" && chmod 755 "$(dirname "$FARM_KIT_HOME")"; }; then
            stop_farm "Could not create $(dirname "$FARM_KIT_HOME")." 'Run the script again with sudo.'
        fi
    fi
    rm -rf "$FARM_KIT_HOME.new"
    if ! { cp -R "$here" "$FARM_KIT_HOME.new" && chown -R 0:0 "$FARM_KIT_HOME.new" && chmod -R u=rwX,go=rX "$FARM_KIT_HOME.new"; }; then
        rm -rf "$FARM_KIT_HOME.new"
        stop_farm "Could not copy the kit to $FARM_KIT_HOME." 'Check the free space on the disk and run the script again with sudo.'
    fi
    if command -v xattr > /dev/null 2>&1; then xattr -dr com.apple.quarantine "$FARM_KIT_HOME.new" > /dev/null 2>&1; fi
    problem=$(list_kit_folder "$FARM_KIT_HOME.new" | test_kit_folder_trust)
    if [ -n "$problem" ]; then
        rm -rf "$FARM_KIT_HOME.new"
        stop_farm "The kit could not be put into a protected folder: $problem" 'Download the kit again from its repository, unpack it, and run the script from the new folder. A kit folder contains no links.'
    fi
    if [ -e "$FARM_KIT_HOME" ] || [ -L "$FARM_KIT_HOME" ]; then
        rm -rf "$FARM_KIT_HOME.previous"
        mv "$FARM_KIT_HOME" "$FARM_KIT_HOME.previous" || stop_farm "Could not put the kit that was in $FARM_KIT_HOME aside." 'Run the script again with sudo.'
    fi
    mv "$FARM_KIT_HOME.new" "$FARM_KIT_HOME" || stop_farm "Could not move the kit to $FARM_KIT_HOME." 'Run the script again with sudo.'
    write_ok "The kit is in $FARM_KIT_HOME now, and this script continues from there. Run the scripts of the kit from that folder from now on (cd $FARM_KIT_HOME); the folder you started from is no longer needed."
    # shellcheck disable=SC2093  # the line after it is only reached when exec failed
    exec /bin/bash "$FARM_KIT_HOME/$entry" "$@"
    stop_farm "Could not start $FARM_KIT_HOME/$entry." "Run it yourself:   cd $FARM_KIT_HOME && sudo bash $entry"
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
        stop_farm "No valid pinned SHA-256 for $what in versions.json." 'Download the kit again from its repository; versions.json must not be edited by hand.'
    fi
    case $url in https://*) ;; *) stop_farm "The download address for $what is not https." 'Download the kit again from its repository.' ;; esac
    want=$(to_lower "$want")
    if [ -f "$out" ] && [ "$(get_file_sha256 "$out")" = "$want" ]; then return 0; fi
    tmp=$out.download
    rm -f "$tmp"
    code=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 -sS -L --max-redirs 5 --connect-timeout 30 --max-time 1800 -o "$tmp" -w '%{http_code}' "$url" 2> "$tmp.err")
    if [ "$code" != 200 ]; then
        got=$(tr '\n' ' ' < "$tmp.err" 2> /dev/null)
        rm -f "$tmp" "$tmp.err"
        if [ "$code" = 404 ]; then
            stop_farm "$what is not at its download address (HTTP 404): $url" "The file was not published yet, or it was withdrawn. Look for a newer kit (the update script with --check) and use that. If there is none, report it on the kit repository. This is not a fault of your Mac or your connection."
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
    # invoke_farm_http <url> [--method M] [--body TEXT] [--bearer TOKEN] [--timeout S] [--like-blossom] [--https-only] [--agent TEXT]
    # One HTTP call that never fails for an HTTP status and never follows a
    # redirect. Sets HTTP_STATUS (0 = no HTTP answer), HTTP_TEXT (at most 1 MB),
    # HTTP_ERROR, HTTP_CHALLENGE (1 when Cloudflare answered instead),
    # HTTP_CURL_CODE (the exit status of curl) and HTTP_RETRY_AFTER (the
    # seconds of a Retry-After header, or nothing).
    #
    # --https-only refuses any address that is not https with TLS 1.2 or later
    # (used for Blossom itself: the farm's credentials travel on that call).
    #
    # Nothing secret is put on a command line: the address, the headers and
    # the body go to curl through its standard input.
    #
    # --like-blossom sends what Blossom's servers send: no User-Agent and no
    # Accept header. Cloudflare treats a request without a User-Agent
    # differently (Browser Integrity Check), so the self-test must look the same.
    local url=$1 method=GET body='' bearer='' timeout=15 like=0 config code https_only=0 agent='blossom-farm-kit'
    shift
    while [ $# -gt 0 ]; do
        case $1 in
            --method) method=$2; shift 2 ;;
            --body) body=$2; shift 2 ;;
            --bearer) bearer=$2; shift 2 ;;
            --timeout) timeout=$2; shift 2 ;;
            --like-blossom) like=1; shift ;;
            --https-only) https_only=1; shift ;;
            --agent) agent=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    HTTP_STATUS=0; HTTP_TEXT=''; HTTP_ERROR=''; HTTP_CHALLENGE=0; HTTP_CURL_CODE=0; HTTP_RETRY_AFTER=''
    _fk_http_dir
    : > "$FK_HTTP_DIR/body"; : > "$FK_HTTP_DIR/headers"; : > "$FK_HTTP_DIR/error"
    config="url = $(curl_config_quote "$url")
request = $(curl_config_quote "$method")
max-time = $timeout
connect-timeout = $timeout
silent
show-error
globoff
output = $(curl_config_quote "$FK_HTTP_DIR/body")
dump-header = $(curl_config_quote "$FK_HTTP_DIR/headers")
write-out = \"%{http_code}\"
"
    if [ "$https_only" = 1 ]; then
        config="${config}proto = \"=https\"
tlsv1.2
max-redirs = 0
"
    else
        config="${config}proto = \"=http,https\"
"
    fi
    if [ "$like" = 1 ]; then
        config="${config}header = \"User-Agent:\"
header = \"Accept:\"
header = \"Accept-Encoding: identity\"
"
    else
        config="${config}user-agent = $(curl_config_quote "$agent")
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
    HTTP_CURL_CODE=$?
    case $code in '' | *[!0-9]*) code=0 ;; esac
    HTTP_STATUS=$((10#$code))
    if [ "$HTTP_STATUS" -eq 0 ]; then
        HTTP_ERROR=$(sed -e 's/^curl: ([0-9]*) //' "$FK_HTTP_DIR/error" | tr '\n' ' ')
        [ -n "$HTTP_ERROR" ] || HTTP_ERROR='no answer'
        return 0
    fi
    HTTP_TEXT=$(head -c 1048576 "$FK_HTTP_DIR/body" | LC_ALL=C tr -d '\000')
    HTTP_RETRY_AFTER=$(LC_ALL=C awk 'tolower($1) == "retry-after:" { v = $2; sub(/\r$/, "", v); if (v ~ /^[0-9]+$/) print v; exit }' "$FK_HTTP_DIR/headers")
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
    # Logs of the two services that run as root (the restart service and the
    # packet filter job). They have a folder of their own that only root can
    # touch: root must never write through a path the service account could
    # replace with a link to another file.
    _fk_make_dir "$FARM_ROOT_LOGS" private
    if [ -n "${1:-}" ]; then
        # The provider's own folder is handed to the service account. It must
        # be a folder of its own, never one of the kit's (see
        # test_provider_nickname; this is the same rule, checked on the disk).
        if [ -e "$FARM_ROOT/$1" ]; then
            for d in "$FARM_BIN" "$FARM_SERVICES" "$FARM_CONFIG" "$FARM_LOGS" "$FARM_ROOT_LOGS" "$FARM_DOWNLOADS" "$FARM_DATA" "$FARM_VAR" \
                "$FARM_ROOT/npm" "$FARM_ROOT/appium" "$FARM_ROOT/export" "$FARM_ROOT/previous" "$FARM_ROOT/export-stage" "$FARM_ROOT/import-stage"; do
                if [ "$FARM_ROOT/$1" -ef "$d" ]; then
                    stop_farm "The provider nickname \"$1\" cannot be used: $FARM_ROOT/$1 is a folder the kit itself uses." 'Choose another nickname, for example Provider1.'
                fi
            done
        fi
        _fk_make_dir "$FARM_ROOT/$1" service-write
    fi
    # Logs: the services append to them, each as the service account.
    if [ ! -d "$FARM_LOGS" ]; then mkdir "$FARM_LOGS" || stop_farm "Could not create $FARM_LOGS." 'Run the script again with sudo.'; fi
    if ! { chown "0:$FARM_SERVICE_GROUP" "$FARM_LOGS" && chmod 770 "$FARM_LOGS"; }; then
        stop_farm "Could not restrict access to $FARM_LOGS." 'Run the script again with sudo.'
    fi
}

# --- launchd ----------------------------------------------------------------

farm_plist_path() { printf '%s/%s.plist' "$FARM_LAUNCHD_DIR" "$(farm_label "$1")"; }

farm_service_loaded() { launchctl print "system/$(farm_label "$1")" > /dev/null 2>&1; }

launchd_process_id() {
    # The output of "launchctl print" on standard input -> the number of the
    # service's process, when launchd says the service is running; nothing
    # otherwise. "0" when it is running but no process number is shown.
    LC_ALL=C awk '
        /^[[:space:]]*state = running[[:space:]]*$/ { running = 1 }
        /^[[:space:]]*pid = [0-9]+[[:space:]]*$/ { if (pid == "") pid = $3 }
        END { if (running) print (pid == "" ? 0 : pid) }'
}

test_program_started() {
    # test_program_started <command line of a process>
    # Status 0 when it is a farm program, 1 when it is still the wrapper
    # (services/farm-run.sh) waiting for another service, or nothing at all.
    case $1 in '' | *farm-run.sh*) return 1 ;; esac
    return 0
}

farm_service_alive() {
    # Status 0 when launchd has a process for the service. That process may
    # still be the wrapper, waiting for the port of the service it needs.
    [ -n "$(launchctl print "system/$(farm_label "$1")" 2> /dev/null | launchd_process_id)" ]
}

farm_service_running() {
    # Status 0 when the program of the service itself runs: launchd has a
    # process for it AND that process is no longer the wrapper. Every service
    # is started through services/farm-run.sh, which waits for the service it
    # depends on; "launchd has a process" alone would call a hub that waits
    # for a MongoDB that never comes "running".
    local pid
    pid=$(launchctl print "system/$(farm_label "$1")" 2> /dev/null | launchd_process_id)
    [ -n "$pid" ] || return 1
    [ "$pid" = 0 ] && return 0
    test_program_started "$(ps -o command= -p "$pid" 2> /dev/null)"
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

copy_as_new_file() {
    # copy_as_new_file <source> <destination> [<owner:group> <mode>]
    # Puts a copy of the source at the destination as a NEW file: it is
    # written under another name in the same folder and then moved over the
    # destination. Never write a program onto the file it replaces: macOS
    # remembers the code signature of a program per file, and on Apple Silicon
    # a program that was rewritten in place is killed when it starts ("Code
    # Signature Invalid") until the Mac is restarted. A script that is
    # running is not changed under the shell that reads it, either.
    # Without owner and mode, those of the source are kept.
    # The quarantine mark macOS puts on files that came through a browser is
    # taken off the copy: it would stop a service from starting the program.
    # Callers check the pinned SHA-256 of a program before they call this.
    local tmp="$2.new.$$"
    rm -f "$tmp"
    if [ $# -ge 4 ]; then
        if ! { cp -f "$1" "$tmp" && chown "$3" "$tmp" && chmod "$4" "$tmp"; }; then rm -f "$tmp"; return 1; fi
    else
        if ! cp -pf "$1" "$tmp"; then rm -f "$tmp"; return 1; fi
    fi
    if command -v xattr > /dev/null 2>&1; then xattr -d com.apple.quarantine "$tmp" > /dev/null 2>&1; fi
    if ! mv -f "$tmp" "$2"; then rm -f "$tmp"; return 1; fi
    return 0
}

install_one_file() {
    # install_one_file <source> <destination>   (root owns it; the service account may run it)
    if ! copy_as_new_file "$1" "$2" "0:$FARM_SERVICE_GROUP" 750; then
        stop_farm "Could not write $2." 'Check the free space on the disk and run the script again with sudo.'
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
        if ! copy_as_new_file "$KIT_ROOT/services/$file" "$FARM_SERVICES/$file" "0:$FARM_SERVICE_GROUP" 640; then
            stop_farm "Could not write $FARM_SERVICES/$file." 'Run the script again with sudo.'
        fi
    done
    if ! copy_as_new_file "$KIT_ROOT/lib/json.awk" "$FARM_SERVICES/json.awk" "0:$FARM_SERVICE_GROUP" 640; then
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
        if [ "$hub_user" = admin ]; then
            _fk_step signin fail 'The hub refused the password of its administrator "admin".' 'Run the test again and type the password you chose for the hub administrator when the farm was installed. If it is lost: README, section Troubleshooting, "Lost hub administrator password".'
        else
            _fk_step signin fail "The hub refused the password of the user \"$hub_user\"." "If you typed it by hand, run the test again as the hub administrator instead:   sudo bash scripts/self-test.sh --hub-user admin   . If Blossom reports the same for this user, give it a new password:   sudo bash scripts/rotate-secrets.sh --hub-user   . A paired computer hands the new password to Blossom by itself and does not show it; otherwise it is shown once, to be entered in Blossom."
        fi
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

    # extra check, not part of the product's test: the provider reports the
    # state of the phones to the hub on this path, from this computer, and
    # GADS 6.0.0 asks for no login there.
    invoke_farm_http "$hub/provider-update" --like-blossom --timeout 8
    if [ "$HTTP_STATUS" -eq 403 ]; then
        _fk_step hub-provider-update ok 'The path the provider reports to the hub on is refused at the tunnel (403), as it must be.' ''
    else
        _fk_step hub-provider-update fail "The hub path /provider-update is not refused by the tunnel (HTTP $HTTP_STATUS). GADS accepts reports about the phones there without a login." 'Run install.sh again: it rewrites the tunnel configuration and restarts the tunnel. If it stays like this, report it on the kit repository (privately: Security -> Report a vulnerability); see docs/security.md, section 3.'
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
        _fk_step restart fail 'The restart service refused the secret.' 'Run scripts/rotate-secrets.sh --restart-secret. A paired computer hands the new secret to Blossom by itself; otherwise enter it there.'
    elif test_looks_down "$HTTP_STATUS" "$HTTP_TEXT" || [ "$HTTP_STATUS" -ne 200 ] || ! printf '%s' "$HTTP_TEXT" | json_flatten > /dev/null 2>&1; then
        _fk_step restart fail "The restart service did not answer its status (HTTP $HTTP_STATUS)." 'Check the restart service and read /opt/farm/logs-root/restart-server.log.'
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
        _fk_step restart-locked fail "Without the secret the restart service answered HTTP $HTTP_STATUS (expected 401)." 'Do not use this farm until this is understood: read /opt/farm/logs-root/restart-server.log and docs/security.md.'
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
        hub-provider-update) echo 'Hub refuses reports from outside' ;;
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

# ---------------------------------------------------------------------------
# Pairing with Blossom CRM
# ---------------------------------------------------------------------------
# Blossom shows a command that carries a pairing code. The installer claims
# the code when it starts, sends the description of the farm when it has
# finished, and from then on this computer holds a "farm token": with it the
# scripts send new credentials to Blossom without a new code. The token is
# made here, kept in /opt/farm/config/pairing.json (root only), and Blossom
# stores only its SHA-256. Everything goes to the one https address the
# pairing was made with; a redirect is refused, not followed.
# docs/security.md, section 9, is the threat model.

FK_APP_TRIES=${FK_APP_TRIES:-4}
FK_APP_RETRY_DELAY=${FK_APP_RETRY_DELAY:-2}
FK_PAIR_HELP='In Blossom open Phone Farm -> Farm setup -> Connect a computer, copy the new command yourself and run it on this computer: it keeps what is already set up. Only ever run a command you took from your own Blossom, signed in.'

farm_kit_version() {
    local v=''
    if [ -n "${KIT_VERSIONS:-}" ]; then v=$(kit_version kit)
    elif [ -n "${FARM_CONFIG:-}" ]; then v=$(json_file_get "$FARM_CONFIG/versions.json" kit); fi
    case $v in '' | *[!0-9A-Za-z.+-]*) v='0' ;; esac
    printf '%s' "$v"
}

farm_computer_label() {
    local name=''
    if command -v scutil > /dev/null 2>&1; then name=$(scutil --get ComputerName 2> /dev/null); fi
    [ -n "$name" ] || name=$(hostname 2> /dev/null)
    clean_computer_label "${name%%.*}"
}

farm_os_version() {
    local v=''
    if command -v sw_vers > /dev/null 2>&1; then v=$(sw_vers -productVersion 2> /dev/null); fi
    if [ -n "$v" ]; then clean_computer_label "macOS $v"; else clean_computer_label "$(uname -sr 2> /dev/null)"; fi
}

_fk_computer_json() {
    # What this computer says about itself. No secret is in it.
    local installed=${FARM_CONFIG:-}/versions.json
    printf '{"label":%s,"platform":"macos","os_version":%s,"kit_version":%s,"gads_version":%s,"provider_version":%s}' \
        "$(json_string "$(farm_computer_label)")" "$(json_string "$(farm_os_version)")" "$(json_string "$(farm_kit_version)")" \
        "$(json_string "$(json_file_get "$installed" gads.version)")" "$(json_string "$(json_file_get "$installed" gadsDrag.version)")"
}

_fk_pair_clear() {
    FARM_IS_PAIRED=0
    PAIR_ORIGIN=''; PAIR_TOKEN=''; PAIR_CODE_SHA=''; PAIR_ID=''; PAIR_WORKSPACE=''; PAIR_WORKSPACE_ID=''; PAIR_CLAIMED_AT=''; PAIR_SITE_SENT_AT=''
}

read_farm_pairing() {
    # Sets FARM_IS_PAIRED (0|1) and, when this computer holds a pairing,
    # PAIR_ORIGIN, PAIR_TOKEN, PAIR_CODE_SHA, PAIR_ID, PAIR_WORKSPACE (the name
    # the workspace gives itself), PAIR_WORKSPACE_ID (the identifier Blossom
    # gives it, which nobody can choose), PAIR_CLAIMED_AT and
    # PAIR_SITE_SENT_AT (empty until Blossom has accepted the description of
    # the farm once).
    local text
    _fk_pair_clear
    [ -f "$FARM_PAIRING" ] || return 0
    text=$(cat "$FARM_PAIRING" 2> /dev/null)
    PAIR_ORIGIN=$(normalize_app_origin "$(json_get "$text" appOrigin)")
    PAIR_TOKEN=$(json_get "$text" farmToken)
    if [ -n "$(test_app_origin "$PAIR_ORIGIN")" ] || ! test_farm_token "$PAIR_TOKEN"; then _fk_pair_clear; return 0; fi
    PAIR_CODE_SHA=$(json_get "$text" codeSha256)
    PAIR_ID=$(json_get "$text" pairingId)
    PAIR_WORKSPACE=$(json_get "$text" workspace)
    PAIR_WORKSPACE_ID=$(clean_workspace_id "$(json_get "$text" workspaceId)")
    PAIR_CLAIMED_AT=$(json_get "$text" claimedAt)
    PAIR_SITE_SENT_AT=$(json_get "$text" siteSentAt)
    FARM_IS_PAIRED=1
}

write_farm_pairing() {
    # Writes PAIR_* to the pairing file (root only).
    write_secret_file "$FARM_PAIRING" "{
  \"appOrigin\": $(json_string "$PAIR_ORIGIN"),
  \"farmToken\": $(json_string "$PAIR_TOKEN"),
  \"codeSha256\": $(json_string "$PAIR_CODE_SHA"),
  \"pairingId\": $(json_string "$PAIR_ID"),
  \"workspace\": $(json_string "$PAIR_WORKSPACE"),
  \"workspaceId\": $(json_string "$PAIR_WORKSPACE_ID"),
  \"claimedAt\": $(json_string "$PAIR_CLAIMED_AT"),
  \"siteSentAt\": $(json_string "$PAIR_SITE_SENT_AT")
}
" private
}

forget_farm_pairing() {
    rm -f "$FARM_PAIRING" "$FARM_PAIRING_NEW"
    _fk_pair_clear
}

invoke_blossom() {
    # invoke_blossom <origin> <method> <path> [--body TEXT] [--bearer TOKEN] [--tries N]
    # One call to Blossom's pairing API. Status 0 when Blossom answered 2xx
    # with JSON; otherwise 1. Sets APP_STATUS, APP_TEXT (the JSON answer),
    # APP_CODE (the "code" of a refusal), APP_KIND and APP_MESSAGE (a sentence
    # for the person at the keyboard; never contains a secret).
    #   APP_KIND   ok           Blossom accepted the request
    #              refused      Blossom answered and said no (APP_CODE says why)
    #              origin       the address is not an https origin: nothing was sent
    #              tls          the certificate of the address could not be verified
    #              redirect     the address answered with a redirect: not followed
    #              not_blossom  the address answered, but not as Blossom's API
    #              network      no answer, or Blossom was busy, after every try
    # The request is repeated, with a growing pause, only when it did not
    # arrive or Blossom said to come back later (429, 5xx).
    local origin=$1 method=$2 path=$3 body='' bearer='' tries=$FK_APP_TRIES reason try=1 delay=$FK_APP_RETRY_DELAY wait_s
    shift 3
    while [ $# -gt 0 ]; do
        case $1 in
            --body) body=$2; shift 2 ;;
            --bearer) bearer=$2; shift 2 ;;
            --tries) tries=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    APP_STATUS=0; APP_TEXT=''; APP_CODE=''; APP_KIND=''; APP_MESSAGE=''
    origin=$(normalize_app_origin "$origin")
    reason=$(test_app_origin "$origin")
    if [ -n "$reason" ]; then APP_KIND=origin; APP_MESSAGE="$reason Nothing was sent."; return 1; fi
    while true; do
        invoke_farm_http "$origin$path" --https-only --method "$method" --body "$body" --bearer "$bearer" --timeout 20 --agent "blossom-farm-kit/$(farm_kit_version)"
        APP_STATUS=$HTTP_STATUS; APP_TEXT=''; APP_CODE=''
        if [ "$HTTP_STATUS" -eq 0 ]; then
            case $HTTP_CURL_CODE in
                35 | 51 | 53 | 54 | 58 | 59 | 60 | 64 | 66 | 77 | 80 | 82 | 83 | 90 | 91)
                    APP_KIND=tls
                    APP_MESSAGE="The certificate of $origin could not be verified ($(clean_remote_text "$HTTP_ERROR")). Nothing was sent. Check the date and time of this computer; if they are right, something between this computer and Blossom is intercepting the connection."
                    return 1 ;;
            esac
            APP_KIND=network
            APP_MESSAGE="$origin could not be reached ($(clean_remote_text "$HTTP_ERROR")). Check the internet connection of this computer."
        elif [ "$HTTP_STATUS" -ge 300 ] && [ "$HTTP_STATUS" -lt 400 ]; then
            APP_KIND=redirect
            APP_MESSAGE="$origin answered with a redirect (HTTP $HTTP_STATUS). The farm's credentials are only sent to the address the pairing was made with, so the redirect was not followed. Copy the command from Blossom again."
            return 1
        elif [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
            if [ -n "$HTTP_TEXT" ] && printf '%s' "$HTTP_TEXT" | json_flatten > /dev/null 2>&1; then
                APP_KIND=ok; APP_TEXT=$HTTP_TEXT
                return 0
            fi
            APP_KIND=not_blossom
            APP_MESSAGE="$origin answered, but not the way Blossom does. Is it the address you open Blossom at? Copy the command from Blossom again."
            return 1
        else
            APP_CODE=$(json_get "$HTTP_TEXT" code)
            case $APP_CODE in *[!a-z0-9_]*) APP_CODE='' ;; esac
            if [ "$HTTP_STATUS" -eq 429 ] || [ "$HTTP_STATUS" -ge 500 ]; then
                APP_KIND=network
                APP_MESSAGE="Blossom is busy or not available right now (HTTP $HTTP_STATUS)."
            elif [ -z "$APP_CODE" ]; then
                APP_KIND=not_blossom
                APP_MESSAGE="$origin answered HTTP $HTTP_STATUS, but not the way Blossom does. Is it the address you open Blossom at? Is this kit current?"
                return 1
            else
                APP_KIND=refused
                APP_TEXT=$HTTP_TEXT
                APP_MESSAGE=$(get_pairing_message "$APP_CODE" "$(json_get "$HTTP_TEXT" error)")
                return 1
            fi
        fi
        if [ "$try" -ge "$tries" ]; then return 1; fi
        wait_s=$delay
        case $HTTP_RETRY_AFTER in '' | *[!0-9]*) ;; *) if [ "${#HTTP_RETRY_AFTER}" -le 4 ]; then wait_s=$((10#$HTTP_RETRY_AFTER)); fi ;; esac
        [ "$wait_s" -gt 60 ] && wait_s=60
        sleep "$wait_s"
        try=$((try + 1))
        delay=$((delay * 2)); [ "$delay" -gt 30 ] && delay=30
    done
}

_fk_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

clean_workspace_id() {
    # The identifier of a workspace as Blossom sends it: letters, digits and
    # hyphens, at most 64 (a UUID). Anything else prints nothing.
    local LC_ALL=C
    case $1 in '' | *[!A-Za-z0-9-]*) return 0 ;; esac
    [ "${#1}" -le 64 ] && to_lower "$1"
    return 0
}

test_same_workspace() {
    # test_same_workspace <origin a> <workspace id a> <origin b> <workspace id b>
    # Status 0 only when both pairings are with the same Blossom AND the same
    # workspace, by its identifier. A workspace NAME is never compared: the
    # owner of a workspace chooses it, so it proves nothing.
    [ -n "$2" ] && [ -n "$4" ] && [ "$1" = "$3" ] && [ "$2" = "$4" ]
}

read_typed_word() {
    # read_typed_word <prompt>   sets REPLY_WORD. Status 1 when nobody is at a
    # keyboard (no terminal): the caller must then take that as "no".
    REPLY_WORD=''
    if ! { : < /dev/tty; } 2> /dev/null; then return 1; fi
    IFS= read -r -p "$1" REPLY_WORD < /dev/tty || return 1
    return 0
}

confirm_pairing_replacement() {
    # confirm_pairing_replacement <old origin> <old workspace name> <new origin> <new workspace name or ''>
    # A computer that is paired is about to be paired with ANOTHER workspace
    # (or another Blossom). That moves the farm: the hub login gets a new
    # password, and the addresses, that password and the restart secret go to
    # the new place. A genuine command made in somebody else's workspace would
    # do exactly this, so it is never done without a yes from the keyboard,
    # or the option that says so (--replace-pairing sets FK_REPLACE_PAIRING).
    # Status 0: go on. 1: keep the pairing as it is.
    if [ "${FK_REPLACE_PAIRING:-0}" = 1 ]; then return 0; fi
    echo
    write_color "$FK_YELLOW" '   This computer is already paired with Blossom:'
    write_color "$FK_YELLOW" "       $1${2:+   (workspace \"$2\")}"
    write_color "$FK_YELLOW" '   The command you ran pairs it with another workspace:'
    write_color "$FK_YELLOW" "       $3${4:+   (workspace \"$4\")}"
    write_color "$FK_YELLOW" '   If you go on, the farm LEAVES the first one: its hub login gets a new'
    write_color "$FK_YELLOW" '   password, and its addresses, that password and the restart secret are sent'
    write_color "$FK_YELLOW" '   to the second. Whoever confirms the computer there controls the phones.'
    write_color "$FK_YELLOW" '   A workspace name proves nothing: whoever owns a workspace chooses its name.'
    write_color "$FK_YELLOW" '   Go on only if you copied this command yourself from your own Blossom, signed'
    write_color "$FK_YELLOW" '   in. A command that somebody sent you is a reason to stop.'
    if ! read_typed_word '   Type the word  replace  to go on (anything else keeps the pairing as it is): '; then return 1; fi
    [ "$(to_lower "$(trim_text "$REPLY_WORD")")" = replace ]
}

_fk_pairing_kept() {
    # $1 the Blossom the computer stays paired with
    APP_KIND=declined; APP_CODE=''; APP_STATUS=0
    APP_MESSAGE="This computer stays paired with $1: the new command would have moved the farm to another workspace, and nobody said yes to that at the keyboard. To move it on purpose, run the command again in a Terminal window and answer the question, or add --replace-pairing at its end."
}

default_self_test_user() {
    # default_self_test_user <the hub user Blossom uses>
    # Prints the hub user scripts/self-test.sh signs in with when none is
    # named. On a paired computer nobody has the password of Blossom's own
    # user (it was sent to Blossom and never shown), so the test uses the hub
    # administrator, whose password the owner chose.
    read_farm_pairing
    if [ "$FARM_IS_PAIRED" = 1 ] && [ -n "$PAIR_SITE_SENT_AT" ]; then echo admin; else printf '%s\n' "${1:-blossom}"; fi
}

pair_claim() {
    # pair_claim <origin> <pairing code>
    # Hands the pairing code to Blossom together with a farm token made here.
    # Status 0: Blossom knows this computer; pairing.json holds the token.
    # Status 1: APP_KIND and APP_MESSAGE say why; an earlier pairing of this
    # computer is left as it was. APP_KIND "declined": the computer is paired
    # with another workspace and nobody agreed to move it
    # (confirm_pairing_replacement).
    #
    # The token is written to disk BEFORE it is sent: if the answer is lost on
    # the way, running the same command again repeats the claim with the same
    # token, which Blossom accepts as the same claim.
    local origin code code_sha token='' text old_origin='' old_token='' old_workspace='' old_workspace_id='' agreed=0 body new_workspace new_workspace_id
    origin=$(normalize_app_origin "$1")
    code=$(normalize_pairing_code "$2")
    APP_STATUS=0; APP_TEXT=''; APP_CODE=''; APP_KIND=''; APP_MESSAGE=''
    text=$(test_app_origin "$origin")
    if [ -n "$text" ]; then APP_KIND=origin; APP_MESSAGE="$text Nothing was sent."; return 1; fi
    text=$(test_pairing_code "$code")
    if [ -n "$text" ]; then APP_KIND=origin; APP_MESSAGE="$text Nothing was sent."; return 1; fi
    code_sha=$(get_text_sha256 "$origin $code")

    read_farm_pairing
    if [ "$FARM_IS_PAIRED" = 1 ]; then
        if [ "$PAIR_CODE_SHA" = "$code_sha" ] && [ -n "$PAIR_CLAIMED_AT" ]; then
            APP_KIND=ok
            return 0   # this very code was claimed by this computer before
        fi
        old_origin=$PAIR_ORIGIN; old_token=$PAIR_TOKEN; old_workspace=$PAIR_WORKSPACE; old_workspace_id=$PAIR_WORKSPACE_ID
        if [ "$old_origin" != "$origin" ]; then
            # another Blossom altogether: asked before anything is sent to it
            if ! confirm_pairing_replacement "$old_origin" "$old_workspace" "$origin" ''; then _fk_pairing_kept "$old_origin"; return 1; fi
            agreed=1
        fi
    fi
    if [ -f "$FARM_PAIRING_NEW" ]; then
        text=$(cat "$FARM_PAIRING_NEW" 2> /dev/null)
        if [ "$(json_get "$text" codeSha256)" = "$code_sha" ]; then token=$(json_get "$text" farmToken); fi
    fi
    if ! test_farm_token "$token"; then
        token=$(new_farm_token)
        if ! test_farm_token "$token"; then APP_KIND=origin; APP_MESSAGE='The random generator of this computer gave no token.'; return 1; fi
        write_secret_file "$FARM_PAIRING_NEW" "{\"codeSha256\": $(json_string "$code_sha"), \"farmToken\": $(json_string "$token")}" private
    fi

    body="{\"protocol\":1,\"pairing_code\":$(json_string "$code"),\"farm_token\":$(json_string "$token"),\"computer\":$(_fk_computer_json)}"
    if ! invoke_blossom "$origin" POST /api/farm/pair/claim --body "$body"; then
        body=''
        case $APP_CODE in pairing_code_unknown | pairing_code_expired | pairing_code_used | bad_request) rm -f "$FARM_PAIRING_NEW" ;; esac
        return 1
    fi
    body=''
    new_workspace=$(clean_remote_text "$(json_get "$APP_TEXT" workspace_name)")
    new_workspace_id=$(clean_workspace_id "$(json_get "$APP_TEXT" workspace_id)")
    if [ -n "$old_token" ] && [ "$agreed" = 0 ] && ! test_same_workspace "$old_origin" "$old_workspace_id" "$origin" "$new_workspace_id"; then
        # The same Blossom, but the code belongs to another workspace (only
        # the answer to the claim tells). So far that workspace has the name
        # of this computer and nothing else.
        text=$APP_TEXT
        if ! confirm_pairing_replacement "$old_origin" "$old_workspace" "$origin" "$new_workspace"; then
            # give the claim up again, and keep the pairing this computer has
            invoke_blossom "$origin" DELETE /api/farm/pair/token --bearer "$token" --tries 2 || true
            rm -f "$FARM_PAIRING_NEW"
            read_farm_pairing
            _fk_pairing_kept "$old_origin"
            return 1
        fi
        APP_TEXT=$text; APP_KIND=ok; APP_MESSAGE=''; APP_CODE=''
    fi
    PAIR_ORIGIN=$origin; PAIR_TOKEN=$token; PAIR_CODE_SHA=$code_sha
    PAIR_ID=$(clean_remote_text "$(json_get "$APP_TEXT" pairing_id)")
    PAIR_WORKSPACE=$new_workspace; PAIR_WORKSPACE_ID=$new_workspace_id
    PAIR_CLAIMED_AT=$(_fk_now); PAIR_SITE_SENT_AT=''
    write_farm_pairing
    rm -f "$FARM_PAIRING_NEW"
    FARM_IS_PAIRED=1
    if [ -n "$old_token" ] && [ "$old_token" != "$token" ]; then
        # the pairing this one replaces: tell its Blossom, without insisting
        invoke_blossom "$old_origin" DELETE /api/farm/pair/token --bearer "$old_token" --tries 1 || true
        APP_KIND=ok; APP_MESSAGE=''; APP_CODE=''
    fi
    return 0
}

_fk_pair_read_answer() {
    # Reads the state out of an answer of Blossom (APP_TEXT).
    local v
    PAIR_STATE=$(json_get "$APP_TEXT" state)
    case $PAIR_STATE in installing | checking | awaiting_confirmation | active | rejected | expired) ;; *) PAIR_STATE='' ;; esac
    PAIR_NEEDS_CONFIRMATION=$(json_get "$APP_TEXT" needs_confirmation)
    PAIR_SITE_LABEL=$(clean_remote_text "$(json_get "$APP_TEXT" site_label)")
    [ "$PAIR_SITE_LABEL" = null ] && PAIR_SITE_LABEL=''
    v=$(clean_remote_text "$(json_get "$APP_TEXT" workspace_name)")
    [ -n "$v" ] && [ "$v" != null ] && PAIR_WORKSPACE=$v
    PAIR_CHECK_OK=$(json_get "$APP_TEXT" check.ok)
    PAIR_DEVICES=$(json_get "$APP_TEXT" check.devices)
    case $PAIR_DEVICES in '' | *[!0-9]*) PAIR_DEVICES='' ;; esac
    PAIR_CHECK_STEP=$(clean_remote_text "$(json_get "$APP_TEXT" check.failed_step)")
    [ "$PAIR_CHECK_STEP" = null ] && PAIR_CHECK_STEP=''
    PAIR_CHECK_DETAIL=$(clean_remote_text "$(json_get "$APP_TEXT" check.detail)")
    [ "$PAIR_CHECK_DETAIL" = null ] && PAIR_CHECK_DETAIL=''
    PAIR_POLL=$(json_get "$APP_TEXT" poll_after_seconds)
    case $PAIR_POLL in '' | *[!0-9]* | ?????*) PAIR_POLL=3 ;; esac
    [ "$PAIR_POLL" -lt 1 ] && PAIR_POLL=1
    [ "$PAIR_POLL" -gt 30 ] && PAIR_POLL=30
    return 0
}

pair_send_site() {
    # pair_send_site <hub url> <provider url> <nickname> <hub user> <hub password or ''> <restart url> <restart secret or ''>
    # Sends the description of this farm to the Blossom it is paired with, with
    # the farm token. A password or secret that is left empty means "keep the
    # one you have", which Blossom refuses (APP_CODE credentials_required)
    # when it has none for these addresses. Status 0 when Blossom accepted;
    # then PAIR_STATE and PAIR_NEEDS_CONFIRMATION say where the pairing stands.
    local site body
    read_farm_pairing
    APP_STATUS=0; APP_TEXT=''; APP_CODE=''; APP_KIND=''; APP_MESSAGE=''
    if [ "$FARM_IS_PAIRED" != 1 ]; then APP_KIND=origin; APP_MESSAGE='This computer is not paired with Blossom.'; return 1; fi
    site="\"hub_url\":$(json_string "$1"),\"provider_url\":$(json_string "$2"),\"provider_nickname\":$(json_string "$3"),\"hub_user\":$(json_string "$4"),\"restart_url\":$(json_string "$6")"
    [ -n "$5" ] && site="$site,\"hub_password\":$(json_string "$5")"
    [ -n "$7" ] && site="$site,\"restart_secret\":$(json_string "$7")"
    body="{\"protocol\":1,\"site\":{$site},\"computer\":$(_fk_computer_json)}"
    site=''
    if ! invoke_blossom "$PAIR_ORIGIN" PUT /api/farm/pair/site --bearer "$PAIR_TOKEN" --body "$body"; then body=''; return 1; fi
    body=''
    _fk_pair_read_answer
    PAIR_SITE_SENT_AT=$(_fk_now)
    write_farm_pairing
    return 0
}

pair_send_computer() {
    # Tells Blossom the versions this computer runs now (after an update).
    read_farm_pairing
    APP_STATUS=0; APP_TEXT=''; APP_CODE=''; APP_KIND=''; APP_MESSAGE=''
    if [ "$FARM_IS_PAIRED" != 1 ]; then APP_KIND=origin; APP_MESSAGE='This computer is not paired with Blossom.'; return 1; fi
    invoke_blossom "$PAIR_ORIGIN" PUT /api/farm/pair/site --bearer "$PAIR_TOKEN" --body "{\"protocol\":1,\"computer\":$(_fk_computer_json)}" --tries 2 || return 1
    _fk_pair_read_answer
    return 0
}

pair_get_status() {
    # pair_get_status [tries=2]
    # Asks Blossom where the pairing stands. Status 0: PAIR_STATE is one of
    # installing, checking, awaiting_confirmation, active, rejected, expired;
    # PAIR_CHECK_OK (true, false or empty), PAIR_DEVICES, PAIR_CHECK_STEP and
    # PAIR_CHECK_DETAIL describe what Blossom found when it called the farm.
    read_farm_pairing
    APP_STATUS=0; APP_TEXT=''; APP_CODE=''; APP_KIND=''; APP_MESSAGE=''
    PAIR_STATE=''; PAIR_CHECK_OK=''; PAIR_DEVICES=''; PAIR_CHECK_STEP=''; PAIR_CHECK_DETAIL=''; PAIR_SITE_LABEL=''; PAIR_POLL=3; PAIR_NEEDS_CONFIRMATION=''
    if [ "$FARM_IS_PAIRED" != 1 ]; then APP_KIND=origin; APP_MESSAGE='This computer is not paired with Blossom.'; return 1; fi
    invoke_blossom "$PAIR_ORIGIN" GET /api/farm/pair/status --bearer "$PAIR_TOKEN" --tries "${1:-2}" || return 1
    _fk_pair_read_answer
    if [ -z "$PAIR_STATE" ]; then APP_KIND=not_blossom; APP_MESSAGE="$PAIR_ORIGIN answered, but with a pairing state this kit does not know. Is this kit current?"; return 1; fi
    return 0
}

describe_pairing_check() {
    # One sentence about what Blossom found when it called the farm.
    local phones
    if [ "$PAIR_CHECK_OK" = true ]; then
        case ${PAIR_DEVICES:-0} in
            0) phones='no phone yet (expected until the phones are added)' ;;
            1) phones='1 phone' ;;
            *) phones="$PAIR_DEVICES phones" ;;
        esac
        echo "Blossom sees your farm: $phones."
    elif [ "$PAIR_CHECK_OK" = false ]; then
        echo "Blossom could not use the farm yet${PAIR_CHECK_STEP:+ (step: $PAIR_CHECK_STEP)}${PAIR_CHECK_DETAIL:+: $PAIR_CHECK_DETAIL}"
    fi
}

pair_wait() {
    # pair_wait [seconds to wait at most=600]
    # Follows the pairing after the farm was sent, and says what happens.
    # Status 0: the site is active in Blossom. 2: still waiting for somebody
    # to confirm in Blossom (nothing is lost). 1: declined, expired, or
    # Blossom no longer accepts this computer.
    local max=${1:-600} waited=0 last='' said_confirm=0 line
    while true; do
        if pair_get_status 1; then
            case $PAIR_STATE in
                active)
                    line=$(describe_pairing_check)
                    write_ok "Confirmed in Blossom${PAIR_SITE_LABEL:+ as \"$PAIR_SITE_LABEL\"}. ${line:-The site is active.}"
                    return 0 ;;
                awaiting_confirmation)
                    if [ "$said_confirm" = 0 ]; then
                        said_confirm=1
                        line=$(describe_pairing_check)
                        if [ "$PAIR_CHECK_OK" = false ]; then write_warn "$line"; elif [ -n "$line" ]; then write_ok "$line"; fi
                        write_color "$FK_YELLOW" "   Now confirm in Blossom: Phone Farm -> Farm setup shows this computer (\"$(farm_computer_label)\")"
                        write_color "$FK_YELLOW" '   with its addresses. Check that they are yours, then press Confirm. Waiting...'
                    fi ;;
                checking) [ "$last" = checking ] || write_note 'Blossom is calling the farm from its servers...' ;;
                installing) [ "$last" = installing ] || write_note 'Blossom is waiting for the description of the farm.' ;;
                rejected) write_warn "This computer was declined in Blossom. $FK_PAIR_HELP"; return 1 ;;
                expired) write_warn "The pairing was not confirmed in Blossom in time. $FK_PAIR_HELP"; return 1 ;;
            esac
            last=$PAIR_STATE
        elif [ "$APP_KIND" = refused ]; then
            write_warn "$APP_MESSAGE $FK_PAIR_HELP"
            return 1
        elif [ "$APP_KIND" != network ]; then
            write_warn "$APP_MESSAGE"
            return 1
        fi
        if [ "$waited" -ge "$max" ]; then return 2; fi
        sleep "$PAIR_POLL"
        waited=$((waited + PAIR_POLL))
    done
}

pair_unpair() {
    # Tells Blossom that this computer gives up its farm token, and deletes
    # the pairing file. Status 0 when Blossom took note or no longer knew the
    # token; 1 when it could not be told (the file is kept).
    read_farm_pairing
    APP_STATUS=0; APP_TEXT=''; APP_CODE=''; APP_KIND=''; APP_MESSAGE=''
    if [ "$FARM_IS_PAIRED" != 1 ]; then forget_farm_pairing; return 0; fi
    if invoke_blossom "$PAIR_ORIGIN" DELETE /api/farm/pair/token --bearer "$PAIR_TOKEN" --tries 2; then forget_farm_pairing; return 0; fi
    if [ "$APP_KIND" = refused ] && [ "$APP_STATUS" -eq 401 ]; then forget_farm_pairing; return 0; fi
    return 1
}

# ---------------------------------------------------------------------------
# A newer kit: where it is looked for, and how it is checked before use
# (scripts/update.sh --check and --latest; docs/security.md, section 9).
# ---------------------------------------------------------------------------

# The branch "main" of the kit repository says which kit is the released one:
# versions.json carries its version, pairing.json the commit it was made from
# and the SHA-256 of that commit's MANIFEST.sha256.
FARM_KIT_REPOSITORY='fyhcrew-art/blossom-farm-kit'
FARM_KIT_RAW_URL='https://raw.githubusercontent.com/fyhcrew-art/blossom-farm-kit'
FARM_KIT_ARCHIVE_URL='https://github.com/fyhcrew-art/blossom-farm-kit/archive'

test_git_commit_text() {
    local LC_ALL=C
    local re='^[0-9a-f]{40}$'
    [[ $1 =~ $re ]]
}

test_kit_tree() {
    # test_kit_tree <folder> <SHA-256 of its MANIFEST.sha256>
    # Prints what is wrong with an unpacked kit, or nothing when every file is
    # the one its list names: the list has the SHA-256 given; every file on
    # the list is there with its SHA-256; nothing is there that the list does
    # not name, except the four files that cannot be on it (MANIFEST.sha256
    # itself, bootstrap.sh, bootstrap.ps1, pairing.json); nothing is a link.
    local dir=$1 want_list=$2 got want name extra allowed
    if [ ! -f "$dir/MANIFEST.sha256" ]; then echo 'It has no MANIFEST.sha256.'; return 0; fi
    got=$(get_file_sha256 "$dir/MANIFEST.sha256")
    if [ "$got" != "$(to_lower "$want_list")" ]; then
        echo "Its list of files is not the expected one (expected SHA-256 $want_list, got $got)."
        return 0
    fi
    if LC_ALL=C grep -q -v -E '^[0-9a-f]{64}  [A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' "$dir/MANIFEST.sha256" || LC_ALL=C grep -q -E '(^|[ /])\.\.?(/|$)' "$dir/MANIFEST.sha256"; then
        echo 'Its list of files has a line that is not a checksum and a file name.'
        return 0
    fi
    if [ -n "$(cd "$dir" && find . ! -type f ! -type d -print | head -n 1)" ]; then
        echo 'It holds something that is neither a file nor a folder.'
        return 0
    fi
    while read -r want name; do
        if [ ! -f "$dir/$name" ]; then echo "The file $name is missing."; return 0; fi
        got=$(get_file_sha256 "$dir/$name")
        if [ "$got" != "$want" ]; then
            echo "The file $name is not the one the list names (expected SHA-256 $want, got $got)."
            return 0
        fi
    done < "$dir/MANIFEST.sha256"
    allowed=$( { awk '{ print $2 }' "$dir/MANIFEST.sha256"; printf 'MANIFEST.sha256\nbootstrap.sh\nbootstrap.ps1\npairing.json\n'; } | LC_ALL=C sort -u)
    extra=$( (cd "$dir" && find . -type f -print) | sed 's|^\./||' | LC_ALL=C sort | awk -v allowed="$allowed" '
        BEGIN { n = split(allowed, a, "\n"); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
        !($0 in ok) { print; exit }')
    if [ -n "$extra" ]; then echo "It holds a file that its list does not name: $extra"; fi
    return 0
}

test_kit_update_rules() {
    # test_kit_update_rules <text of this kit's versions.json> <text of the fetched kit's versions.json>
    # Prints why a kit that was fetched may not replace this one, or nothing.
    # The rules a kit enforces on its successor, whoever published it:
    #   * the version goes up, never back or sideways;
    #   * a program keeps its checksum as long as it keeps its version: a kit
    #     that names the provider (or the hub) by the version this kit names
    #     must pin the same SHA-256 for it, on every system. Another file
    #     under the same version is refused; a changed program has to come
    #     with a new version, which the update shows before it replaces
    #     anything;
    #   * every download address is https.
    local old=$1 new=$2 a b key
    a=$(json_get "$old" kit); b=$(json_get "$new" kit)
    case $b in '' | *[!0-9.]*) echo 'It names no usable kit version.'; return 0 ;; esac
    if [ "$a" = "$b" ] || ! version_at_least "$b" "$a"; then
        echo "It is kit $b, which is not newer than this kit ($a)."
        return 0
    fi
    if [ "$(json_get "$old" gadsDrag.version)" = "$(json_get "$new" gadsDrag.version)" ]; then
        for key in gadsDrag.sha256 macos.arm64.provider.sha256 macos.x86_64.provider.sha256; do
            a=$(to_lower "$(json_get "$old" "$key")"); b=$(to_lower "$(json_get "$new" "$key")")
            if [ -n "$a" ] && [ "$a" != "$b" ]; then
                echo "It pins another file for the provider $(json_get "$new" gadsDrag.version) than this kit does ($key: $b instead of $a). A changed program must carry a new version."
                return 0
            fi
        done
    fi
    if [ "$(json_get "$old" gads.version)" = "$(json_get "$new" gads.version)" ]; then
        for key in gads.hubZipSha256 gads.hubExeSha256 macos.arm64.hub.zipSha256 macos.arm64.hub.exeSha256 macos.x86_64.hub.zipSha256 macos.x86_64.hub.exeSha256; do
            a=$(to_lower "$(json_get "$old" "$key")"); b=$(to_lower "$(json_get "$new" "$key")")
            if [ -n "$a" ] && [ "$a" != "$b" ]; then
                echo "It pins another file for GADS $(json_get "$new" gads.version) than this kit does ($key: $b instead of $a). A changed program must carry a new version."
                return 0
            fi
        done
    fi
    b=$(printf '%s' "$new" | json_flatten 2> /dev/null | LC_ALL=C awk -F '\t' '$1 ~ /(^|\.)([a-zA-Z]*[uU]rl)$/ && $2 !~ /^https:\/\// { print $1; exit }')
    if [ -n "$b" ]; then echo "Its download address $b is not https."; fi
    return 0
}

kit_fetch_file() {
    # kit_fetch_file <address> <out file> [seconds]
    # One https download, redirects followed to https only. Sets KIT_FETCH_STATUS
    # (the HTTP status; 0 when there was no answer or the transfer broke off)
    # and KIT_FETCH_ERROR. Status 0 only for a complete answer 200.
    local url=$1 out=$2 max=${3:-120} code rc err
    KIT_FETCH_STATUS=0; KIT_FETCH_ERROR=''
    case $url in https://*) ;; *) KIT_FETCH_ERROR='the address is not https'; return 1 ;; esac
    err=$out.err
    code=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 -sS -L --max-redirs 5 --connect-timeout 30 --max-time "$max" -o "$out" -w '%{http_code}' "$url" 2> "$err")
    rc=$?
    KIT_FETCH_ERROR=$(tr '\n' ' ' < "$err" 2> /dev/null)
    rm -f "$err"
    if [ "$rc" -ne 0 ]; then rm -f "$out"; [ -n "$KIT_FETCH_ERROR" ] || KIT_FETCH_ERROR="curl ended with status $rc"; return 1; fi
    KIT_FETCH_STATUS=$code
    if [ "$code" != 200 ]; then rm -f "$out"; KIT_FETCH_ERROR="HTTP $code"; return 1; fi
    return 0
}

get_released_kit() {
    # get_released_kit <work folder>
    # Asks the branch "main" of the kit repository which kit is released.
    # Sets RELEASED_KIT_VERSION, and RELEASED_KIT_COMMIT and
    # RELEASED_KIT_MANIFEST when pairing.json there names that same version
    # (otherwise both are empty: main already carries a newer kit that is not
    # released yet). Status 1 with RELEASED_KIT_ERROR when main cannot be read.
    local work=$1 text
    RELEASED_KIT_VERSION=''; RELEASED_KIT_COMMIT=''; RELEASED_KIT_MANIFEST=''; RELEASED_KIT_ERROR=''
    if ! kit_fetch_file "$FARM_KIT_RAW_URL/main/versions.json" "$work/main-versions.json" 60; then
        RELEASED_KIT_ERROR="versions.json of the kit repository could not be read ($KIT_FETCH_ERROR)."
        return 1
    fi
    RELEASED_KIT_VERSION=$(json_file_get "$work/main-versions.json" kit)
    case $RELEASED_KIT_VERSION in
        '' | *[!0-9.]*) RELEASED_KIT_VERSION=''; RELEASED_KIT_ERROR='versions.json of the kit repository names no kit version.'; return 1 ;;
    esac
    if ! kit_fetch_file "$FARM_KIT_RAW_URL/main/pairing.json" "$work/main-pairing.json" 60; then
        if [ "$KIT_FETCH_STATUS" = 404 ]; then return 0; fi
        RELEASED_KIT_ERROR="pairing.json of the kit repository could not be read ($KIT_FETCH_ERROR)."
        return 1
    fi
    text=$(cat "$work/main-pairing.json")
    if [ "$(json_get "$text" kitVersion)" != "$RELEASED_KIT_VERSION" ]; then return 0; fi
    RELEASED_KIT_COMMIT=$(json_get "$text" kitCommit)
    RELEASED_KIT_MANIFEST=$(to_lower "$(json_get "$text" manifestSha256)")
    if ! test_git_commit_text "$RELEASED_KIT_COMMIT" || ! test_sha256_text "$RELEASED_KIT_MANIFEST"; then
        RELEASED_KIT_COMMIT=''; RELEASED_KIT_MANIFEST=''
        RELEASED_KIT_ERROR='pairing.json of the kit repository does not name a commit and the SHA-256 of its list of files.'
        return 1
    fi
    return 0
}

fetch_kit_commit() {
    # fetch_kit_commit <commit> <SHA-256 of its MANIFEST.sha256> <empty work folder>
    # Downloads the archive GitHub makes of the kit at that commit, looks at
    # its list before unpacking (everything inside the one folder of the
    # commit, files and folders only), unpacks it and checks every file
    # (test_kit_tree). On success the kit is in <work folder>/kit, without
    # the files that are not on its list, and the status is 0. Otherwise
    # FETCHED_KIT_ERROR says why and nothing usable is left.
    local commit=$1 manifest=$2 work=$3 top bad problem
    FETCHED_KIT_ERROR=''
    if ! test_git_commit_text "$commit"; then FETCHED_KIT_ERROR='That is not a commit.'; return 1; fi
    top="${FARM_KIT_REPOSITORY##*/}-$commit"
    if ! kit_fetch_file "$FARM_KIT_ARCHIVE_URL/$commit.tar.gz" "$work/kit.tar.gz" 900; then
        FETCHED_KIT_ERROR="The kit could not be downloaded ($KIT_FETCH_ERROR). Address: $FARM_KIT_ARCHIVE_URL/$commit.tar.gz"
        return 1
    fi
    if ! tar -tzf "$work/kit.tar.gz" > "$work/names" 2> /dev/null || ! tar -tvzf "$work/kit.tar.gz" > "$work/listing" 2> /dev/null || [ ! -s "$work/names" ]; then
        rm -f "$work/kit.tar.gz"
        FETCHED_KIT_ERROR='The kit archive is incomplete or damaged (the download was cut short?).'
        return 1
    fi
    bad=$(awk -v top="$top" '
        $0 == top || $0 == top "/" { next }
        index($0, top "/") != 1 { print; exit }
        /(^|\/)\.\.(\/|$)/ { print; exit }' "$work/names")
    [ -n "$bad" ] || bad=$(awk '{ t = substr($0, 1, 1); if (t != "-" && t != "d") { print "a link or a device"; exit } }' "$work/listing")
    if [ -n "$bad" ]; then
        rm -f "$work/kit.tar.gz"
        FETCHED_KIT_ERROR="The kit archive holds something that does not belong to the kit ($bad)."
        return 1
    fi
    mkdir "$work/unpacked" || { FETCHED_KIT_ERROR="Could not write to $work."; return 1; }
    if ! tar -xzf "$work/kit.tar.gz" -o -C "$work/unpacked" 2> /dev/null || [ ! -d "$work/unpacked/$top" ]; then
        rm -rf "$work/unpacked" "$work/kit.tar.gz"
        FETCHED_KIT_ERROR='The kit archive could not be unpacked.'
        return 1
    fi
    rm -f "$work/kit.tar.gz" "$work/names" "$work/listing"
    problem=$(test_kit_tree "$work/unpacked/$top" "$manifest")
    if [ -n "$problem" ]; then
        rm -rf "$work/unpacked"
        FETCHED_KIT_ERROR="The kit that was downloaded did not pass its check. $problem"
        return 1
    fi
    rm -f "$work/unpacked/$top/bootstrap.sh" "$work/unpacked/$top/bootstrap.ps1" "$work/unpacked/$top/pairing.json"
    if ! mv "$work/unpacked/$top" "$work/kit" || ! rmdir "$work/unpacked"; then FETCHED_KIT_ERROR="Could not write to $work."; return 1; fi
    return 0
}
