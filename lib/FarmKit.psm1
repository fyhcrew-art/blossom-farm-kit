# Blossom farm kit - shared functions.
#
# Works on Windows PowerShell 5.1 (the PowerShell every Windows 10/11 has).
# ASCII only on purpose: Windows PowerShell 5.1 reads a script without a BOM
# in the system code page.
#
# The functions in the first half are pure (no system access) and are covered
# by tests\FarmKit.Tests.ps1.

# ---------------------------------------------------------------------------
# Errors: every failure says what went wrong and what to do about it.
# ---------------------------------------------------------------------------

function Stop-Farm {
    # Stops the running script with a message and a "what to do".
    param(
        [Parameter(Mandatory = $true)][string]$Problem,
        [Parameter(Mandatory = $true)][string]$WhatToDo
    )
    $ex = New-Object System.InvalidOperationException($Problem)
    $ex.Data['WhatToDo'] = $WhatToDo
    throw $ex
}

function Write-FarmFailure {
    # Prints an error caught at the top of a script. Never prints secrets:
    # callers must not put any into exception messages.
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    $ex = $ErrorRecord.Exception
    Write-Host ''
    Write-Host ('PROBLEM:    ' + $ex.Message) -ForegroundColor Red
    $what = $null
    if ($ex.Data -and $ex.Data.Contains('WhatToDo')) { $what = [string]$ex.Data['WhatToDo'] }
    if (-not $what) {
        $what = 'This error was not expected. Run the script again; it is safe to re-run. If it stops at the same place, copy the PROBLEM line and open an issue on the kit repository. If a log helps, add the output of scripts\status.ps1 -Logs (it masks session tokens and host names); never post a file from C:\farm\logs itself, and remove passwords first.'
    }
    Write-Host ('WHAT TO DO: ' + $what) -ForegroundColor Yellow
    Write-Host ''
}

function Write-Step { param([string]$Text) Write-Host ''; Write-Host ('== ' + $Text + ' ==') -ForegroundColor Cyan }
function Write-Ok { param([string]$Text) Write-Host ('   [ok]   ' + $Text) -ForegroundColor Green }
function Write-Note { param([string]$Text) Write-Host ('   ' + $Text) }
function Write-Warn { param([string]$Text) Write-Host ('   [warn] ' + $Text) -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------

function New-RandomSecret {
    # A secret from the operating system's cryptographic random generator.
    # Hex: 2 characters per byte. Base64Url: about 1.33 characters per byte.
    param(
        [ValidateRange(16, 128)][int]$Bytes = 32,
        [ValidateSet('Hex', 'Base64Url')][string]$Format = 'Hex'
    )
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    if ($Format -eq 'Hex') {
        return (-join ($buffer | ForEach-Object { $_.ToString('x2') }))
    }
    return [Convert]::ToBase64String($buffer).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-PasswordStrength {
    # Returns a list of problems; an empty list means the password is accepted.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [string[]]$Forbidden = @()
    )
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Password.Length -lt 14) { $problems.Add('It must be at least 14 characters long.') }
    if ($Password.Length -gt 128) { $problems.Add('It must be at most 128 characters long.') }
    $classes = 0
    if ($Password -cmatch '[a-z]') { $classes++ }
    if ($Password -cmatch '[A-Z]') { $classes++ }
    if ($Password -match '[0-9]') { $classes++ }
    if ($Password -match '[^a-zA-Z0-9]') { $classes++ }
    if ($classes -lt 3) { $problems.Add('It must mix at least three of: lower-case letters, upper-case letters, digits, other characters.') }
    if ($Password -match '^\s|\s$') { $problems.Add('It must not start or end with a space.') }
    if ($Password -match '[\x00-\x1f]') { $problems.Add('It must not contain control characters.') }
    $lower = $Password.ToLowerInvariant()
    $words = @('password', 'admin', 'gads', 'blossom', 'qwerty', '123456', 'letmein', 'welcome') + $Forbidden
    foreach ($w in $words) {
        if ($w -and $w.Length -ge 4 -and $lower.Contains($w.ToLowerInvariant())) {
            $problems.Add('It must not contain "' + $w + '".')
        }
    }
    if ($Password.Length -gt 0) {
        $distinct = ($Password.ToCharArray() | Sort-Object -Unique | Measure-Object).Count
        if ($distinct -lt 8) { $problems.Add('It repeats too few different characters (at least 8 different ones).') }
    }
    return , $problems.ToArray()
}

function Test-FarmHostname {
    # Returns $null when the name can be used as a public tunnel host name,
    # otherwise the reason it cannot.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)
    $n = $Name.Trim()
    if (-not $n) { return 'The host name is empty.' }
    if ($n -match '://') { return 'Enter the host name only, without https:// in front.' }
    if ($n -match '[/\\?#@:\s]') { return 'Enter the host name only: no path, port, spaces or other characters.' }
    if ($n -cne $n.ToLowerInvariant()) { return 'Use lower-case letters only.' }
    if ($n.Length -gt 253) { return 'The host name is too long.' }
    if ($n -match '^\d{1,3}(\.\d{1,3}){3}$') { return 'An IP address cannot be used; a host name under your own domain is needed.' }
    $labels = $n.Split('.')
    if ($labels.Count -lt 3) { return 'Use a sub-domain of your domain, for example farm-hub.example.com (not the bare domain).' }
    foreach ($l in $labels) {
        if ($l.Length -lt 1 -or $l.Length -gt 63) { return 'Every part between the dots must be 1 to 63 characters long.' }
        if ($l -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') { return 'Only letters a-z, digits and hyphens are allowed, and no part may start or end with a hyphen.' }
    }
    if ($labels[$labels.Count - 1] -match '^\d+$') { return 'The last part of the host name cannot be a number.' }
    $internal = @('local', 'localhost', 'internal', 'lan', 'home', 'corp', 'intranet', 'test', 'invalid', 'example')
    if ($internal -contains $labels[$labels.Count - 1]) { return 'This name only works inside a private network. Use a name under a real domain that you own.' }
    if ($n -match '(^|\.)example\.(com|net|org)$') { return 'example.com is a placeholder. Use a name under a domain that you own.' }
    if ($n -match '\.cfargotunnel\.com$|\.trycloudflare\.com$') { return 'Use a name under your own domain, not a Cloudflare-internal name.' }
    return $null
}

function Test-FarmHostnameSet {
    # Checks the three names together. Returns a list of problems.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Hub,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Provider,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Restart
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $pairs = @(@('Hub', $Hub), @('Provider', $Provider), @('Restart service', $Restart))
    foreach ($p in $pairs) {
        $reason = Test-FarmHostname -Name $p[1]
        if ($reason) { $problems.Add($p[0] + ' host name: ' + $reason) }
    }
    $names = @($Hub.Trim(), $Provider.Trim(), $Restart.Trim())
    if (($names | Sort-Object -Unique | Measure-Object).Count -ne 3) {
        $problems.Add('The three host names must be different from each other.')
    }
    return , $problems.ToArray()
}

function Test-ProviderNickname {
    # Returns $null when usable, otherwise the reason.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Nickname)
    if ($Nickname -notmatch '^[A-Za-z][A-Za-z0-9_-]{1,31}$') {
        return 'Use 2 to 32 characters: letters, digits, "-" and "_", starting with a letter (for example Provider1). It becomes a folder name and part of an address.'
    }
    return $null
}

function Test-PublicIpAddress {
    # True when the address is a public internet address (the product refuses
    # private, loopback, link-local, CGNAT, multicast and reserved ranges).
    param([Parameter(Mandatory = $true)][string]$Address)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($ip.IsIPv4MappedToIPv6) { return (Test-PublicIpAddress -Address $ip.MapToIPv4().ToString()) }
        $b = $ip.GetAddressBytes()
        if ($ip.Equals([System.Net.IPAddress]::IPv6Loopback) -or $ip.Equals([System.Net.IPAddress]::IPv6None)) { return $false }
        if (($b[0] -band 0xfe) -eq 0xfc) { return $false }                      # fc00::/7 unique local
        if ($b[0] -eq 0xfe -and ($b[1] -band 0xc0) -eq 0x80) { return $false }  # fe80::/10 link-local
        if ($b[0] -eq 0xff) { return $false }                                   # multicast
        if ($b[0] -eq 0x20 -and $b[1] -eq 0x01 -and $b[2] -eq 0x0d -and $b[3] -eq 0xb8) { return $false } # documentation
        return $true
    }
    $o = $ip.GetAddressBytes()
    if ($o[0] -eq 0 -or $o[0] -eq 10 -or $o[0] -eq 127) { return $false }
    if ($o[0] -eq 100 -and $o[1] -ge 64 -and $o[1] -le 127) { return $false }   # CGNAT
    if ($o[0] -eq 169 -and $o[1] -eq 254) { return $false }                     # link-local
    if ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) { return $false }
    if ($o[0] -eq 192 -and $o[1] -eq 168) { return $false }
    if ($o[0] -eq 192 -and $o[1] -eq 0 -and $o[2] -eq 0) { return $false }
    if ($o[0] -eq 192 -and $o[1] -eq 0 -and $o[2] -eq 2) { return $false }      # documentation
    if ($o[0] -eq 198 -and ($o[1] -eq 18 -or $o[1] -eq 19)) { return $false }   # benchmarking
    if ($o[0] -eq 198 -and $o[1] -eq 51 -and $o[2] -eq 100) { return $false }
    if ($o[0] -eq 203 -and $o[1] -eq 0 -and $o[2] -eq 113) { return $false }
    if ($o[0] -ge 224) { return $false }                                        # multicast and reserved
    return $true
}

function Get-CloudflaredConfigText {
    # The tunnel configuration file. Every service is an address on this
    # computer; the last rule is the catch-all Cloudflare requires.
    param(
        [Parameter(Mandatory = $true)][string]$TunnelId,
        [Parameter(Mandatory = $true)][string]$CredentialsFile,
        [Parameter(Mandatory = $true)][string]$HubHost,
        [Parameter(Mandatory = $true)][string]$ProviderHost,
        [Parameter(Mandatory = $true)][string]$RestartHost,
        [int]$HubPort = 10000,
        [int]$GatePort = 10002,
        [int]$RestartPort = 19999
    )
    if ($TunnelId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        throw 'The tunnel id is not a UUID.'
    }
    foreach ($h in @($HubHost, $ProviderHost, $RestartHost)) {
        $reason = Test-FarmHostname -Name $h
        if ($reason) { throw ('Host name "' + $h + '" cannot be used: ' + $reason) }
    }
    # Single-quoted YAML: a backslash is literal, a quote is doubled.
    $cred = "'" + $CredentialsFile.Replace("'", "''") + "'"
    $lines = @(
        '# Written by the Blossom farm kit (install.ps1). Re-running install.ps1 rewrites this file.',
        ('tunnel: ' + $TunnelId.ToLowerInvariant()),
        ('credentials-file: ' + $cred),
        '',
        'ingress:',
        '  # GADS 6.0.0 does not check the login on hub paths that contain "appium".',
        '  # Blossom never calls such a path, so they are refused here, before the hub.',
        ('  - hostname: ' + $HubHost),
        "    path: '(?i)appium'",
        '    service: http_status:403',
        '  # The provider reports to the hub on this path, locally. Never from outside.',
        ('  - hostname: ' + $HubHost),
        "    path: '^/provider-update'",
        '    service: http_status:403',
        '  # GADS 6.0.0 serves the provider record (an endless stream) on this path',
        '  # without a login. Blossom never calls it; the hub page shows it locally.',
        ('  - hostname: ' + $HubHost),
        "    path: '^/admin/provider/[^/]+/info'",
        '    service: http_status:403',
        '  # GADS hub (has its own login)',
        ('  - hostname: ' + $HubHost),
        ('    service: http://127.0.0.1:' + $HubPort),
        '  # GADS provider, through the provider gate (the provider itself has no login)',
        ('  - hostname: ' + $ProviderHost),
        ('    service: http://127.0.0.1:' + $GatePort),
        '  # restart service (protected by the restart secret)',
        ('  - hostname: ' + $RestartHost),
        ('    service: http://127.0.0.1:' + $RestartPort),
        '  # everything else',
        '  - service: http_status:404',
        ''
    )
    return ($lines -join "`n")
}

function Get-TunnelIdFromText {
    # Finds the first UUID in a line of text ($null when there is none).
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $m = [regex]::Match($Text, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value.ToLowerInvariant() }
    return $null
}

function Test-Sha256Text {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return ($Text -match '^[0-9a-fA-F]{64}$')
}

function ConvertTo-NssmArgument {
    # Quotes one value for a Windows command line when it contains a space.
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '"') { throw 'A double quote cannot be used in this value.' }
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

function Hide-LogSecret {
    # Masks what must not leave the computer when a log line is shown or
    # posted: a session token in an address (?token=...), a bearer header,
    # anything shaped like a signed token (JWT), and the given names (the
    # farm's public host names). GADS writes every request address to its
    # log, and the hub accepts its session token in the address.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string[]]$Names = @()
    )
    $t = [regex]::Replace($Text, '(?i)([?&;](?:token|access_token|id_token|secret|password)=)[^&\s"''<>]+', '$1<hidden>')
    $t = [regex]::Replace($t, '(?i)\b(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}', '$1<hidden>')
    $t = [regex]::Replace($t, 'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*', '<hidden-token>')
    foreach ($n in $Names) {
        if ($n -and $n.Length -ge 4) { $t = [regex]::Replace($t, [regex]::Escape($n), '<host-name>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
    }
    return $t
}

function ConvertTo-WingetVersion {
    # 'v1.9.25200' or 'v1.4.3531-preview' -> [version] 1.9 / 1.4; $null when
    # the text holds no version.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $m = [regex]::Match([string]$Text, '(\d+)\.(\d+)')
    if (-not $m.Success) { return $null }
    return New-Object System.Version([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
}

function Protect-NativeArgument {
    # Windows PowerShell 5.1 wraps an argument that contains a space in double
    # quotes but does not double a backslash at its end, so the program reads
    # \" as a literal quote and swallows the arguments that follow. PowerShell
    # 6 and later double it themselves.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [int]$PSMajor = $PSVersionTable.PSVersion.Major
    )
    if ($PSMajor -ge 6) { return $Value }
    $m = [regex]::Match($Value, '\\+$')
    if ($m.Success -and $Value -match '\s') { return $Value + $m.Value }
    return $Value
}

function ConvertTo-PathList {
    # A PATH value without empty entries and without a backslash at the end of
    # an entry ("C:\Program Files\nodejs\" means the same folder without it).
    param([AllowEmptyString()][AllowNull()][string]$Path)
    $parts = @(([string]$Path).Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
            if ($_ -match '^[A-Za-z]:\\+$') { $_.Substring(0, 3) } else { $_.TrimEnd('\') }
        } | Where-Object { $_ })
    return ($parts -join ';')
}

function Test-ServiceConfigSame {
    # Compares two descriptions of a service: hashtables whose values are a
    # string or a list of strings. Empty entries do not count.
    param([Parameter(Mandatory = $true)][hashtable]$Current, [Parameter(Mandatory = $true)][hashtable]$Wanted)
    foreach ($k in $Wanted.Keys) {
        $a = @(@($Current[$k]) | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { [string]$_ })
        $b = @(@($Wanted[$k]) | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { [string]$_ })
        if ($a.Count -ne $b.Count) { return $false }
        for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -cne $b[$i]) { return $false } }
    }
    return $true
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })) }
    finally { $sha.Dispose() }
}

function Test-FarmRootTrust {
    # Decides what to do with a farm folder that ALREADY EXISTS before the kit
    # touches it. On Windows any signed-in user may create a folder in C:\, and
    # whoever creates a folder owns it and can always change who may write to
    # it. The services in this folder run as SYSTEM and its files are secrets,
    # so a folder somebody else prepared must not be adopted.
    # Returns Action = 'use', 'recreate' (empty: delete it and make a new one)
    # or 'refuse', with the Reason for a refusal.
    param(
        [Parameter(Mandatory = $true)][bool]$IsFolder,
        [Parameter(Mandatory = $true)][bool]$IsLink,
        [Parameter(Mandatory = $true)][bool]$IsEmpty,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$OwnerSid,
        [string[]]$AllowSids = @()
    )
    # Administrators, SYSTEM, TrustedInstaller
    $trusted = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $verdict = New-Object PSObject -Property @{ Action = 'use'; Reason = $null }
    if (-not $IsFolder) { $verdict.Action = 'refuse'; $verdict.Reason = 'It is a file, not a folder.'; return $verdict }
    if ($IsLink) { $verdict.Action = 'refuse'; $verdict.Reason = 'It is a link to another place, not a folder of its own.'; return $verdict }
    if ($IsEmpty) { $verdict.Action = 'recreate'; return $verdict }
    if ($trusted -notcontains $OwnerSid) {
        $verdict.Action = 'refuse'; $verdict.Reason = 'It was not created by this kit: its owner is not the Administrators group, so whoever made it can still change what is inside.'
        return $verdict
    }
    $others = @($AllowSids | Where-Object { $_ -and ($trusted -notcontains $_) } | Sort-Object -Unique)
    if ($others.Count -gt 0) {
        $verdict.Action = 'refuse'; $verdict.Reason = 'It was not locked by this kit: accounts other than Administrators and SYSTEM have access to it, so what is inside cannot be trusted.'
    }
    return $verdict
}

# ---------------------------------------------------------------------------
# System helpers
# ---------------------------------------------------------------------------

function Invoke-Native {
    # Runs a program and returns its exit code and its output as text lines.
    # ErrorActionPreference is lowered locally: in Windows PowerShell 5.1 a
    # program that writes to stderr would otherwise stop a script that runs
    # with ErrorActionPreference = Stop.
    param([Parameter(Mandatory = $true)][string]$File, [string[]]$Arguments = @())
    $ErrorActionPreference = 'Continue'
    $lines = @(& $File @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return New-Object PSObject -Property @{ Code = $LASTEXITCODE; Output = $lines }
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) {
        Stop-Farm -Problem 'This script must run as Administrator.' -WhatToDo 'Close this window. Press Start, type "powershell", right-click "Windows PowerShell", choose "Run as administrator", and run the same command again.'
    }
}

function Enable-Tls12 {
    # Windows PowerShell 5.1 may still default to TLS 1.0 for downloads.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}

function Update-SessionPath {
    # Picks up PATH changes made by installers without reopening the window.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Write-TextFileUtf8 {
    # UTF-8 without BOM (Out-File in Windows PowerShell 5.1 writes UTF-16).
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Protect-FarmPath {
    # Leaves only Administrators and SYSTEM on the path (well-known SIDs, so it
    # works on every Windows language). Inherited permissions are removed, and
    # the Administrators group becomes the owner: an owner can always change
    # the permissions, so it must not stay with whoever created the path.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: ' + $Path) }
    $isDir = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    $r = Invoke-Native -File 'icacls.exe' -Arguments @($Path, '/setowner', '*S-1-5-32-544')
    if ($r.Code -ne 0) {
        Stop-Farm -Problem ('Could not make Administrators the owner of ' + $Path + ' (icacls exit code ' + $r.Code + ').') -WhatToDo 'Check that the drive is NTFS (file permissions do not exist on FAT/exFAT) and that you run as Administrator, then run the script again.'
    }
    if ($isDir) {
        $grants = @('*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
    } else {
        $grants = @('*S-1-5-32-544:F', '*S-1-5-18:F')
    }
    $r = Invoke-Native -File 'icacls.exe' -Arguments @($Path, '/inheritance:r', '/grant:r', $grants[0], '/grant:r', $grants[1])
    if ($r.Code -ne 0) {
        Stop-Farm -Problem ('Could not restrict access to ' + $Path + ' (icacls exit code ' + $r.Code + ').') -WhatToDo 'Check that the drive is NTFS (file permissions do not exist on FAT/exFAT) and that you run as Administrator, then run the script again.'
    }
    # Remove well-known broad groups in case they were granted explicitly:
    # Users, Authenticated Users, Everyone.
    foreach ($sid in @('*S-1-5-32-545', '*S-1-5-11', '*S-1-1-0')) {
        $null = Invoke-Native -File 'icacls.exe' -Arguments @($Path, '/remove:g', $sid)
    }
}

function Get-FarmRootVerdict {
    # Looks at a farm folder that exists and says whether it can be used
    # (Test-FarmRootTrust holds the rules).
    param([Parameter(Mandatory = $true)][string]$Root)
    $item = Get-Item -LiteralPath $Root -Force
    $isFolder = [bool]$item.PSIsContainer
    $isLink = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    $isEmpty = $false
    if ($isFolder -and -not $isLink) { $isEmpty = (@(Get-ChildItem -LiteralPath $Root -Force | Select-Object -First 1).Count -eq 0) }
    $owner = ''
    $allow = @()
    try {
        $acl = Get-Acl -LiteralPath $Root
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        $allow = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
                Where-Object { [string]$_.AccessControlType -eq 'Allow' } | ForEach-Object { $_.IdentityReference.Value })
    } catch { $owner = '' }
    return (Test-FarmRootTrust -IsFolder $isFolder -IsLink $isLink -IsEmpty $isEmpty -OwnerSid $owner -AllowSids $allow)
}

function Stop-FarmRootUntrusted {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Reason)
    Stop-Farm -Problem ($Root + ' already exists and cannot be used. ' + $Reason) -WhatToDo ('Nothing was changed. If you know the folder (an earlier farm set up by hand), rename it:   Rename-Item ' + $Root + ' ' + $Root + '-old   and run the script again. If you do not know where it comes from, do the same and have the computer checked: the kit keeps secrets and programs that run with full rights in this folder. To move a kit-installed farm from another computer use scripts\export-farm.ps1 and scripts\import-farm.ps1.')
}

function Initialize-FarmRoot {
    # Creates the farm folder, or takes over an existing one only when that is
    # safe, and locks it to Administrators and SYSTEM. Called before anything
    # in the folder is read or run.
    param([Parameter(Mandatory = $true)][string]$Root)
    $created = $false
    if (Test-Path -LiteralPath $Root) {
        $verdict = Get-FarmRootVerdict -Root $Root
        if ($verdict.Action -eq 'refuse') { Stop-FarmRootUntrusted -Root $Root -Reason $verdict.Reason }
        if ($verdict.Action -eq 'recreate') {
            # An empty folder of unknown origin: a new one replaces it, so that
            # nobody keeps a hold on it.
            Remove-Item -LiteralPath $Root -Force
        }
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $created = $true
    }
    Protect-FarmPath -Path $Root
    if ($created -and @(Get-ChildItem -LiteralPath $Root -Force | Select-Object -First 1).Count -gt 0) {
        Stop-FarmRootUntrusted -Root $Root -Reason 'Something was put into it while it was being created.'
    }
}

function Write-SecretFile {
    # Creates the file empty, restricts it, then writes the secret into it.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    if (-not (Test-Path -LiteralPath $Path)) { Write-TextFileUtf8 -Path $Path -Text '' }
    Protect-FarmPath -Path $Path
    Write-TextFileUtf8 -Path $Path -Text $Text
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Secure)
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-FarmPassword {
    # Asks twice, hidden, and repeats until the password passes the rules.
    # Nothing typed here is echoed or stored in the console history.
    param([Parameter(Mandatory = $true)][string]$Prompt, [string[]]$Forbidden = @())
    while ($true) {
        $first = ConvertFrom-SecureStringPlain -Secure (Read-Host -Prompt $Prompt -AsSecureString)
        $problems = Test-PasswordStrength -Password $first -Forbidden $Forbidden
        if ($problems.Count -gt 0) {
            Write-Warn 'That password is not strong enough:'
            foreach ($p in $problems) { Write-Note ('  - ' + $p) }
            continue
        }
        $second = ConvertFrom-SecureStringPlain -Secure (Read-Host -Prompt 'Type it again' -AsSecureString)
        if ($first -cne $second) { Write-Warn 'The two entries differ. Try again.'; continue }
        return $first
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-VerifiedDownload {
    # Downloads to a temporary name, checks the SHA-256, and only then moves
    # the file into place. A file that is already there with the right hash is
    # kept. Nothing with a wrong hash is ever left at $OutFile.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$What
    )
    if (-not (Test-Sha256Text -Text $Sha256)) {
        Stop-Farm -Problem ('No valid pinned SHA-256 for ' + $What + ' in versions.json.') -WhatToDo 'Download the kit again from its releases page; versions.json must not be edited by hand.'
    }
    if ($Url -notmatch '^https://') {
        Stop-Farm -Problem ('The download address for ' + $What + ' is not https.') -WhatToDo 'Download the kit again from its releases page.'
    }
    $want = $Sha256.ToLowerInvariant()
    if ((Test-Path -LiteralPath $OutFile) -and ((Get-FileSha256 -Path $OutFile) -eq $want)) { return }
    Enable-Tls12
    $tmp = $OutFile + '.download'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 downloads very slow
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 900
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $status = 0
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { $status = 0 }
        if ($status -eq 404) {
            Stop-Farm -Problem ($What + ' is not at its download address (HTTP 404): ' + $Url) -WhatToDo 'The file was not published yet, or it was withdrawn. Check the kit''s releases page for a newer kit and use that. If there is none, report it on the kit repository. This is not a fault of your computer or your connection.'
        }
        Stop-Farm -Problem ('Downloading ' + $What + ' failed: ' + $_.Exception.Message) -WhatToDo ('Check the internet connection of this computer and run the script again. Address: ' + $Url)
    } finally {
        $ProgressPreference = $oldProgress
    }
    $got = Get-FileSha256 -Path $tmp
    if ($got -ne $want) {
        Remove-Item -LiteralPath $tmp -Force
        Stop-Farm -Problem ($What + ' was downloaded but its SHA-256 is wrong (expected ' + $want + ', got ' + $got + '). The file was deleted.') -WhatToDo 'Do not continue with this file. Run the script again; if the hash is wrong again, the download is being altered on the way or the published file changed: report it on the kit repository.'
    }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

function Invoke-FarmHttp {
    # One HTTP call that never throws for an HTTP status and never follows a
    # redirect. Returns Status (0 = no HTTP answer), Text, Json, Error.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [string]$Body = $null,
        [int]$TimeoutSec = 15,
        # Send what Blossom's servers send: no User-Agent and no Accept header.
        # Cloudflare treats a request without a User-Agent differently
        # (Browser Integrity Check), so the self-test must look the same.
        [switch]$LikeBlossom
    )
    Enable-Tls12
    $result = New-Object PSObject -Property @{ Status = 0; Text = ''; Json = $null; Error = $null; Challenge = $false }
    $response = $null
    try {
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
        $req.Method = $Method
        $req.AllowAutoRedirect = $false
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        if ($LikeBlossom) {
            $req.Headers['Accept-Encoding'] = 'identity'
        } else {
            $req.UserAgent = 'blossom-farm-kit'
            $req.Accept = 'application/json'
        }
        foreach ($k in $Headers.Keys) { $req.Headers[$k] = [string]$Headers[$k] }
        if ($Body -ne $null -and $Body -ne '') {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $req.ContentType = 'application/json'
            $req.ContentLength = $bytes.Length
            $stream = $req.GetRequestStream()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
        } elseif ($Method -ne 'GET' -and $Method -ne 'HEAD') {
            $req.ContentLength = 0
        }
        try {
            $response = $req.GetResponse()
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $response = $_.Exception.Response } else { throw }
        }
        $result.Status = [int]$response.StatusCode
        # Cloudflare marks an answer that is its own challenge or block page.
        if ($response.Headers['cf-mitigated']) { $result.Challenge = $true }
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try {
            $buffer = New-Object char[] 1048576
            $read = $reader.ReadBlock($buffer, 0, $buffer.Length)   # at most 1 MB of text
            $result.Text = New-Object string($buffer, 0, $read)
        } finally { $reader.Close() }
        if ($result.Status -eq 403 -and $result.Text -match '(?i)<html|<!doctype' -and $result.Text -match '(?i)cloudflare') { $result.Challenge = $true }
        $trimmed = $result.Text.TrimStart()
        if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
            try { $result.Json = $result.Text | ConvertFrom-Json } catch { $result.Json = $null }
        }
    } catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $result.Error = $inner.Message
    } finally {
        if ($response) { $response.Close() }
    }
    return $result
}

function Get-JsonProperty {
    # Reads a property that may not exist, without an error.
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Test-LooksDown {
    # The product's rule: a 5xx status or an HTML page means "the tunnel
    # answers, but not the program behind it".
    param([int]$Status, [string]$Text)
    return ($Status -ge 500 -or $Text -match '(?i)<!doctype|<html')
}

function Get-FarmPaths {
    param([string]$Root = 'C:\farm')
    $config = Join-Path $Root 'config'
    return New-Object PSObject -Property @{
        Root            = $Root
        Bin             = Join-Path $Root 'bin'
        Config          = $config
        Logs            = Join-Path $Root 'logs'
        Services        = Join-Path $Root 'services'
        Downloads       = Join-Path $Root 'downloads'
        FarmJson        = Join-Path $config 'farm.json'
        RestartSecret   = Join-Path $config 'restart-secret.txt'
        KeepAvailable   = Join-Path $config 'keep-available.json'
        Cloudflared     = Join-Path $config 'cloudflared'
        CloudflaredYml  = Join-Path (Join-Path $config 'cloudflared') 'config.yml'
        HubExe          = Join-Path (Join-Path $Root 'bin') 'GADS.exe'
        ProviderExe     = Join-Path (Join-Path $Root 'bin') 'GADS-drag.exe'
        Nssm            = Join-Path (Join-Path $Root 'bin') 'nssm.exe'
    }
}

function Read-FarmConfig {
    # The non-secret record of this installation ($null when not installed).
    # Nothing is read from a farm folder that somebody else prepared.
    param([Parameter(Mandatory = $true)]$Paths)
    if (Test-Path -LiteralPath $Paths.Root) {
        $verdict = Get-FarmRootVerdict -Root $Paths.Root
        if ($verdict.Action -eq 'refuse') { Stop-FarmRootUntrusted -Root $Paths.Root -Reason $verdict.Reason }
    }
    if (-not (Test-Path -LiteralPath $Paths.FarmJson)) { return $null }
    try { return (Get-Content -LiteralPath $Paths.FarmJson -Raw | ConvertFrom-Json) }
    catch { Stop-Farm -Problem ($Paths.FarmJson + ' cannot be read as JSON.') -WhatToDo 'Run install.ps1 again; it rewrites the file.' }
}

function Read-KitVersions {
    param([Parameter(Mandatory = $true)][string]$KitRoot)
    $file = Join-Path $KitRoot 'versions.json'
    if (-not (Test-Path -LiteralPath $file)) {
        Stop-Farm -Problem 'versions.json is missing from the kit folder.' -WhatToDo 'Download the complete kit again (the whole folder, not single files) and run the script from inside it.'
    }
    return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
}

function Get-ToolPath {
    # Full path of a program on PATH, or $null.
    param([Parameter(Mandatory = $true)][string]$Name)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-FarmTool {
    # Full path of a program: on PATH (after re-reading PATH from the
    # registry), or in the folder its installer normally uses. Some installers
    # (MongoDB) do not put their program on PATH at all.
    param([Parameter(Mandatory = $true)][string]$Command)
    Update-SessionPath
    $found = Get-ToolPath -Name $Command
    if ($found) { return $found }
    $guesses = @()
    $pf = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    if ($Command -eq 'mongod' -or $Command -eq 'mongodump' -or $Command -eq 'mongorestore') {
        foreach ($base in @((Join-Path $pf 'MongoDB\Server'), (Join-Path $pf 'MongoDB\Tools'))) {
            if (Test-Path -LiteralPath $base) {
                $guesses += @(Get-ChildItem -LiteralPath $base -Filter ($Command + '.exe') -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object { $_.FullName })
            }
        }
    }
    if ($Command -eq 'cloudflared') { $guesses += @((Join-Path $pf86 'cloudflared\cloudflared.exe'), (Join-Path $pf 'cloudflared\cloudflared.exe')) }
    if ($Command -eq 'node') { $guesses += @((Join-Path $pf 'nodejs\node.exe')) }
    if ($Command -eq 'nssm' -or $Command -eq 'ffmpeg') { $guesses += @((Join-Path $pf ('WinGet\Links\' + $Command + '.exe')), (Join-Path $env:LOCALAPPDATA ('Microsoft\WinGet\Links\' + $Command + '.exe'))) }
    foreach ($g in $guesses) {
        if ($g -and (Test-Path -LiteralPath $g)) { return $g }
    }
    return $null
}

function Install-WingetPackage {
    # Installs one pinned package version with winget (which verifies the
    # installer's SHA-256 against its manifest). Does nothing when the program
    # is already on PATH, whatever its version: an existing install is kept.
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$What
    )
    $found = Find-FarmTool -Command $Command
    if ($found) { Write-Ok ($What + ' is already installed (' + $found + ')'); return }
    if (-not (Get-ToolPath -Name 'winget')) {
        Stop-Farm -Problem 'winget (the Windows package manager) is not available on this computer.' -WhatToDo 'Install "App Installer" from the Microsoft Store (it contains winget), or update Windows 10 to version 1809 or later, then run the script again. See README, section Troubleshooting.'
    }
    # winget before 1.4 does not know --disable-interactivity and stops on it.
    $wingetVersion = $null
    try { $wingetVersion = ConvertTo-WingetVersion -Text ((Invoke-Native -File 'winget.exe' -Arguments @('--version')).Output -join ' ') } catch { $wingetVersion = $null }
    Write-Note ('Installing ' + $What + ' ' + $Version + ' with winget...')
    $wingetArgs = @('install', '--exact', '--id', $Id, '--version', $Version, '--source', 'winget', '--scope', 'machine',
        '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($wingetVersion -and $wingetVersion -ge (New-Object System.Version(1, 4))) { $wingetArgs += '--disable-interactivity' }
    & winget.exe @wingetArgs | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not (Find-FarmTool -Command $Command)) {
        # Some packages do not support --scope machine; try once without it.
        $wingetArgs = @($wingetArgs | Where-Object { $_ -ne '--scope' -and $_ -ne 'machine' })
        & winget.exe @wingetArgs | Out-Host
        $code = $LASTEXITCODE
    }
    $found = Find-FarmTool -Command $Command
    if (-not $found) {
        Stop-Farm -Problem ('Installing ' + $What + ' with winget did not work (winget exit code ' + $code + ').') -WhatToDo ('Read winget''s own message above. If it says an argument name was not recognized, winget is too old: update "App Installer" in the Microsoft Store (Library -> Get updates) and run the script again. Otherwise run this yourself and read its message:  winget install --exact --id ' + $Id + ' --version ' + $Version + '   Then run the script again. If the version is no longer offered, see README, section Troubleshooting.')
    }
    Write-Ok ($What + ' installed (' + $found + ')')
}

function Invoke-Nssm {
    # Runs nssm and returns its exit code; output is discarded (nssm prints
    # UTF-16, which is unreadable in a console transcript anyway).
    param([Parameter(Mandatory = $true)][string]$Nssm, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $safe = @($Arguments | ForEach-Object { Protect-NativeArgument -Value $_ })
    return (Invoke-Native -File $Nssm -Arguments $safe).Code
}

function Get-FarmServiceConfig {
    # What Windows has on record for an nssm service (read from the registry,
    # where nssm keeps it), in the shape Test-ServiceConfigSame compares.
    param([Parameter(Mandatory = $true)][string]$Name)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $svc = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    $par = Get-ItemProperty -LiteralPath ($key + '\Parameters') -ErrorAction SilentlyContinue
    return @{
        ImagePath           = ([string](Get-JsonProperty -Object $svc -Name 'ImagePath')).Trim('"')
        DependOnService     = @(Get-JsonProperty -Object $svc -Name 'DependOnService')
        Application         = [string](Get-JsonProperty -Object $par -Name 'Application')
        AppParameters       = [string](Get-JsonProperty -Object $par -Name 'AppParameters')
        AppDirectory        = [string](Get-JsonProperty -Object $par -Name 'AppDirectory')
        AppStdout           = [string](Get-JsonProperty -Object $par -Name 'AppStdout')
        AppEnvironmentExtra = @(Get-JsonProperty -Object $par -Name 'AppEnvironmentExtra')
        KitConfig           = [string](Get-JsonProperty -Object $par -Name 'BlossomFarmKitConfig')
    }
}

function Set-FarmService {
    # Creates or updates one nssm service. Idempotent. A service that is
    # running and already configured exactly as asked is left alone, running:
    # stopping the hub would stop the services that depend on it as well. Any
    # other existing service is stopped, reconfigured in place and left
    # stopped. Returns $true when the service was (re)configured.
    param(
        [Parameter(Mandatory = $true)][string]$Nssm,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Application,
        [Parameter(Mandatory = $true)][string]$Parameters,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$LogFile,
        [string[]]$DependsOn = @(),
        [string[]]$Environment = @(),
        # Files the program reads when it starts (its script, its configuration).
        # When one of them changed, the service is restarted even though its
        # settings are the same.
        [string[]]$WatchFiles = @(),
        [switch]$DelayedStart
    )
    if (-not (Test-Path -LiteralPath $Application)) {
        Stop-Farm -Problem ('Cannot create the service ' + $Name + ': ' + $Application + ' does not exist.') -WhatToDo 'Run install.ps1 again from the start; an earlier step did not finish.'
    }
    $start = 'SERVICE_AUTO_START'
    if ($DelayedStart) { $start = 'SERVICE_DELAYED_AUTO_START' }
    # What is compared with the registry, to notice a service that was changed
    # by hand since the kit configured it.
    $wanted = @{
        DependOnService = $DependsOn; Application = $Application; AppParameters = $Parameters
        AppDirectory = $Directory; AppEnvironmentExtra = $Environment
    }
    # A fingerprint of everything this function sets, stored with the service
    # once it is completely configured.
    $watched = @(@($Application) + $WatchFiles | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | ForEach-Object { Get-FileSha256 -Path $_ })
    $fingerprint = Get-TextSha256 -Text ((@($Nssm, $Application, $Parameters, $Directory, $LogFile, $DisplayName, $Description, $start) + @('deps') + $DependsOn + @('env') + $Environment + @('files') + $watched) -join "`n")
    $parametersKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name + '\Parameters'
    $existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        $current = Get-FarmServiceConfig -Name $Name
        if ($existing.Status -eq 'Running' -and $current.KitConfig -eq $fingerprint -and (Test-ServiceConfigSame -Current $current -Wanted $wanted)) {
            return $false
        }
        if ($existing.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
        Remove-ItemProperty -LiteralPath $parametersKey -Name 'BlossomFarmKitConfig' -ErrorAction SilentlyContinue
        $null = Invoke-Nssm -Nssm $Nssm -Arguments @('set', $Name, 'Application', $Application)
    } else {
        $code = Invoke-Nssm -Nssm $Nssm -Arguments @('install', $Name, $Application)
        if ($code -ne 0) {
            Stop-Farm -Problem ('nssm could not create the service ' + $Name + ' (exit code ' + $code + ').') -WhatToDo 'Check that no other program uses a service of that name (services.msc), then run the script again.'
        }
    }
    $settings = @(
        @('AppParameters', $Parameters),
        @('AppDirectory', $Directory),
        @('DisplayName', $DisplayName),
        @('Description', $Description),
        @('Start', $start),
        @('ObjectName', 'LocalSystem'),
        @('AppStdout', $LogFile),
        @('AppStderr', $LogFile),
        @('AppStdoutCreationDisposition', '4'),
        @('AppStderrCreationDisposition', '4'),
        @('AppRotateFiles', '1'),
        @('AppRotateOnline', '1'),
        @('AppRotateBytes', '10485760'),
        @('AppExit', 'Default', 'Restart'),
        @('AppRestartDelay', '5000'),
        @('AppThrottle', '10000'),
        @('AppStopMethodConsole', '5000'),
        @('AppKillProcessTree', '1')
    )
    foreach ($s in $settings) {
        $code = Invoke-Nssm -Nssm $Nssm -Arguments (@('set', $Name) + $s)
        if ($code -ne 0) {
            Stop-Farm -Problem ('nssm could not set ' + $s[0] + ' on the service ' + $Name + ' (exit code ' + $code + ').') -WhatToDo 'Run the script again. If it repeats, remove the service with scripts\uninstall.ps1 -ServicesOnly and install again.'
        }
    }
    $problem = $null
    if ($DependsOn.Count -gt 0) {
        $code = Invoke-Nssm -Nssm $Nssm -Arguments (@('set', $Name, 'DependOnService') + $DependsOn)
        if ($code -ne 0) { $problem = 'DependOnService (nssm exit code ' + $code + ')' }
    } else {
        $null = Invoke-Nssm -Nssm $Nssm -Arguments @('reset', $Name, 'DependOnService')
    }
    # The environment is written straight into the registry value nssm reads
    # (a list of NAME=value strings), not through nssm's command line: a value
    # with spaces that ends in a backslash (a PATH usually does) is mangled by
    # Windows PowerShell 5.1 on the way and would swallow the entries after it.
    try {
        if ($Environment.Count -gt 0) {
            Set-ItemProperty -LiteralPath $parametersKey -Name 'AppEnvironmentExtra' -Type MultiString -Value ([string[]]$Environment) -ErrorAction Stop
        } else {
            Remove-ItemProperty -LiteralPath $parametersKey -Name 'AppEnvironmentExtra' -ErrorAction SilentlyContinue
        }
    } catch { $problem = 'AppEnvironmentExtra (' + $_.Exception.Message + ')' }
    $after = Get-FarmServiceConfig -Name $Name
    if (-not $problem -and -not (Test-ServiceConfigSame -Current $after -Wanted @{ AppEnvironmentExtra = $Environment })) {
        $problem = 'AppEnvironmentExtra (what Windows has on record differs from what was set)'
    }
    if ($problem) {
        Stop-Farm -Problem ('The service ' + $Name + ' could not be configured completely: ' + $problem + '.') -WhatToDo 'Run the script again. If it repeats, remove the service with scripts\uninstall.ps1 -ServicesOnly and install again.'
    }
    Set-ItemProperty -LiteralPath $parametersKey -Name 'BlossomFarmKitConfig' -Type String -Value $fingerprint
    return $true
}

function Start-FarmService {
    param([Parameter(Mandatory = $true)][string]$Name, [int]$WaitSec = 30)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Stop-Farm -Problem ('The Windows service ' + $Name + ' does not exist.') -WhatToDo 'Run install.ps1 again.'
    }
    if ($svc.Status -ne 'Running') {
        try { Start-Service -Name $Name -ErrorAction Stop } catch { }
    }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-Service -Name $Name).Status -eq 'Running') { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Wait-TcpPort {
    param([Parameter(Mandatory = $true)][int]$Port, [int]$WaitSec = 30)
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $Port)
            if ($client.Connected) { return $true }
        } catch { } finally { $client.Close() }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

$FarmFirewallPrefix = 'Blossom farm - no network access to '

function Set-FarmFirewallBlock {
    # One Windows Firewall rule that refuses incoming TCP connections to one
    # program. Why: for every iPhone the GADS provider opens ports
    # (WebDriverAgent, the screen stream) on ALL network addresses of the
    # computer, on port numbers chosen at run time, and neither they nor an
    # Appium server ask for a login. Everything the farm needs reaches these
    # ports from the computer itself (the loopback address, which the firewall
    # never filters), so the rule costs nothing. A block rule wins over any
    # "allow" rule for the same program. TCP only: the live video (WebRTC) is
    # UDP and is not touched. Returns $true when the rule is in place.
    param([Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][string]$Program)
    $display = $FarmFirewallPrefix + $Label
    try {
        Get-NetFirewallRule -DisplayName $display -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $null = New-NetFirewallRule -DisplayName $display -Group 'Blossom farm kit' `
            -Description 'Blossom farm kit: other computers must not reach the ports this program opens. Loopback traffic on this computer is not affected.' `
            -Direction Inbound -Action Block -Protocol TCP -Program $Program -Profile Any -Enabled True -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Remove-FarmFirewallBlock {
    # Removes every firewall rule the kit created. Returns how many.
    $rules = @()
    try { $rules = @(Get-NetFirewallRule -DisplayName ($FarmFirewallPrefix + '*') -ErrorAction SilentlyContinue) } catch { $rules = @() }
    foreach ($r in $rules) { try { Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop } catch { Write-Warn ('Could not remove the firewall rule "' + $r.DisplayName + '".') } }
    return $rules.Count
}

function Get-FarmFirewallState {
    # Available: the firewall could be asked at all. ProfilesOff: profiles
    # (Domain, Private, Public) on which Windows Firewall is switched off.
    # Programs: the programs (lower case) that have an enabled kit block rule.
    $state = New-Object PSObject -Property @{ Available = $false; ProfilesOff = @(); Programs = @() }
    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        $state.ProfilesOff = @($profiles | Where-Object { [string]$_.Enabled -ne 'True' } | ForEach-Object { [string]$_.Name })
        $rules = @(Get-NetFirewallRule -DisplayName ($FarmFirewallPrefix + '*') -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.Enabled -eq 'True' -and [string]$_.Action -eq 'Block' -and [string]$_.Direction -eq 'Inbound' })
        $programs = @()
        foreach ($r in $rules) {
            $filter = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
            if ($filter -and $filter.Program) { $programs += ([string]$filter.Program).ToLowerInvariant() }
        }
        $state.Programs = $programs
        $state.Available = $true
    } catch { $state.Available = $false }
    return $state
}

$FarmServiceNames = @('FarmRestart', 'Cloudflared', 'KeepAvailable', 'FarmGate', 'GadsProvider', 'GadsHub')

function Get-FarmServiceNames {
    # In the order they are stopped (the reverse is the start order).
    return $FarmServiceNames
}

function Connect-Hub {
    # Signs in to the hub on this computer. Returns the token, or $null when
    # the hub refuses the login. Stops when the hub does not answer at all.
    param([Parameter(Mandatory = $true)][string]$HubUrl, [Parameter(Mandatory = $true)][string]$Username, [Parameter(Mandatory = $true)][string]$Password)
    $body = (@{ username = $Username; password = $Password } | ConvertTo-Json -Compress)
    $r = Invoke-FarmHttp -Url ($HubUrl + '/authenticate') -Method 'POST' -Body $body -TimeoutSec 15
    if ($r.Status -eq 0) {
        Stop-Farm -Problem ('The GADS hub does not answer at ' + $HubUrl + ' (' + $r.Error + ').') -WhatToDo 'Check the service: Get-Service GadsHub, MongoDB. Read the end of C:\farm\logs\hub.log. Then run the script again.'
    }
    if ($r.Status -ne 200) { return $null }
    $token = Get-JsonProperty -Object (Get-JsonProperty -Object $r.Json -Name 'result') -Name 'access_token'
    if (-not $token) { $token = Get-JsonProperty -Object $r.Json -Name 'access_token' }
    return $token
}

function Invoke-FarmSelfTest {
    # The same walk the product's "Test connection" takes, from this computer,
    # against the public host names. Returns a list of step results; a step
    # has Id, State (ok, warn, fail, skip), Detail and Fix. The requests carry
    # the headers Blossom's servers send (in particular: no User-Agent), so
    # that Cloudflare treats both alike.
    param(
        [Parameter(Mandatory = $true)][string]$HubHost,
        [Parameter(Mandatory = $true)][string]$ProviderHost,
        [Parameter(Mandatory = $true)][string]$RestartHost,
        [Parameter(Mandatory = $true)][string]$Nickname,
        [Parameter(Mandatory = $true)][string]$HubUser,
        [Parameter(Mandatory = $true)][string]$HubPassword,
        [Parameter(Mandatory = $true)][string]$RestartSecret
    )
    $steps = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Id, $State, $Detail, $Fix)
        $steps.Add((New-Object PSObject -Property @{ Id = $Id; State = $State; Detail = $Detail; Fix = $Fix }))
    }
    $hub = 'https://' + $HubHost
    $provider = 'https://' + $ProviderHost
    $restart = 'https://' + $RestartHost

    # 1 addresses
    $bad = Test-FarmHostnameSet -Hub $HubHost -Provider $ProviderHost -Restart $RestartHost
    if ($bad.Count -gt 0) { & $add 'address' 'fail' ($bad -join ' ') 'Run install.ps1 again and enter valid host names.'; return $steps }
    & $add 'address' 'ok' 'The three addresses are well formed https addresses.' $null

    # 2 DNS: public addresses only
    foreach ($name in @($HubHost, $ProviderHost, $RestartHost)) {
        $addresses = @()
        try { $addresses = @([System.Net.Dns]::GetHostAddresses($name) | ForEach-Object { $_.ToString() }) } catch { $addresses = @() }
        if ($addresses.Count -eq 0) {
            & $add 'dns' 'fail' ($name + ' does not resolve yet.') 'A new DNS record can take a few minutes. Wait, then run scripts\self-test.ps1. If it stays like this, look at the DNS records of your domain in the Cloudflare dashboard: there must be a CNAME for this name pointing at <tunnel id>.cfargotunnel.com.'
            return $steps
        }
        $private = @($addresses | Where-Object { -not (Test-PublicIpAddress -Address $_) })
        if ($private.Count -gt 0) {
            & $add 'dns' 'fail' ($name + ' resolves to a private address (' + ($private -join ', ') + '). Blossom refuses such names.') 'Remove any hosts-file entry or local DNS override for this name; it must resolve to Cloudflare.'
            return $steps
        }
    }
    & $add 'dns' 'ok' 'All three names resolve to public addresses.' $null

    # 3 reach + TLS
    $r = Invoke-FarmHttp -LikeBlossom -Url ($hub + '/health') -TimeoutSec 15
    if ($r.Status -eq 0) {
        & $add 'reach' 'fail' ('The hub address could not be reached: ' + $r.Error) 'Check that the Cloudflared service is running (scripts\status.ps1) and read C:\farm\logs\cloudflared.log.'
        return $steps
    }
    $challengeFix = 'Cloudflare is answering instead of the farm. Blossom''s servers send plain API requests without a browser''s User-Agent and cannot pass a challenge. In the Cloudflare dashboard of your domain: Security -> Settings, switch "Browser Integrity Check" off (it is on by default), or add a rule that skips it for the three farm host names; and remove any Access application, "Under Attack" mode, managed challenge or bot rule for them (docs\network.md, section 5).'
    if ($r.Challenge) {
        & $add 'reach' 'fail' ('Cloudflare blocked or challenged the request (HTTP ' + $r.Status + ') before it reached the hub.') $challengeFix
        return $steps
    }
    if (Test-LooksDown -Status $r.Status -Text $r.Text) {
        & $add 'reach' 'fail' ('The address answers (HTTP ' + $r.Status + '), but not the hub behind it.') 'Check that the GadsHub service is running (scripts\status.ps1).'
        return $steps
    }
    if ($r.Status -ge 300 -and $r.Status -lt 400) {
        & $add 'reach' 'fail' ('The hub address answers with a redirect (HTTP ' + $r.Status + '). Blossom does not follow redirects.') 'Remove redirect rules and any Cloudflare Access application in front of this host name (docs\security.md).'
        return $steps
    }
    & $add 'reach' 'ok' ('Connected to ' + $HubHost + ' with a valid certificate.') $null

    # 4 sign-in
    $body = (@{ username = $HubUser; password = $HubPassword } | ConvertTo-Json -Compress)
    $r = Invoke-FarmHttp -LikeBlossom -Url ($hub + '/authenticate') -Method 'POST' -Body $body -TimeoutSec 15
    $token = Get-JsonProperty -Object (Get-JsonProperty -Object $r.Json -Name 'result') -Name 'access_token'
    if (-not $token) { $token = Get-JsonProperty -Object $r.Json -Name 'access_token' }
    if ($r.Challenge) {
        & $add 'signin' 'fail' ('Cloudflare blocked or challenged the sign-in request (HTTP ' + $r.Status + ') before it reached the hub.') $challengeFix
        return $steps
    }
    if ($r.Status -eq 401 -or $r.Status -eq 403) {
        & $add 'signin' 'fail' 'The hub refused the user name or password.' 'Reset the login with scripts\rotate-secrets.ps1 -HubUser and enter the new password in Blossom.'
        return $steps
    }
    if (-not $token) {
        & $add 'signin' 'fail' ('The address answers (HTTP ' + $r.Status + '), but its sign-in did not return a token.') 'Check that the hub host name points at the hub (port 10000) in C:\farm\config\cloudflared\config.yml.'
        return $steps
    }
    & $add 'signin' 'ok' 'The hub accepted the user name and password.' $null
    $auth = @{ Authorization = ('Bearer ' + $token) }

    # 5 hub endpoints
    $r = Invoke-FarmHttp -LikeBlossom -Url ($hub + '/admin/devices') -Headers $auth -TimeoutSec 15
    $registered = @()
    $list = Get-JsonProperty -Object (Get-JsonProperty -Object $r.Json -Name 'result') -Name 'devices'
    if ($r.Status -eq 200 -and $null -ne $r.Json) {
        if ($list) { $registered = @($list) }
        & $add 'hub' 'ok' 'The hub serves its device register (/admin/devices).' $null
    } elseif ($r.Status -eq 401 -or $r.Status -eq 403) {
        & $add 'hub' 'fail' 'The user signs in but may not read the device register.' 'The hub user Blossom uses needs the admin role (hub page, Admin, Users).'
        return $steps
    } else {
        & $add 'hub' 'fail' ('The hub did not serve /admin/devices (HTTP ' + $r.Status + ').') 'Read C:\farm\logs\hub.log.'
        return $steps
    }

    # extra check, not part of the product's test: GADS 6.0.0 skips its login
    # for hub paths containing "appium"; the tunnel must refuse them (403).
    # (cloudflared matches the rule against the decoded path, the same form
    # the hub checks, so a percent-encoded spelling is refused as well.)
    $leaks = @()
    foreach ($probe in @('/device/kit-selftest/appium/status', '/device/kit-selftest/APPIUM/status', '/device/kit-selftest/appiumSource')) {
        $r = Invoke-FarmHttp -LikeBlossom -Url ($hub + $probe) -TimeoutSec 15
        if ($r.Status -ne 403) { $leaks += ($probe + ' -> HTTP ' + $r.Status) }
    }
    if ($leaks.Count -gt 0) {
        & $add 'hub-appium' 'fail' ('Hub paths containing "appium" are not refused by the tunnel: ' + ($leaks -join '; ') + '.') 'GADS does not check the login on these paths. If Appium is switched on for the provider, stop the tunnel (Stop-Service Cloudflared) and report this on the kit repository; see docs\security.md, section 3.'
    } else {
        & $add 'hub-appium' 'ok' 'Hub paths containing "appium" are refused at the tunnel (403), as they must be.' $null
    }

    # extra check, not part of the product's test: GADS 6.0.0 serves the
    # provider record as an endless stream on this path without a login.
    $r = Invoke-FarmHttp -LikeBlossom -Url ($hub + '/admin/provider/' + [Uri]::EscapeDataString($Nickname) + '/info') -TimeoutSec 8
    if ($r.Status -eq 403) {
        & $add 'hub-provider-info' 'ok' 'The provider record of the hub is refused at the tunnel (403), as it must be.' $null
    } else {
        & $add 'hub-provider-info' 'fail' ('The hub path /admin/provider/<nickname>/info is not refused by the tunnel (HTTP ' + $r.Status + '). GADS serves it without a login.') 'Run install.ps1 again: it rewrites the tunnel configuration and restarts the tunnel. If it stays like this, report it on the kit repository (privately: Security -> Report a vulnerability); see docs\security.md, section 3.'
    }

    # 6 phones
    $r = Invoke-FarmHttp -LikeBlossom -Url ($hub + '/provider/' + [Uri]::EscapeDataString($Nickname) + '/devices') -Headers $auth -TimeoutSec 15
    $sync = @()
    $syncList = Get-JsonProperty -Object $r.Json -Name 'result'
    if ($r.Status -eq 200 -and $syncList) { $sync = @($syncList) }
    $udids = @(@($registered) + @($sync) | ForEach-Object { Get-JsonProperty -Object $_ -Name 'udid' } | Where-Object { $_ } | Sort-Object -Unique)
    $live = @($sync | Where-Object { (Get-JsonProperty -Object $_ -Name 'connected') -eq $true -and (Get-JsonProperty -Object $_ -Name 'provider_state') -eq 'live' }).Count
    if ($udids.Count -eq 0) {
        & $add 'devices' 'warn' 'The connection works, but no phone is registered on the hub yet.' 'Normal for a new farm. Continue with docs\phones.md.'
    } elseif ($live -eq 0) {
        & $add 'devices' 'warn' ('' + $udids.Count + ' phone(s) registered, none live right now.') 'Check the provider, the cables, and WebDriverAgent (docs\phones.md).'
    } else {
        & $add 'devices' 'ok' ('' + $udids.Count + ' phone(s) registered, ' + $live + ' live right now.') $null
    }

    # 7 provider (through the gate)
    $path = '/'
    if ($udids.Count -gt 0) { $path = '/device/' + [Uri]::EscapeDataString([string]$udids[0]) + '/info' }
    $r = Invoke-FarmHttp -LikeBlossom -Url ($provider + $path) -Headers $auth -TimeoutSec 15
    if ($r.Status -eq 0) {
        & $add 'provider' 'fail' ('The provider address could not be reached: ' + $r.Error) 'Check the Cloudflared service and the provider host name in the tunnel configuration.'
    } elseif ($r.Status -eq 401) {
        & $add 'provider' 'fail' 'The provider gate refused a token the hub had just issued.' 'Check that the FarmGate and GadsHub services run (scripts\status.ps1) and read C:\farm\logs\provider-gate.log.'
    } elseif (Test-LooksDown -Status $r.Status -Text $r.Text) {
        & $add 'provider' 'fail' ('The provider address answers (HTTP ' + $r.Status + '), but not the provider behind it.') 'Check that the GadsProvider and FarmGate services run (scripts\status.ps1) and read C:\farm\logs\provider.log.'
    } else {
        & $add 'provider' 'ok' ('The provider answers at ' + $ProviderHost + '. (Live video is opened by a browser and is not part of this test.)') $null
    }
    # extra check, not part of the product's test: the provider must NOT answer without a token
    $r = Invoke-FarmHttp -LikeBlossom -Url ($provider + '/devices') -TimeoutSec 15
    if ($r.Status -eq 200) {
        & $add 'provider-locked' 'fail' 'The provider address answers WITHOUT a login. Anyone who learns this host name could control the phones.' 'The provider host name must point at the provider gate (port 10002), never at the provider itself (port 10001). Run install.ps1 again to rewrite the tunnel configuration.'
    } elseif ($r.Status -eq 401) {
        & $add 'provider-locked' 'ok' 'Without a hub token the provider address answers 401, as it must.' $null
    } else {
        & $add 'provider-locked' 'warn' ('Without a token the provider address answered HTTP ' + $r.Status + ' (expected 401).') 'Run scripts\status.ps1 and check the FarmGate service.'
    }

    # 8 restart service
    $r = Invoke-FarmHttp -LikeBlossom -Url ($restart + '/status') -Headers @{ Authorization = ('Bearer ' + $RestartSecret) } -TimeoutSec 15
    if ($r.Status -eq 0) {
        & $add 'restart' 'fail' ('The restart service could not be reached: ' + $r.Error) 'Check the Cloudflared and FarmRestart services (scripts\status.ps1).'
    } elseif ($r.Status -eq 401 -or $r.Status -eq 403) {
        & $add 'restart' 'fail' 'The restart service refused the secret.' 'Run scripts\rotate-secrets.ps1 -RestartSecret and enter the new secret in Blossom.'
    } elseif ((Test-LooksDown -Status $r.Status -Text $r.Text) -or $r.Status -ne 200 -or $null -eq $r.Json) {
        & $add 'restart' 'fail' ('The restart service did not answer its status (HTTP ' + $r.Status + ').') 'Check the FarmRestart service and read C:\farm\logs\restart-server.log.'
    } else {
        $off = @()
        foreach ($k in @('hub', 'provider', 'cloudflare', 'keep_available', 'mongodb')) {
            if ((Get-JsonProperty -Object $r.Json -Name $k) -ne $true) { $off += $k }
        }
        if ($off.Count -gt 0) { & $add 'restart' 'warn' ('Answers. Reported as not running: ' + ($off -join ', ') + '.') 'Run scripts\status.ps1.' }
        else { & $add 'restart' 'ok' 'Answers, and reports every program as running.' $null }
    }
    $r = Invoke-FarmHttp -LikeBlossom -Url ($restart + '/status') -TimeoutSec 15
    if ($r.Status -ne 401) {
        & $add 'restart-locked' 'fail' ('Without the secret the restart service answered HTTP ' + $r.Status + ' (expected 401).') 'Do not use this farm until this is understood: read C:\farm\logs\restart-server.log and docs\security.md.'
    } else {
        & $add 'restart-locked' 'ok' 'Without the secret the restart service answers 401, as it must.' $null
    }
    return $steps
}

function Write-SelfTestReport {
    # Prints the steps; returns $true when nothing failed.
    param([Parameter(Mandatory = $true)]$Steps)
    $titles = @{ address = 'Addresses'; dns = 'DNS'; reach = 'Secure connection (TLS)'; signin = 'Hub sign-in'; hub = 'Hub answers like GADS';
        'hub-appium' = 'Hub refuses unauthenticated Appium paths'; 'hub-provider-info' = 'Hub refuses the open provider record'; devices = 'Phones'; provider = 'Provider'; 'provider-locked' = 'Provider refuses strangers'; restart = 'Restart service'; 'restart-locked' = 'Restart service refuses strangers' }
    $allOk = $true
    foreach ($s in $Steps) {
        $color = 'Green'; $mark = 'OK    '
        if ($s.State -eq 'warn') { $color = 'Yellow'; $mark = 'CHECK ' }
        if ($s.State -eq 'fail') { $color = 'Red'; $mark = 'FAILED'; $allOk = $false }
        Write-Host ('   ' + $mark + '  ' + $titles[$s.Id] + ': ' + $s.Detail) -ForegroundColor $color
        if ($s.Fix) { Write-Host ('           What to do: ' + $s.Fix) }
    }
    $reached = @($Steps | ForEach-Object { $_.Id })
    foreach ($id in @('address', 'dns', 'reach', 'signin', 'hub', 'devices', 'provider', 'restart')) {
        if ($reached -notcontains $id) { Write-Host ('   NOT RUN ' + $titles[$id] + ': an earlier step failed.') -ForegroundColor DarkGray }
    }
    return $allOk
}

Export-ModuleMember -Function *
