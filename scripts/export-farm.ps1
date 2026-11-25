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
    Where to write the archive (default C:\farm\export\farm-export-<date>.zip,
    a folder only Administrators can read). On an NTFS drive the file is
    restricted to Administrators before anything is written into it. A USB
    stick formatted FAT32 or exFAT has no file permissions at all: the script
    says so and asks before writing there.
#>
[CmdletBinding()]
param([string]$OutFile = '')

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

try {
    Assert-Administrator
    Protect-KitFolder -KitRoot $KitRoot
    $paths = Get-FarmPaths
    $farm = Read-FarmConfig -Paths $paths
    if (-not $farm) { Stop-Farm -Problem 'This computer has no farm installation.' -WhatToDo 'There is nothing to export. Run this on the computer that runs the farm.' }
    $versions = Read-KitVersions -KitRoot $KitRoot
    if (-not $OutFile) {
        $exportDir = Join-Path $paths.Root 'export'
        if (-not (Test-Path -LiteralPath $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }   # inherits C:\farm's Administrators-only access
        $OutFile = Join-Path $exportDir ('farm-export-' + (Get-Date).ToString('yyyyMMdd-HHmm') + '.zip')
    }
    $OutFile = [System.IO.Path]::GetFullPath($OutFile)
    if (Test-Path -LiteralPath $OutFile) { Stop-Farm -Problem ($OutFile + ' already exists.') -WhatToDo 'Delete it or choose another name with -OutFile.' }
    $outDir = Split-Path -Parent $OutFile
    if (-not $outDir -or -not (Test-Path -LiteralPath $outDir -PathType Container)) { Stop-Farm -Problem ('The folder for the archive does not exist: ' + $outDir) -WhatToDo 'Create it, or choose another place with -OutFile.' }

    # File permissions exist on NTFS (and ReFS) only. Decided before anything
    # secret is written: either the file can be restricted first, or the
    # person is told plainly that this medium cannot protect it.
    $canRestrict = $false
    $fileSystem = ''
    try { $fileSystem = [string](New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($OutFile))).DriveFormat } catch { $fileSystem = '' }
    if ($fileSystem -eq 'NTFS' -or $fileSystem -eq 'ReFS') { $canRestrict = $true }
    if (-not $canRestrict) {
        $shown = $fileSystem
        if (-not $shown) { $shown = 'unknown' }
        Write-Warn ($OutFile + ' is on a drive without file permissions (file system: ' + $shown + ').')
        Write-Warn 'Everybody who can read that drive can read the archive, with every secret of this farm. Only continue if the drive itself is encrypted (BitLocker To Go).'
        $answer = Read-Host -Prompt 'Type YES to write the archive there anyway'
        if ($answer -cne 'YES') { Write-Note 'Nothing was written.'; exit 0 }
    }

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
    # The archive is built inside C:\farm (Administrators only). The
    # destination is created empty and restricted BEFORE the bytes are copied
    # into it, so the secrets never sit in a file that others can open.
    $packed = Join-Path $paths.Root ('export-' + (New-RandomSecret -Bytes 16 -Format Hex) + '.zip')
    $written = $false
    try {
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $packed -CompressionLevel Optimal
        if ($packed -ne $OutFile) {
            $out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $out.Close()
            $written = $true
            if ($canRestrict) { Protect-FarmPath -Path $OutFile }
            $source = [System.IO.File]::OpenRead($packed)
            try {
                $out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try { $source.CopyTo($out) } finally { $out.Close() }
            } finally { $source.Close() }
        }
    } catch {
        # Never leave a half-written or unprotected archive behind.
        if ($written -and (Test-Path -LiteralPath $OutFile)) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if (Test-Path -LiteralPath $packed) { Remove-Item -LiteralPath $packed -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $size = [Math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 1)
    if ($canRestrict) { Write-Ok ($OutFile + ' written (' + $size + ' MB), readable by Administrators only.') }
    else { Write-Warn ($OutFile + ' written (' + $size + ' MB). It is NOT protected by file permissions: anyone with the drive can read it.') }

    Write-Step '4/4  Next'
    Write-Host '   THE ARCHIVE IS NOT ENCRYPTED AND CONTAINS EVERY SECRET OF THIS FARM.' -ForegroundColor Yellow
    Write-Host '   Move it on an encrypted medium, never by e-mail or chat, and delete it afterwards.' -ForegroundColor Yellow
    Write-Note 'On the new computer: unpack the kit, then'
    Write-Note ('   powershell -ExecutionPolicy Bypass -File .\scripts\import-farm.ps1 -Archive <path to ' + (Split-Path -Leaf $OutFile) + '>')
    Write-Note 'Before starting the farm there, stop it here:  scripts\uninstall.ps1'
    Write-Note 'Copy the archive to the encrypted medium first: uninstall.ps1 -RemoveData deletes C:\farm with everything in it.'
    exit 0
}
catch { Write-FarmFailure -ErrorRecord $_; exit 1 }
