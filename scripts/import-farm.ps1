<#
.SYNOPSIS
    Restores a farm from an archive made by export-farm.ps1, on a new computer.
.DESCRIPTION
        powershell -ExecutionPolicy Bypass -File .\scripts\import-farm.ps1 -Archive C:\farm-export-20260101-1200.zip

    Restores the database, the configuration with its secrets, the tunnel
    credentials and the phone pairings, then tells you to run install.ps1,
    which installs the programs and services around them. The host names, the
    hub passwords and the restart secret stay the same, so nothing has to be
    changed in Blossom CRM.

    The old computer must not run the farm any more (same tunnel).
.PARAMETER Archive
    The archive written by export-farm.ps1.
.PARAMETER Force
    Overwrite an installation that already exists on this computer.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Archive, [switch]$Force)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

try {
    Assert-Administrator
    if (-not (Test-Path -LiteralPath $Archive)) { Stop-Farm -Problem ('Archive not found: ' + $Archive) -WhatToDo 'Give the full path of the .zip file written by export-farm.ps1.' }
    $paths = Get-FarmPaths
    # A C:\farm that this kit did not create and lock is not adopted.
    Initialize-FarmRoot -Root $paths.Root
    if ((Test-Path -LiteralPath $paths.FarmJson) -and -not $Force) {
        Stop-Farm -Problem 'This computer already has a farm installation.' -WhatToDo 'To replace it with the archive, run the same command with -Force. Its database, secrets and tunnel settings will be overwritten.'
    }
    $versions = Read-KitVersions -KitRoot $KitRoot

    Write-Step '1/5  Programs needed for the restore'
    Install-WingetPackage -Id $versions.winget.mongodb.id -Version $versions.winget.mongodb.version -Command 'mongod' -What 'MongoDB'
    Install-WingetPackage -Id $versions.winget.mongodbTools.id -Version $versions.winget.mongodbTools.version -Command 'mongorestore' -What 'MongoDB Database Tools (mongodump, mongorestore)'
    $mongorestore = Find-FarmTool -Command 'mongorestore'

    Write-Step '2/5  Unpacking'
    if (-not (Test-Path -LiteralPath $paths.Logs)) { New-Item -ItemType Directory -Path $paths.Logs -Force | Out-Null }
    $stage = Join-Path $paths.Root 'import-stage'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Expand-Archive -LiteralPath $Archive -DestinationPath $stage -Force
    $manifestFile = Join-Path $stage 'manifest.json'
    $dump = Join-Path $stage 'gads.archive.gz'
    if (-not (Test-Path -LiteralPath $manifestFile) -or -not (Test-Path -LiteralPath $dump) -or -not (Test-Path -LiteralPath (Join-Path $stage 'config\farm.json'))) {
        Remove-Item -LiteralPath $stage -Recurse -Force
        Stop-Farm -Problem 'This file is not an archive written by export-farm.ps1 (manifest, database dump or configuration missing).' -WhatToDo 'Run scripts\export-farm.ps1 on the old computer again and use the file it writes.'
    }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    Write-Ok ('Archive of ' + $manifest.exportedAt + ', provider "' + $manifest.nickname + '".')

    Write-Step '3/5  Database'
    foreach ($name in @('Cloudflared', 'KeepAvailable', 'FarmRestart', 'FarmGate', 'GadsProvider', 'GadsHub')) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
    }
    if (-not (Get-Service -Name 'MongoDB' -ErrorAction SilentlyContinue)) {
        Stop-Farm -Problem 'MongoDB has no Windows service called "MongoDB".' -WhatToDo 'Uninstall MongoDB in Windows Settings -> Apps and run this script again so that it installs MongoDB with its service.'
    }
    if (-not (Start-FarmService -Name 'MongoDB' -WaitSec 60) -or -not (Wait-TcpPort -Port 27017 -WaitSec 60)) {
        Stop-Farm -Problem 'MongoDB does not start.' -WhatToDo 'Read the MongoDB entries in Event Viewer -> Windows Logs -> Application, then run this script again.'
    }
    $r = Invoke-Native -File $mongorestore -Arguments @('--host', '127.0.0.1:27017', ('--archive=' + $dump), '--gzip', '--drop', '--nsInclude', 'gads.*')
    if ($r.Code -ne 0) {
        Stop-Farm -Problem ('mongorestore failed: ' + (($r.Output | Select-Object -Last 3) -join ' ')) -WhatToDo 'Check free space on C: and run this script again. If the old computer ran a newer MongoDB than this kit installs, install that MongoDB version here first.'
    }
    Write-Ok 'Database "gads" restored.'

    Write-Step '4/5  Configuration, secrets and pairings'
    if (-not (Test-Path -LiteralPath $paths.Config)) { New-Item -ItemType Directory -Path $paths.Config -Force | Out-Null }
    Copy-Item -Path (Join-Path $stage 'config\*') -Destination $paths.Config -Recurse -Force
    Write-Ok 'C:\farm\config restored (host names, restart secret, tunnel credentials).'
    if (Test-Path -LiteralPath (Join-Path $stage 'pair_records')) {
        $target = Join-Path (Join-Path $paths.Root ([string]$manifest.nickname)) 'pair_records'
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        Copy-Item -Path (Join-Path $stage 'pair_records\*') -Destination $target -Recurse -Force
        Write-Ok 'The provider''s cached phone pairings restored.'
    }
    if (Test-Path -LiteralPath (Join-Path $stage 'Lockdown')) {
        $lockdown = Join-Path $env:ProgramData 'Apple\Lockdown'
        if (-not (Test-Path -LiteralPath $lockdown)) { New-Item -ItemType Directory -Path $lockdown -Force | Out-Null }
        Copy-Item -Path (Join-Path $stage 'Lockdown\*') -Destination $lockdown -Recurse -Force
        Write-Ok 'Apple''s pairing records restored (the phones should not ask to be trusted again; if one does, tap Trust).'
    }
    Remove-Item -LiteralPath $stage -Recurse -Force

    Write-Step '5/5  Next'
    Write-Note 'Now run the installer. It finds the restored configuration, asks for the hub administrator'
    Write-Note 'password you already had, and installs the programs and services around it:'
    Write-Note '   powershell -ExecutionPolicy Bypass -File .\install.ps1'
    Write-Host '   Make sure the old computer no longer runs the farm, and delete the archive when done.' -ForegroundColor Yellow
    exit 0
}
catch { Write-FarmFailure -ErrorRecord $_; exit 1 }
