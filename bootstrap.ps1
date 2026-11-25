<#
.SYNOPSIS
    Blossom farm kit - the first file of the one-command setup (Windows).

.DESCRIPTION
    Blossom CRM shows a command that downloads this file from a kit release,
    compares its SHA-256 with the value Blossom printed, and only then runs
    it, from an Administrator PowerShell:

        powershell -NoProfile -ExecutionPolicy Bypass -File blossom-bootstrap.ps1 -AppOrigin https://... -PairingCode XXXX-XXXX-XXXX-XXXX-XXXX

    What this file does, in order:
      1. downloads SHA256SUMS of the same kit release and compares its
         SHA-256 with the value written into this file when the release was
         made;
      2. downloads the kit archive and compares its SHA-256 with the one in
         SHA256SUMS;
      3. unpacks the kit to C:\blossom-farm-kit, for Administrators to change
         and everybody else to read (a kit that was there before is kept as
         C:\blossom-farm-kit.previous);
      4. starts install.ps1 from there with the options it was given.
    So the command pins this file, this file pins SHA256SUMS, and SHA256SUMS
    pins the archive. A file that fails its check is deleted, never unpacked,
    never run.

    -Destination FOLDER names another place for the kit. Every other option
    is handed to install.ps1 unchanged (Get-Help .\install.ps1 lists them).

    The copy of this file in the source tree is a template: the four values
    below are filled in when a kit release is made (docs\RELEASING.md), and
    the template refuses to run.
#>

$ErrorActionPreference = 'Stop'
$KitTag = '@KIT_TAG@'
$KitBaseUrl = '@KIT_BASE_URL@'
$KitArchive = '@KIT_ARCHIVE@'
$KitSumsSha256 = '@KIT_SUMS_SHA256@'

# No param() block on purpose: every option except -Destination belongs to
# install.ps1 and is passed on exactly as it was written.
$Destination = ''
$InstallerArguments = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    if ([string]$args[$i] -ieq '-Destination' -and ($i + 1) -lt $args.Count) { $Destination = [string]$args[$i + 1]; $i++ }
    else { $InstallerArguments += $args[$i] }
}

function Stop-Bootstrap {
    param([string]$Problem, [string]$WhatToDo)
    Write-Host ''
    Write-Host ('PROBLEM:    ' + $Problem) -ForegroundColor Red
    Write-Host ('WHAT TO DO: ' + $WhatToDo) -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$again = 'In Blossom open Phone Farm -> Farm setup -> Connect a computer and copy the command again.'
$onWindows = ($env:OS -eq 'Windows_NT')
if ($KitSumsSha256 -cnotmatch '^[0-9a-f]{64}$') {
    Stop-Bootstrap 'This is the template of the bootstrap file, not the one of a kit release.' ($again + ' If you have the kit folder already, run install.ps1 inside it.')
}
if ($KitBaseUrl -notmatch '^https://') { Stop-Bootstrap 'This bootstrap file names a download address that is not https.' $again }
if (-not $KitArchive -or $KitArchive -match '[\\/]|\.\.') { Stop-Bootstrap 'This bootstrap file is damaged.' $again }
if ($onWindows) {
    $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Bootstrap 'This command must run as Administrator.' 'Close this window. Press Start, type "powershell", right-click "Windows PowerShell", choose "Run as administrator", and paste the command from Blossom again.'
    }
}
if (-not $Destination) { $Destination = 'C:\blossom-farm-kit' }
if (-not [System.IO.Path]::IsPathRooted($Destination)) { Stop-Bootstrap ('The folder for the kit must be a full path: ' + $Destination) 'Leave -Destination out to use C:\blossom-farm-kit.' }
$Destination = $Destination.TrimEnd('\', '/')

$stage = $Destination + '.new'
$previous = $Destination + '.previous'

function Get-KitFile {
    param([string]$Name, [string]$OutFile)
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads very slow
    try {
        Invoke-WebRequest -Uri ($KitBaseUrl + '/' + $Name) -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
    } catch {
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Stop-Bootstrap ('Downloading ' + $Name + ' of the kit release ' + $KitTag + ' failed: ' + $_.Exception.Message) ('Check the internet connection of this computer and run the command again. Address: ' + $KitBaseUrl + '/' + $Name)
    } finally { $ProgressPreference = $old }
}

function Stop-BadChecksum {
    param([string]$What, [string]$Want, [string]$Got)
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Bootstrap ($What + ' (expected ' + $Want + ', got ' + $Got + '). Nothing was unpacked or run.') 'Do not work around it. Run the command again; if it repeats, the download is being altered on the way or the release was changed: report it on the kit repository.'
}

Write-Host ''
Write-Host ('Blossom farm kit - fetching the kit (' + $KitTag + ')') -ForegroundColor Cyan
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
if ($onWindows) {
    # Administrators run these scripts: nobody else may change them. Set
    # before anything is put into the folder (Administrators, SYSTEM: full;
    # Users: read).
    & icacls.exe $stage /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' /grant:r '*S-1-5-18:(OI)(CI)F' /grant:r '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Stop-Bootstrap ('Could not restrict access to ' + $stage + '.') 'Check that the drive is NTFS, then run the command again.'
    }
}

$sumsFile = Join-Path $stage 'SHA256SUMS'
Get-KitFile -Name 'SHA256SUMS' -OutFile $sumsFile
$got = (Get-FileHash -LiteralPath $sumsFile -Algorithm SHA256).Hash.ToLowerInvariant()
if ($got -cne $KitSumsSha256) { Stop-BadChecksum 'The list of checksums of the kit release is not the one this file expects' $KitSumsSha256 $got }
$want = $null
foreach ($line in (Get-Content -LiteralPath $sumsFile)) {
    $parts = @(([string]$line).Trim() -split '\s+', 2)
    if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -ceq $KitArchive -and $parts[0] -match '^[0-9a-fA-F]{64}$') { $want = $parts[0].ToLowerInvariant(); break }
}
if (-not $want) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Bootstrap ('The list of checksums of the kit release does not name ' + $KitArchive + '.') 'Report it on the kit repository.'
}
$zip = Join-Path $stage 'kit.zip'
Get-KitFile -Name $KitArchive -OutFile $zip
$got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($got -cne $want) { Stop-BadChecksum 'The kit archive was downloaded but its SHA-256 is wrong' $want $got }
Write-Host ('   [ok]   ' + $KitArchive + ' downloaded, SHA-256 verified.') -ForegroundColor Green

$unpacked = Join-Path $stage 'unpacked'
Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
$top = @(Get-ChildItem -LiteralPath $unpacked -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') } | Select-Object -First 1)
if ($top.Count -eq 0) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Bootstrap 'The kit archive does not contain install.ps1.' 'Report it on the kit repository.'
}
Remove-Item -LiteralPath $zip, $sumsFile -Force
# The kit's files move up into the staging folder, which already carries the
# permissions; then the folder takes the place of the kit that was there.
Get-ChildItem -LiteralPath $top[0].FullName -Force | Move-Item -Destination $stage -Force
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
