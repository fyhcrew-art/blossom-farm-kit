<#
.SYNOPSIS
    Moves an installed farm to the versions of THIS kit folder, or first
    fetches the newest kit and then does that.
.DESCRIPTION
    From an Administrator PowerShell, inside the kit folder:

        powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1 -Check     (is there a newer kit? changes nothing)
        powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1 -Latest    (fetch the newest kit, check it, update the farm with it)
        powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1            (update the farm with the kit this script is in)

    The update downloads the GADS programs pinned in the kit's versions.json
    (and verifies their SHA-256), stops the farm for about a minute, replaces
    the programs and the service scripts, and starts everything again. The
    database, the secrets, the tunnel and the phones' pairings are not touched.
    The previous programs are kept next to the new ones; to go back:

        powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1 -Rollback

    -Latest asks the kit repository's main branch which kit is released
    (versions.json and pairing.json there), downloads that commit's archive
    from GitHub, checks every file against the commit's MANIFEST.sha256, and
    refuses a kit that is not newer or that pins another file for a program
    version this kit already pins. Before anything is replaced it prints the
    commit and the versions of the kit, of GADS and of the provider, old and
    new. The kit that was here is kept as <kit folder>.previous. What this
    does and does not protect against is in docs\security.md, section 9.

    Programs installed with winget (MongoDB, Node.js, FFmpeg, cloudflared) are
    not changed by this script; see README, section "Updating".
.PARAMETER Check
    Say whether a newer kit is released. Changes nothing.
.PARAMETER Latest
    Fetch the newest kit, check it, put it in place of this one, and update
    the farm with it.
.PARAMETER Rollback
    Put back the programs and service scripts that the last update replaced.
.PARAMETER ProviderExe
    Path of a GADS-drag.exe you already have, used instead of downloading it.
    Only accepted when its SHA-256 is the one pinned in versions.json.
#>
[CmdletBinding()]
param([switch]$Check, [switch]$Latest, [switch]$Rollback, [string]$ProviderExe = '')

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

function Stop-FarmPrograms {
    foreach ($name in @('Cloudflared', 'KeepAvailable', 'FarmRestart', 'FarmGate', 'GadsProvider', 'GadsHub')) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 4
}

function Start-FarmPrograms {
    $bad = @()
    foreach ($name in @('GadsHub', 'GadsProvider', 'FarmGate', 'KeepAvailable', 'FarmRestart', 'Cloudflared')) {
        if (-not (Start-FarmService -Name $name -WaitSec 40)) { $bad += $name }
    }
    return $bad
}

try {
    Assert-Administrator
    Protect-KitFolder -KitRoot $KitRoot
    if (([int][bool]$Check + [int][bool]$Latest + [int][bool]$Rollback) -gt 1) {
        Stop-Farm -Problem 'Use one of -Check, -Latest and -Rollback at a time.' -WhatToDo 'Run the script again with one of them.'
    }

    if ($Check -or $Latest) {
        $thisKit = Read-KitVersions -KitRoot $KitRoot
        Write-Step 'Looking for a newer kit'
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ('blossom-kit-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try { $released = Get-ReleasedKit -WorkFolder $work }
        finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $released.Ok) { Stop-Farm -Problem $released.Error -WhatToDo 'Nothing was changed. Check the internet connection of this computer and run the script again.' }
        Write-Note ('This kit:          ' + $thisKit.kit)
        Write-Note ('The newest kit:    ' + $released.Version)
        if (-not (Test-KitVersionText -Text ([string]$thisKit.kit)) -or (Compare-KitVersion -Have $released.Version -Want ([string]$thisKit.kit)) -le 0) {
            Write-Ok 'This kit is the newest one. Nothing to fetch.'
            if ($Latest) { Write-Note 'To bring the farm to the versions of this kit, run scripts\update.ps1 without an option.' }
            exit 0
        }
        if (-not $released.Commit) {
            Write-Note ('Kit ' + $released.Version + ' is being prepared and is not released yet. Nothing to fetch; look again later.')
            exit 0
        }
        if ($Check) {
            Write-Ok ('Kit ' + $released.Version + ' is available (commit ' + $released.Commit + ').')
            Write-Note 'To fetch it, check it and update the farm with it, run   scripts\update.ps1 -Latest'
            exit 0
        }
        if (-not (Read-FarmConfig -Paths (Get-FarmPaths))) {
            Stop-Farm -Problem 'This computer has no farm installation, so there is nothing to update.' -WhatToDo 'Nothing was changed. To set up a farm, use the command from Blossom, or download the kit and run install.ps1 (README).'
        }
        Write-Step ('Fetching kit ' + $released.Version + ' (the farm keeps running)')
        $kitFolder = $KitRoot.TrimEnd('\', '/')
        $previous = $kitFolder + '.previous'
        # Administrators run these scripts: nobody else may change them, and
        # nobody may have prepared the folder they are checked in
        # (New-KitStagingFolder in lib\FarmKit.psm1 says how that is made sure).
        $staging = New-KitStagingFolder -Beside $kitFolder
        if (-not $staging.Ok) { Stop-Farm -Problem $staging.Error -WhatToDo 'Nothing was changed. Check that the drive is NTFS, then run the script again; if it repeats, report it on the kit repository.' }
        $stage = $staging.Path
        $saved = Save-KitCommit -Commit $released.Commit -ManifestSha256 $released.ManifestSha256 -WorkFolder $stage
        if (-not $saved.Ok) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            Stop-Farm -Problem $saved.Error -WhatToDo 'Nothing was changed. Run the script again; if it repeats, do not work around it: report it on the kit repository.'
        }
        $problem = $null
        $fetched = $null
        try { $fetched = Get-Content -LiteralPath (Join-Path $saved.Path 'versions.json') -Raw | ConvertFrom-Json } catch { $problem = 'Its versions.json cannot be read.' }
        if (-not $problem) { $problem = Test-KitUpdateRule -Current $thisKit -New $fetched }
        if (-not $problem -and ([string]$fetched.kit -cne $released.Version)) { $problem = 'It says it is kit ' + $fetched.kit + ', but the repository announced kit ' + $released.Version + '.' }
        if (-not $problem -and -not (Test-Path -LiteralPath (Join-Path $saved.Path 'scripts\update.ps1'))) { $problem = 'It has no scripts\update.ps1.' }
        if ($problem) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            Stop-Farm -Problem ('The kit that was fetched was refused. ' + $problem) -WhatToDo 'Nothing was changed. Do not work around it: report it on the kit repository.'
        }
        Write-Ok ('Kit ' + $released.Version + ' was downloaded and every file has the SHA-256 its list names.')
        Write-Note ('Commit:    ' + $released.Commit)
        Write-Note ('This kit:  ' + (Get-KitVersionLine -Versions $thisKit))
        Write-Note ('New kit:   ' + (Get-KitVersionLine -Versions $fetched))
        # The kit's files move up into the staging folder, which already carries
        # the permissions; then the folder takes the place of this kit.
        Get-ChildItem -LiteralPath $saved.Path -Force | Move-Item -Destination $stage -Force
        Remove-Item -LiteralPath $saved.Path -Recurse -Force
        Set-Location -LiteralPath ([System.IO.Path]::GetPathRoot($kitFolder))
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
        try { Move-Item -LiteralPath $kitFolder -Destination $previous -Force }
        catch {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            Stop-Farm -Problem ('Could not put the kit that is in ' + $kitFolder + ' aside: ' + $_.Exception.Message) -WhatToDo 'Nothing was changed. Close every other window that is open in that folder and run the script again.'
        }
        try { Move-Item -LiteralPath $stage -Destination $kitFolder -Force }
        catch {
            Move-Item -LiteralPath $previous -Destination $kitFolder -Force
            Stop-Farm -Problem ('Could not put the new kit into ' + $kitFolder + ': ' + $_.Exception.Message) -WhatToDo 'The kit that was there is back. Run the script again.'
        }
        Write-Ok ('The new kit is in ' + $kitFolder + ' (the one before it: ' + $previous + '). The update continues with it.')
        $shell = (Get-Process -Id $PID).Path
        $passOn = @()
        if ($ProviderExe) { $passOn = @('-ProviderExe', $ProviderExe) }
        & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kitFolder 'scripts\update.ps1') @passOn
        exit $LASTEXITCODE
    }

    $paths = Get-FarmPaths
    $farm = Read-FarmConfig -Paths $paths
    if (-not $farm) { Stop-Farm -Problem 'This computer has no farm installation.' -WhatToDo 'Run install.ps1 instead.' }
    $backup = Join-Path $paths.Root 'previous'
    $files = @(
        @($paths.HubExe, 'GADS.exe'),
        @($paths.ProviderExe, 'GADS-drag.exe'),
        @((Join-Path $paths.Services 'restart-server.js'), 'restart-server.js'),
        @((Join-Path $paths.Services 'provider-gate.js'), 'provider-gate.js'),
        @((Join-Path $paths.Services 'keep-available.ps1'), 'keep-available.ps1'),
        @((Join-Path $paths.Config 'versions.json'), 'versions.json')
    )

    if ($Rollback) {
        Write-Step 'Rollback to the programs before the last update'
        if (-not (Test-Path -LiteralPath (Join-Path $backup 'versions.json'))) {
            Stop-Farm -Problem 'There is nothing to go back to (C:\farm\previous is empty).' -WhatToDo 'A rollback is only possible after an update made with this script.'
        }
        Stop-FarmPrograms
        foreach ($f in $files) {
            $saved = Join-Path $backup $f[1]
            if (Test-Path -LiteralPath $saved) { Copy-Item -LiteralPath $saved -Destination $f[0] -Force }
        }
        $bad = @(Start-FarmPrograms)
        if ($bad.Count -gt 0) { Stop-Farm -Problem ('After the rollback these services did not start: ' + ($bad -join ', ')) -WhatToDo 'Run scripts\status.ps1 -Logs and read the log of the first one.' }
        Write-Ok 'The previous programs are back and running.'
        exit 0
    }

    $new = Read-KitVersions -KitRoot $KitRoot
    $current = $null
    $currentFile = Join-Path $paths.Config 'versions.json'
    if (Test-Path -LiteralPath $currentFile) { $current = Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json }

    Write-Step 'What changes'
    $was = '(unknown)'
    if ($current) { $was = 'kit ' + $current.kit + ', hub ' + $current.gads.version + ', provider ' + $current.gadsDrag.version }
    Write-Note ('Installed: ' + $was)
    Write-Note ('This kit:  kit ' + $new.kit + ', hub ' + $new.gads.version + ', provider ' + $new.gadsDrag.version)

    Write-Step 'Downloading and verifying (the farm keeps running)'
    $newHub = Join-Path $paths.Downloads 'update-GADS.exe'
    $newProvider = Join-Path $paths.Downloads 'update-GADS-drag.exe'
    $hubHash = ([string]$new.gads.hubExeSha256).ToLowerInvariant()
    if ((Test-Path -LiteralPath $paths.HubExe) -and ((Get-FileSha256 -Path $paths.HubExe) -eq $hubHash)) {
        Copy-Item -LiteralPath $paths.HubExe -Destination $newHub -Force
    } else {
        $zip = Join-Path $paths.Downloads 'update-gads-win.zip'
        Get-VerifiedDownload -Url $new.gads.hubZipUrl -Sha256 $new.gads.hubZipSha256 -OutFile $zip -What ('GADS ' + $new.gads.version + ' for Windows')
        $unpack = Join-Path $paths.Downloads 'update-gads-win'
        if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
        $unpacked = Join-Path $unpack 'GADS.exe'
        if (-not (Test-Path -LiteralPath $unpacked) -or ((Get-FileSha256 -Path $unpacked) -ne $hubHash)) {
            Stop-Farm -Problem 'GADS.exe inside the downloaded archive does not have the expected SHA-256.' -WhatToDo 'Nothing was changed. Delete C:\farm\downloads\update-* and run the update again; if it repeats, report it on the kit repository.'
        }
        Copy-Item -LiteralPath $unpacked -Destination $newHub -Force
        Remove-Item -LiteralPath $unpack -Recurse -Force
    }
    $providerHash = ([string]$new.gadsDrag.sha256).ToLowerInvariant()
    if ((Test-Path -LiteralPath $paths.ProviderExe) -and ((Get-FileSha256 -Path $paths.ProviderExe) -eq $providerHash)) {
        Copy-Item -LiteralPath $paths.ProviderExe -Destination $newProvider -Force
    } else {
        if ($ProviderExe) {
            if (-not (Test-Path -LiteralPath $ProviderExe -PathType Leaf) -or ((Get-FileSha256 -Path $ProviderExe) -ne $providerHash)) {
                Stop-Farm -Problem ('-ProviderExe: ' + $ProviderExe + ' is missing or does not have the SHA-256 this kit pins for the provider ' + $new.gadsDrag.version + '.') -WhatToDo 'Nothing was changed. Use the GADS-drag.exe of exactly this version, or leave -ProviderExe out to download it.'
            }
            Copy-Item -LiteralPath $ProviderExe -Destination $newProvider -Force
        }
        Get-VerifiedDownload -Url $new.gadsDrag.url -Sha256 $new.gadsDrag.sha256 -OutFile $newProvider -What ('the patched GADS provider ' + $new.gadsDrag.version)
    }
    Write-Ok 'Both programs are downloaded and their SHA-256 values match.'

    Write-Step 'Replacing (the farm is offline for about a minute)'
    if (-not (Test-Path -LiteralPath $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
    Stop-FarmPrograms
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f[0]) { Copy-Item -LiteralPath $f[0] -Destination (Join-Path $backup $f[1]) -Force }
    }
    Copy-Item -LiteralPath $newHub -Destination $paths.HubExe -Force
    Copy-Item -LiteralPath $newProvider -Destination $paths.ProviderExe -Force
    foreach ($file in @('restart-server.js', 'provider-gate.js', 'keep-available.ps1')) {
        Copy-Item -LiteralPath (Join-Path $KitRoot ('services\' + $file)) -Destination (Join-Path $paths.Services $file) -Force
    }
    Copy-Item -LiteralPath (Join-Path $KitRoot 'versions.json') -Destination $currentFile -Force
    Remove-Item -LiteralPath $newHub, $newProvider -Force -ErrorAction SilentlyContinue

    $bad = @(Start-FarmPrograms)
    if ($bad.Count -gt 0) {
        Stop-Farm -Problem ('After the update these services did not start: ' + ($bad -join ', ')) -WhatToDo 'Go back with   scripts\update.ps1 -Rollback   . To report it on the kit repository, copy the output of   scripts\status.ps1 -Logs   (it masks session tokens and your host names). Never post a file from C:\farm\logs itself: GADS writes request addresses into its logs, and they can contain a login token.'
    }
    Write-Ok 'Updated and running. Check with scripts\status.ps1, then "Test connection" in Blossom.'
    $pairing = Read-FarmPairing -Paths $paths
    if ($pairing) {
        $told = Send-FarmComputer -Paths $paths
        if ($told.Ok) { Write-Ok ('Blossom (' + $pairing.AppOrigin + ') was told the versions this computer runs now.') }
        else { Write-Note ('Blossom could not be told the new versions (' + $told.Message + '). Nothing depends on it; scripts\status.ps1 shows the pairing.') }
    }
    Write-Note 'If this kit changed the tunnel configuration or the services (the README says so under "Updating"), run install.ps1 once as well.'
    exit 0
}
catch { Write-FarmFailure -ErrorRecord $_; exit 1 }
