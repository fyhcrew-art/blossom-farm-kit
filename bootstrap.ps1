<#
.SYNOPSIS
    Blossom farm kit - the first file of the one-command setup (Windows).

.DESCRIPTION
    Blossom CRM shows a command that downloads this file from the kit
    repository at one exact commit, compares its SHA-256 with the value
    Blossom printed, and only then runs it, from an Administrator PowerShell:

        powershell -NoProfile -ExecutionPolicy Bypass -File blossom-bootstrap.ps1 -KitCommit <40 hex digits> -AppOrigin https://... -PairingCode XXXX-XXXX-XXXX-XXXX-XXXX

    What this file does, in order:
      1. downloads the archive GitHub makes of the kit at that same commit;
      2. looks at the list of what is in the archive before unpacking it
         (nothing may lie outside the kit's own folder), and unpacks it into
         a new folder only Administrators can change (its name cannot be
         guessed, and it is created together with its permissions);
      3. compares the SHA-256 of MANIFEST.sha256 in it with the value written
         below, and then the SHA-256 of every unpacked file with that list.
         A file that is missing, changed or not on the list stops everything,
         and so does a folder that holds no file of the list;
      4. puts the kit into C:\blossom-farm-kit, for Administrators to change
         and everybody else to read (a kit that was there before is kept as
         C:\blossom-farm-kit.previous);
      5. starts install.ps1 from there with the options it was given.
    So the command pins this file, this file pins the list, and the list pins
    every file of the kit. The archive itself has no pinned checksum (GitHub
    does not promise the same bytes each time); what is inside it has. When a
    check fails, everything downloaded is deleted and nothing is run.

    -KitCommit COMMIT is the commit of the kit to fetch (the command from
    Blossom carries it). -Destination FOLDER names another place for the kit.
    -VerifyOnly downloads, unpacks into a temporary folder, checks
    everything, says so and stops: nothing is installed and no Administrator
    rights are needed. Every other option is handed to install.ps1 unchanged
    (Get-Help .\install.ps1 lists them).

    The value of $KitManifestSha256 is written by tools/make-manifest.sh.
#>

$ErrorActionPreference = 'Stop'
$KitRepository = 'fyhcrew-art/blossom-farm-kit'
$KitArchiveUrl = 'https://github.com/fyhcrew-art/blossom-farm-kit/archive'
$KitManifestSha256 = 'c003825f8a505b51b1068fadadc207ba68285aad8b8d918830ec0883b1630dab'

# No param() block on purpose: every option except the three below belongs to
# install.ps1 and is passed on exactly as it was written.
$Destination = ''
$KitCommit = ''
$VerifyOnly = $false
$InstallerArguments = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    if ([string]$args[$i] -ieq '-Destination' -and ($i + 1) -lt $args.Count) { $Destination = [string]$args[$i + 1]; $i++ }
    elseif ([string]$args[$i] -ieq '-KitCommit' -and ($i + 1) -lt $args.Count) { $KitCommit = [string]$args[$i + 1]; $i++ }
    elseif ([string]$args[$i] -ieq '-VerifyOnly') { $VerifyOnly = $true }
    else { $InstallerArguments += $args[$i] }
}

$stage = ''
function Stop-Bootstrap {
    param([string]$Problem, [string]$WhatToDo)
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ''
    Write-Host ('PROBLEM:    ' + $Problem) -ForegroundColor Red
    Write-Host ('WHAT TO DO: ' + $WhatToDo) -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$again = 'In Blossom open Phone Farm -> Farm setup -> Connect a computer and copy the command again.'
$report = 'Do not work around it. Run the command again; if it repeats, the download is being altered on the way or does not belong to this file: report it on the kit repository.'
$onWindows = ($env:OS -eq 'Windows_NT')
if ($KitManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { Stop-Bootstrap 'This bootstrap file is damaged.' $again }
if ($KitArchiveUrl -notmatch '^https://') { Stop-Bootstrap 'This bootstrap file names a download address that is not https.' $again }
if (-not $KitCommit) {
    Stop-Bootstrap 'The command does not say which commit of the kit to fetch (-KitCommit).' ($again + ' If you have the kit folder already, run install.ps1 inside it.')
}
if ($KitCommit -cnotmatch '^[0-9a-f]{40}$') { Stop-Bootstrap 'The value of -KitCommit is not a commit: it must be 40 digits and letters a to f.' $again }
if ($onWindows -and -not $VerifyOnly) {
    $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Bootstrap 'This command must run as Administrator.' 'Close this window. Press Start, type "powershell", right-click "Windows PowerShell", choose "Run as administrator", and paste the command from Blossom again.'
    }
}
if (-not $Destination) { $Destination = 'C:\blossom-farm-kit' }
if (-not $VerifyOnly -and -not [System.IO.Path]::IsPathRooted($Destination)) { Stop-Bootstrap ('The folder for the kit must be a full path: ' + $Destination) 'Leave -Destination out to use C:\blossom-farm-kit.' }
$Destination = $Destination.TrimEnd('\', '/')

$top = ($KitRepository -split '/')[-1] + '-' + $KitCommit
$url = $KitArchiveUrl + '/' + $KitCommit + '.zip'
$previous = $Destination + '.previous'

Write-Host ''
Write-Host ('Blossom farm kit - fetching the kit (commit ' + $KitCommit + ')') -ForegroundColor Cyan
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# The folder everything is unpacked and checked in. Administrators run the
# scripts of the kit, so nobody else may be able to change them - and ordinary
# accounts may create folders directly on a drive. The folder must therefore
# be one nobody could prepare: its name cannot be guessed, it must not exist,
# it is created together with its permissions (Administrators and SYSTEM:
# full; Users: read; nothing inherited), and it is looked at again before
# anything is written into it. (lib\FarmKit.psm1 does the same in
# New-KitStagingFolder for scripts\update.ps1 -Latest.)
if ($VerifyOnly) { $newStage = Join-Path ([System.IO.Path]::GetTempPath()) ('blossom-kit-' + [Guid]::NewGuid().ToString('N')) }
else { $newStage = $Destination + '.new-' + [Guid]::NewGuid().ToString('N') }
$ntfs = 'Check that the drive is NTFS, then run the command again; if it repeats, report it on the kit repository.'
if (Test-Path -LiteralPath $newStage) { Stop-Bootstrap ($newStage + ' exists already.') 'Run the command again.' }
try {
    if (-not $onWindows -or $VerifyOnly) { New-Item -ItemType Directory -Path $newStage -ErrorAction Stop | Out-Null }
    else {
        $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $none = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true, $false)
        foreach ($grant in @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-18', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
            $account = New-Object System.Security.Principal.SecurityIdentifier($grant[0])
            $rights = [System.Security.AccessControl.FileSystemRights]$grant[1]
            $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($account, $rights, $inherit, $none, $allow)))
        }
        if ($PSVersionTable.PSVersion.Major -lt 6) { [void][System.IO.Directory]::CreateDirectory($newStage, $security) }
        else { [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $newStage) }
    }
} catch { Stop-Bootstrap ('Could not create ' + $newStage + ': ' + $_.Exception.Message) $ntfs }
if ($onWindows -and -not $VerifyOnly) {
    $problem = ''
    try {
        $sid = [System.Security.Principal.SecurityIdentifier]
        $acl = Get-Acl -LiteralPath $newStage
        $owner = $acl.GetOwner($sid).Value
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if (@('S-1-5-32-544', 'S-1-5-18', $me) -notcontains $owner) { $problem = 'its owner is another account (' + $owner + ')' }
        elseif (-not $acl.AreAccessRulesProtected) { $problem = 'it takes permissions from the folder above it' }
        elseif (@(Get-ChildItem -LiteralPath $newStage -Force).Count -ne 0) { $problem = 'it is not empty' }
        else {
            foreach ($rule in $acl.GetAccessRules($true, $true, $sid)) {
                if ($rule.AccessControlType -ne $allow) { continue }
                $who = $rule.IdentityReference.Value
                if ($who -eq 'S-1-5-32-544' -or $who -eq 'S-1-5-18') { continue }
                if ($who -eq 'S-1-5-32-545' -and (([int]$rule.FileSystemRights) -band (-bnot 0x1200A9)) -eq 0) { continue }
                $problem = 'the account ' + $who + ' may change it'
                break
            }
        }
    } catch { $problem = 'its permissions cannot be read: ' + $_.Exception.Message }
    # $stage is still empty here: a folder that failed this check is not ours to delete.
    if ($problem) { Stop-Bootstrap ($newStage + ' is not a folder only Administrators can change: ' + $problem + '. Nothing was downloaded or run.') $ntfs }
}
$stage = $newStage

$zip = Join-Path $stage 'kit.zip'
$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads very slow
try {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 900
} catch {
    $todo = 'Check the internet connection of this computer and run the command again. Address: ' + $url
    if ($_.Exception.Message -match '404') { $todo = 'The kit repository does not have this commit. ' + $again + ' Address: ' + $url }
    Stop-Bootstrap ('Downloading the kit failed: ' + $_.Exception.Message) $todo
} finally { $ProgressPreference = $oldProgress }

# The list of the archive, before anything is unpacked: every entry inside
# the one folder that belongs to this commit. Each file is then written by
# this script itself, to a path it has checked.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$unpacked = Join-Path $stage 'unpacked'
$kit = Join-Path $unpacked $top
$archive = $null
try { $archive = [System.IO.Compression.ZipFile]::OpenRead($zip) }
catch { Stop-Bootstrap 'The kit archive is incomplete or damaged (the download was cut short?). Nothing was unpacked or run.' 'Run the command again.' }
$problem = ''
try {
    foreach ($entry in $archive.Entries) {
        $name = [string]$entry.FullName
        if ($name -ceq ($top + '/')) { continue }
        if (-not $name.StartsWith($top + '/', [System.StringComparison]::Ordinal) -or $name -match '\\|:|(^|/)\.\.(/|$)|//') { $problem = $name; break }
    }
    if (-not $problem) {
        New-Item -ItemType Directory -Path $kit -Force | Out-Null
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            $target = Join-Path $unpacked ($name -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if ($name.EndsWith('/')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            $folder = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    }
} catch {
    $archive.Dispose(); $archive = $null
    Stop-Bootstrap ('The kit archive could not be unpacked: ' + $_.Exception.Message + ' Nothing was run.') 'Check the free space on the disk and run the command again.'
} finally { if ($archive) { $archive.Dispose() } }
if ($problem) { Stop-Bootstrap ('The kit archive holds something outside the folder of this commit (' + $problem + '). Nothing was unpacked or run.') $report }
Remove-Item -LiteralPath $zip -Force

# Every file against the list, and the list against the value in this file.
$manifest = Join-Path $kit 'MANIFEST.sha256'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Stop-Bootstrap 'The kit that was downloaded has no MANIFEST.sha256: it is not a kit this file can check. Nothing was run.' $again }
$got = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
if ($got -cne $KitManifestSha256) {
    Stop-Bootstrap ('The list of files of the kit that was downloaded is not the one this file expects (expected ' + $KitManifestSha256 + ', got ' + $got + '): the kit is not the one of this command, or it was changed. Nothing was run.') $report
}
$listed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($line in [System.IO.File]::ReadAllLines($manifest)) {
    if ($line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*)$' -or $line -match '(^|[ /])\.\.?(/|$)') {
        Stop-Bootstrap 'The list of files of the kit has a line that is not a checksum and a file name. Nothing was run.' $report
    }
    $want = $Matches[1]; $name = $Matches[2]
    $file = Join-Path $kit ($name -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-Bootstrap ('The kit that was downloaded lacks the file ' + $name + '. Nothing was run.') $report }
    $got = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -cne $want) {
        Stop-Bootstrap ('The file ' + $name + ' of the kit that was downloaded is not the one the list names (expected SHA-256 ' + $want + ', got ' + $got + '). Nothing was run.') $report
    }
    [void]$listed.Add($name)
}
# Nothing may be there that the list does not name: no file, and no folder
# that holds no file of the list. Four files cannot be on the list
# (tools/make-manifest.sh says why); they are not part of the installed kit
# and are removed.
$unlisted = @('MANIFEST.sha256', 'bootstrap.sh', 'bootstrap.ps1', 'pairing.json')
$kitFull = (Get-Item -LiteralPath $kit).FullName.TrimEnd('\', '/')
foreach ($item in (Get-ChildItem -LiteralPath $kit -Recurse -Force -File)) {
    $name = $item.FullName.Substring($kitFull.Length + 1) -replace '\\', '/'
    if (-not $listed.Contains($name) -and $unlisted -cnotcontains $name) {
        Stop-Bootstrap ('The kit that was downloaded holds a file that its list does not name: ' + $name + '. Nothing was run.') $report
    }
}
# Nor a folder that holds no file of the list.
$folders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($name in $listed) {
    $parts = $name -split '/'
    for ($i = 1; $i -lt $parts.Count; $i++) { [void]$folders.Add(($parts[0..($i - 1)] -join '/')) }
}
foreach ($item in (Get-ChildItem -LiteralPath $kit -Recurse -Force -Directory)) {
    $name = $item.FullName.Substring($kitFull.Length + 1) -replace '\\', '/'
    if (-not $folders.Contains($name)) {
        Stop-Bootstrap ('The kit that was downloaded holds a folder that its list names no file for: ' + $name + '. Nothing was run.') $report
    }
}
foreach ($name in @('bootstrap.sh', 'bootstrap.ps1', 'pairing.json')) {
    $file = Join-Path $kit $name
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}
Write-Host ('   [ok]   The kit was downloaded and every one of its ' + $listed.Count + ' files has the SHA-256 this command pins.') -ForegroundColor Green

if ($VerifyOnly) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '   [ok]   Checked only (-VerifyOnly): nothing was installed or changed.' -ForegroundColor Green
    exit 0
}

if (-not (Test-Path -LiteralPath (Join-Path $kit 'install.ps1'))) { Stop-Bootstrap 'The kit does not contain install.ps1.' 'Report it on the kit repository.' }
# The kit's files move up into the staging folder, which already carries the
# permissions; then the folder takes the place of the kit that was there.
Get-ChildItem -LiteralPath $kit -Force | Move-Item -Destination $stage -Force
Remove-Item -LiteralPath $unpacked -Recurse -Force
if (Test-Path -LiteralPath $Destination) {
    if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
    try { Move-Item -LiteralPath $Destination -Destination $previous -Force }
    catch { Stop-Bootstrap ('Could not move the kit that is in ' + $Destination + ' out of the way: ' + $_.Exception.Message) 'Close every window that is open in that folder and run the command again.' }
}
Move-Item -LiteralPath $stage -Destination $Destination -Force
Write-Host ('   [ok]   The kit is in ' + $Destination + '. Keep the folder: the maintenance scripts are in it.') -ForegroundColor Green

$shell = (Get-Process -Id $PID).Path
& $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Destination 'install.ps1') @InstallerArguments
exit $LASTEXITCODE
