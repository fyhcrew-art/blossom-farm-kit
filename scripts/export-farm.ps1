<#
.SYNOPSIS
    Packs a farm into one archive, to move it to another computer.
.DESCRIPTION
        powershell -ExecutionPolicy Bypass -File .\scripts\export-farm.ps1

    The archive holds: the GADS database (phones, users, uploaded
    WebDriverAgent), C:\farm\config (the restart secret, the tunnel credentials,
    the host names), the provider's cached phone pairings, and Apple's pairing
    records. No secret is written into this script or into a log; they are in
    the archive.

    TREAT THE ARCHIVE LIKE A MASTER KEY. It is not encrypted. Whoever gets it
    can run your tunnel, sign in to your hub and control your phones. Carry it
    on an encrypted USB stick (BitLocker To Go) or inside an encrypted 7-Zip
    file, and delete it from both computers when the move is done.

    Then, on the new computer:  scripts\import-farm.ps1 -Archive <file>
    and switch the old computer's farm off (scripts\uninstall.ps1): two
    computers must not run the same tunnel.
.PARAMETER OutFile
    Where to write the archive (default C:\farm-export-<date>.zip).
#>
[CmdletBinding()]
param([string]$OutFile = '')

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

try {
    Assert-Administrator
    $paths = Get-FarmPaths
    $farm = Read-FarmConfig -Paths $paths
    if (-not $farm) { Stop-Farm -Problem 'This computer has no farm installation.' -WhatToDo 'There is nothing to export. Run this on the computer that runs the farm.' }
    $versions = Read-KitVersions -KitRoot $KitRoot
    if (-not $OutFile) { $OutFile = 'C:\farm-export-' + (Get-Date).ToString('yyyyMMdd-HHmm') + '.zip' }
    if (Test-Path -LiteralPath $OutFile) { Stop-Farm -Problem ($OutFile + ' already exists.') -WhatToDo 'Delete it or choose another name with -OutFile.' }

    Write-Step '1/4  Database tools'
    Install-WingetPackage -Id $versions.winget.mongodbTools.id -Version $versions.winget.mongodbTools.version -Command 'mongodump' -What 'MongoDB Database Tools (mongodump, mongorestore)'
    $mongodump = Find-FarmTool -Command 'mongodump'

    Write-Step '2/4  Collecting'
    $stage = Join-Path $paths.Root 'export-stage'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null   # inherits C:\farm's Administrators-only access

    $dump = Join-Path $stage 'gads.archive.gz'
    $r = Invoke-Native -File $mongodump -Arguments @('--host', '127.0.0.1:27017', '--db', 'gads', ('--archive=' + $dump), '--gzip')
    if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $dump)) {
        Remove-Item -LiteralPath $stage -Recurse -Force
        Stop-Farm -Problem ('mongodump failed: ' + (($r.Output | Select-Object -Last 3) -join ' ')) -WhatToDo 'Check that the MongoDB service is running (scripts\status.ps1) and that C: has free space, then run the export again.'
    }
    Write-Ok 'Database "gads" dumped.'

    Copy-Item -LiteralPath $paths.Config -Destination (Join-Path $stage 'config') -Recurse -Force
    Write-Ok 'Configuration and secrets copied.'

    $pairCache = Join-Path (Join-Path $paths.Root ([string]$farm.nickname)) 'pair_records'
    if (Test-Path -LiteralPath $pairCache) {
        Copy-Item -LiteralPath $pairCache -Destination (Join-Path $stage 'pair_records') -Recurse -Force
        Write-Ok 'The provider''s cached phone pairings copied.'
    } else { Write-Note 'No cached phone pairings yet.' }

    $lockdown = Join-Path $env:ProgramData 'Apple\Lockdown'
    if (Test-Path -LiteralPath $lockdown) {
        Copy-Item -LiteralPath $lockdown -Destination (Join-Path $stage 'Lockdown') -Recurse -Force
        Write-Ok 'Apple''s pairing records copied.'
    } else { Write-Note 'No Apple pairing records found (the phones will ask "Trust this computer?" again).' }

    $manifest = @{ exportedAt = (Get-Date).ToString('s'); kit = [string]$versions.kit; nickname = [string]$farm.nickname; format = 1 }
    Write-TextFileUtf8 -Path (Join-Path $stage 'manifest.json') -Text ($manifest | ConvertTo-Json)

    Write-Step '3/4  Packing'
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutFile -CompressionLevel Optimal
    Remove-Item -LiteralPath $stage -Recurse -Force
    Protect-FarmPath -Path $OutFile
    Write-Ok ($OutFile + ' written (' + [Math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 1) + ' MB), readable by Administrators only.')

    Write-Step '4/4  Next'
    Write-Host '   THE ARCHIVE IS NOT ENCRYPTED AND CONTAINS EVERY SECRET OF THIS FARM.' -ForegroundColor Yellow
    Write-Host '   Move it on an encrypted medium, never by e-mail or chat, and delete it afterwards.' -ForegroundColor Yellow
    Write-Note 'On the new computer: unpack the kit, then'
    Write-Note ('   powershell -ExecutionPolicy Bypass -File .\scripts\import-farm.ps1 -Archive <path to ' + (Split-Path -Leaf $OutFile) + '>')
    Write-Note 'Before starting the farm there, stop it here:  scripts\uninstall.ps1'
    exit 0
}
catch { Write-FarmFailure -ErrorRecord $_; exit 1 }
