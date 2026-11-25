# Blossom farm kit - a JSON reader for the macOS scripts.
#
# macOS ships no JSON tool that can be relied on in every supported version,
# and the kit must read its own files before it has installed anything. This
# reads one JSON document from standard input and prints one line per value:
#
#     path<TAB>value
#
# The path joins object keys and array positions with dots:
#     {"result":{"workspaces":[{"id":"abc"}]}}  ->  result.workspaces.0.id<TAB>abc
#
# Strings are printed without their quotes and with escapes resolved; line
# breaks and tabs inside a string become a space, so that a value is always
# one line. Numbers, true, false and null are printed as written. Empty
# objects and arrays print nothing. Exit status 2: the input is not JSON.
#
# Plain POSIX awk (the awk of macOS; also mawk, gawk, busybox): no gawk
# extensions, no interval expressions.

{ s = s $0 "\n" }

END {
    bad = 0
    skip()
    if (s == "") exit 2
    value("")
    skip()
    if (bad || s != "") exit 2
}

function skip() { sub(/^[ \t\r\n]+/, "", s) }

function fail() { bad = 1; s = "" }

function hexval(h,    i, n, d) {
    n = 0
    h = tolower(h)
    for (i = 1; i <= length(h); i++) {
        d = index("0123456789abcdef", substr(h, i, 1))
        if (d == 0) return -1
        n = n * 16 + d - 1
    }
    return n
}

# s starts with a double quote; returns the string and consumes it.
function string(    out, c, e, n) {
    s = substr(s, 2)
    out = ""
    while (1) {
        if (match(s, /^[^"\\]+/)) {
            out = out substr(s, 1, RLENGTH)
            s = substr(s, RLENGTH + 1)
        }
        c = substr(s, 1, 1)
        if (c == "\"") { s = substr(s, 2); break }
        if (c != "\\") { fail(); break }
        e = substr(s, 2, 1)
        if (e == "u") {
            n = hexval(substr(s, 3, 4))
            if (n < 0 || length(substr(s, 3, 4)) != 4) { fail(); break }
            if (n >= 32 && n < 127) out = out sprintf("%c", n)
            else if (n < 32) out = out " "
            else out = out substr(s, 1, 6)
            s = substr(s, 7)
            continue
        }
        if (e == "n" || e == "r" || e == "t" || e == "b" || e == "f") out = out " "
        else if (e == "\"" || e == "\\" || e == "/") out = out e
        else { fail(); break }
        s = substr(s, 3)
    }
    gsub(/[\t\r\n]/, " ", out)
    return out
}

function value(path,    c, key, n) {
    if (bad) return
    skip()
    c = substr(s, 1, 1)
    if (c == "{") {
        s = substr(s, 2)
        skip()
        if (substr(s, 1, 1) == "}") { s = substr(s, 2); return }
        while (!bad) {
            skip()
            if (substr(s, 1, 1) != "\"") { fail(); return }
            key = string()
            skip()
            if (substr(s, 1, 1) != ":") { fail(); return }
            s = substr(s, 2)
            value(path == "" ? key : path "." key)
            skip()
            c = substr(s, 1, 1)
            s = substr(s, 2)
            if (c == "}") return
            if (c != ",") { fail(); return }
        }
        return
    }
    if (c == "[") {
        s = substr(s, 2)
        skip()
        if (substr(s, 1, 1) == "]") { s = substr(s, 2); return }
        n = 0
        while (!bad) {
            value(path == "" ? n : path "." n)
            n++
            skip()
            c = substr(s, 1, 1)
            s = substr(s, 2)
            if (c == "]") return
            if (c != ",") { fail(); return }
        }
        return
    }
    if (c == "\"") {
        key = string()
        if (!bad) print path "\t" key
        return
    }
    if (match(s, /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?/) || match(s, /^(true|false|null)/)) {
        print path "\t" substr(s, 1, RLENGTH)
        s = substr(s, RLENGTH + 1)
        return
    }
    fail()
}
