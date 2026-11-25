#!/bin/bash
# Runs every check of the kit on this computer. Nothing here touches a real
# farm, a phone or Cloudflare, and nothing is changed outside temporary
# folders. Run it before every commit to main; docs/RELEASING.md says when
# else.
#
#   bash tools/check.sh [--require-all] [--upstream]
#
#   --require-all   a check whose tool is missing counts as failed instead of
#                   being skipped (use it before a kit release)
#   --upstream      also fetch upstream GADS at the pinned commit and check
#                   that patch/provider-drag.patch applies (needs the network)
#
# What runs, and what it needs:
#   always        the list of files (tools/make-manifest.sh --check); every .sh
#                 parses; the bash tests, also in POSIX mode; the JSON reader
#                 with every awk at hand; the launchd property lists are rendered
#   with shellcheck   every .sh as bash (version 0.11.0 is the one the kit is kept clean with)
#   with node     the Node tests; the pairing and bootstrap tests against the
#                 stand-in for Blossom (also need curl, openssl, tar)
#   with xmllint, python3 or plutil   the rendered property lists
#   with pfctl (macOS)   the packet filter rule, parsed only (asks for sudo)
#   with powershell (Windows PowerShell 5.1) or pwsh   every script parses and is
#                 ASCII; PSScriptAnalyzer 1.24.0 and Pester 5.7.1 when the
#                 modules are installed. On Linux and macOS the Pester tests
#                 of pairing need SSL_CERT_FILE (tests/Pairing.Tests.ps1 says how).
#
# On a Mac this runs with the bash, awk and sed of macOS, which is where the
# shell scripts meet the tools they are written for; on Windows run it from
# Git Bash, or run the PowerShell part by hand (docs/RELEASING.md).
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$KIT" || exit 1
REQUIRE_ALL=0; UPSTREAM=0
while [ $# -gt 0 ]; do
    case $1 in
        --require-all) REQUIRE_ALL=1 ;;
        --upstream) UPSTREAM=1 ;;
        -h | --help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[ "$REQUIRE_ALL" = 1 ] && export FARMKIT_REQUIRE_STAND_IN=1

BASH_BIN=${BASH:-bash}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/farmkit-check.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILED=''; SKIPPED=''; RAN=0
run() {
    # run <name> <command...>
    local name=$1
    shift
    printf '== %s\n' "$name"
    RAN=$((RAN + 1))
    if "$@" > "$TMP/out" 2>&1; then
        tail -n 1 "$TMP/out" | sed 's/^/   /'
    else
        sed 's/^/   /' "$TMP/out"
        FAILED="$FAILED
   $name"
    fi
}
skip() {
    # skip <name> <why>
    printf '== %s\n   SKIPPED: %s\n' "$1" "$2"
    if [ "$REQUIRE_ALL" = 1 ]; then FAILED="$FAILED
   $1 (skipped: $2)"; else SKIPPED="$SKIPPED
   $1: $2"; fi
}
have() { command -v "$1" > /dev/null 2>&1; }

SCRIPTS=$(ls install.sh bootstrap.sh lib/farmkit.sh scripts/*.sh services/*.sh tests/*.sh tools/*.sh)

# shellcheck disable=SC2329  # called through run
parse_all() { local f; for f in $SCRIPTS; do "$BASH_BIN" -n "$f" || return 1; done; echo "every .sh parses with bash $BASH_VERSION"; }
# shellcheck disable=SC2329
manifest() { if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then "$BASH_BIN" tools/make-manifest.sh --check; else "$BASH_BIN" tools/make-manifest.sh --tree "$KIT" --check; fi; }
# shellcheck disable=SC2329
json_reader() {
    local doc want awk_cmd tried=0
    doc='{"a":{"b":[{"id":"xA\"y"},true,null,-1.5e3]}}'
    want=$(printf 'a.b.0.id\txA"y\na.b.1\ttrue\na.b.2\tnull\na.b.3\t-1.5e3\n' | cksum)
    for awk_cmd in awk 'gawk --posix' mawk 'busybox awk' original-awk; do
        have "${awk_cmd%% *}" || continue
        tried=$((tried + 1))
        # shellcheck disable=SC2086
        [ "$(printf '%s' "$doc" | $awk_cmd -f lib/json.awk | cksum)" = "$want" ] || { echo "$awk_cmd reads the document differently"; return 1; }
        # shellcheck disable=SC2086
        if printf '%s' '{"a":1,}' | $awk_cmd -f lib/json.awk > /dev/null 2>&1; then echo "$awk_cmd accepted a document that is not JSON"; return 1; fi
    done
    echo "lib/json.awk agrees with $tried awk program(s)"
}
# shellcheck disable=SC2329
property_lists() {
    local f n=0
    "$BASH_BIN" tests/render-templates.sh "$TMP/rendered" > /dev/null || return 1
    for f in "$TMP"/rendered/*.plist; do
        if have plutil; then plutil -lint "$f" > /dev/null || return 1
        elif have python3; then
            python3 -I -c 'import plistlib, sys, os; d = plistlib.load(open(sys.argv[1], "rb")); assert d["Label"] + ".plist" == os.path.basename(sys.argv[1]); assert d["ProgramArguments"][0] == "/bin/bash"' "$f" || return 1
        fi
        if have xmllint; then xmllint --noout --nonet "$f" || return 1; fi
        n=$((n + 1))
    done
    echo "$n property lists rendered and read"
}
# shellcheck disable=SC2329
patch_applies() {
    local commit
    commit=$(LC_ALL=C awk -f lib/json.awk < versions.json | awk -F '\t' '$1 == "gads.commit" { print $2 }')
    git init -q "$TMP/gads" && git -C "$TMP/gads" fetch -q --depth 1 --no-tags https://github.com/shamanec/GADS.git "$commit" || return 1
    git -C "$TMP/gads" -c advice.detachedHead=false checkout -q FETCH_HEAD || return 1
    git -C "$TMP/gads" apply --check "$KIT/patch/provider-drag.patch" || return 1
    echo "the patch applies to $commit"
}

run 'The list of files is up to date (MANIFEST.sha256, the bootstrap files)' manifest
run 'Every shell script parses' parse_all
if have shellcheck; then
    # shellcheck disable=SC2086
    run "shellcheck ($(shellcheck --version | awk '/^version:/ { print $2 }'))" shellcheck -s bash -x $SCRIPTS
else skip 'shellcheck' 'shellcheck is not installed'; fi
run 'The functions of lib/farmkit.sh and the service scripts' "$BASH_BIN" tests/farmkit.test.sh
run 'The same in POSIX mode' "$BASH_BIN" --posix tests/farmkit.test.sh
run 'The JSON reader with every awk at hand' json_reader
if have node && have curl && have openssl; then
    run 'Pairing, against a stand-in for Blossom (https)' "$BASH_BIN" tests/pairing.test.sh
    run 'The same in POSIX mode' "$BASH_BIN" --posix tests/pairing.test.sh
    run 'The one-command setup and the fetched kit: manifest, bootstrap, update' "$BASH_BIN" tests/bootstrap.test.sh
else
    skip 'Pairing, bootstrap and update against a stand-in server' 'node, curl or openssl is not installed'
    run 'The list of files and the update rules (the part without a server)' "$BASH_BIN" tests/bootstrap.test.sh
fi
if have node; then
    run "The restart service, the provider gate, keep-available, the stand-in ($(node --version))" node --test --test-timeout=60000 tests/restart-server.test.js tests/provider-gate.test.js tests/keep-available.test.js tests/fake-blossom.test.js
else skip 'The Node tests' 'node is not installed'; fi
run 'The launchd property lists' property_lists
if have pfctl && [ "$(uname -s)" = Darwin ]; then
    run 'The packet filter rule is accepted by macOS (parsed only)' sudo pfctl -n -f "$TMP/rendered/pf.rules"
fi

PS=''
if have powershell; then PS=powershell; elif have pwsh; then PS=pwsh; fi
if [ -n "$PS" ]; then
    cat > "$TMP/parse.ps1" << 'PS1'
param([string]$Root)
$failed = 0
Get-ChildItem -Path $Root -Recurse -Include *.ps1, *.psm1, *.psd1 -File | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) { $failed++; Write-Host ($_.FullName + ':' + $e.Extent.StartLineNumber + ' ' + $e.Message) }
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1) { $failed++; Write-Host ($_.FullName + ' contains non-ASCII characters (Windows PowerShell 5.1 would misread them)') }
}
Write-Host ('every PowerShell script parses and is ASCII (PowerShell ' + $PSVersionTable.PSVersion + '); problems: ' + $failed)
exit $failed
PS1
    cat > "$TMP/analyze.ps1" << 'PS1'
param([string]$Root)
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Write-Host 'MODULE-MISSING'; exit 3 }
Import-Module PSScriptAnalyzer
$found = @(Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings (Join-Path $Root 'PSScriptAnalyzerSettings.psd1'))
$found | Sort-Object ScriptName, Line | ForEach-Object { Write-Host ('{0} {1} {2}:{3} {4}' -f $_.Severity, $_.RuleName, $_.ScriptName, $_.Line, $_.Message) }
Write-Host ('PSScriptAnalyzer ' + (Get-Module PSScriptAnalyzer).Version + ': ' + $found.Count + ' finding(s)')
if ($found | Where-Object { $_.Severity -eq 'Error' -or $_.Severity -eq 'ParseError' }) { exit 1 }
exit 0
PS1
    cat > "$TMP/pester.ps1" << 'PS1'
param([string]$Root)
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 })) { Write-Host 'MODULE-MISSING'; exit 3 }
Import-Module Pester -MinimumVersion 5.0.0
$config = New-PesterConfiguration
$config.Run.Path = (Join-Path $Root 'tests')
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$r = Invoke-Pester -Configuration $config
Write-Host ('Pester ' + (Get-Module Pester).Version + ': passed ' + $r.PassedCount + ', failed ' + $r.FailedCount + ', skipped ' + $r.SkippedCount)
if ($r.FailedCount -gt 0 -or $r.Result -ne 'Passed') { exit 1 }
exit 0
PS1
    run "Every PowerShell script parses and is ASCII ($PS)" "$PS" -NoProfile -ExecutionPolicy Bypass -File "$TMP/parse.ps1" -Root "$KIT"
    for part in analyze pester; do
        name='PSScriptAnalyzer'; [ "$part" = pester ] && name='The Pester tests'
        "$PS" -NoProfile -ExecutionPolicy Bypass -File "$TMP/$part.ps1" -Root "$KIT" > "$TMP/ps.out" 2>&1; code=$?
        if [ "$code" = 3 ] && grep -q 'MODULE-MISSING' "$TMP/ps.out"; then
            skip "$name" "the module is not installed for $PS (Install-Module Pester -RequiredVersion 5.7.1; Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0)"
        else
            # shellcheck disable=SC2329
            show() { cat "$TMP/ps.out"; return "$code"; }
            run "$name ($PS)" show
        fi
    done
else
    skip 'The PowerShell scripts (parse, PSScriptAnalyzer, Pester)' 'neither powershell nor pwsh is installed; run them on Windows before a kit release'
fi

if [ "$UPSTREAM" = 1 ]; then run 'The patch applies to the pinned upstream commit' patch_applies; fi

echo
if [ -n "$SKIPPED" ]; then printf 'Skipped:%s\n' "$SKIPPED"; fi
if [ -n "$FAILED" ]; then
    printf 'FAILED:%s\n' "$FAILED"
    exit 1
fi
echo "All $RAN checks that ran passed."
