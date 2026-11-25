<#
.SYNOPSIS
    Removes the farm services from this computer; optionally the data too.
.DESCRIPTION
        powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
            removes the six Windows services and the kit's Windows Firewall
            rules. C:\farm, the database, the tunnel and the installed programs
            stay: install.ps1 brings the farm back.

        powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -RemoveData
            also deletes the tunnel at Cloudflare (when possible), the GADS
            database and C:\farm with every secret and phone pairing in it.

    A computer that is paired with Blossom can give the pairing up as well
    (-Unpair, or the question asked with -RemoveData): Blossom then no longer
    accepts anything from this computer. The site stays listed in Blossom
    until an admin removes it there. Do NOT unpair a farm that was moved to
    another computer with export-farm: the new computer uses the same pairing.

    Programs installed with winget and the DNS records are listed at the end
    with the commands to remove them; the script does not remove them itself.
.PARAMETER RemoveData
    Delete the tunnel, the database "gads" and C:\farm. Cannot be undone.
.PARAMETER Unpair
    Give up the pairing with Blossom, without asking.
.PARAMETER ServicesOnly
    Same as running without parameters (kept for clarity in instructions).
#>
[CmdletBinding()]
param([switch]$RemoveData, [switch]$ServicesOnly, [switch]$Unpair)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

try {
    Assert-Administrator
    if ($RemoveData -and $ServicesOnly) { Stop-Farm -Problem '-RemoveData and -ServicesOnly contradict each other.' -WhatToDo 'Use one of them.' }
    $paths = Get-FarmPaths
    $farm = Read-FarmConfig -Paths $paths

    if ($RemoveData) {
        Write-Host ''
        Write-Host 'This deletes the farm from this computer: services, tunnel, the GADS database' -ForegroundColor Yellow
        Write-Host '(phones, users, uploaded WebDriverAgent), every secret and the phones'' pairings.' -ForegroundColor Yellow
        Write-Host 'It cannot be undone. To move a farm instead, use scripts\export-farm.ps1 first.' -ForegroundColor Yellow
        $answer = Read-Host -Prompt 'Type DELETE to continue'
        if ($answer -cne 'DELETE') { Write-Note 'Nothing was changed.'; exit 0 }
    }

    # The pairing with Blossom. Asked before anything is removed, and only
    # when the pairing file is about to be deleted anyway.
    $pairing = Read-FarmPairing -Paths $paths
    $stillPaired = [bool]$pairing
    if ($pairing -and $RemoveData -and -not $Unpair) {
        Write-Host ''
        Write-Host ('This computer is paired with Blossom (' + $pairing.AppOrigin + '). Unpair it as well?') -ForegroundColor Yellow
        Write-Host 'Answer no if you moved this farm to another computer with export-farm: the new' -ForegroundColor Yellow
        Write-Host 'computer uses the same pairing, and unpairing would cut it off.' -ForegroundColor Yellow
        $answer = Read-Host -Prompt 'Unpair this computer from Blossom? [y/N]'
        if ([string]$answer -match '^\s*[yY]') { $Unpair = $true }
    }
    if ($pairing -and $Unpair) {
        Write-Step 'Unpairing from Blossom'
        $gone = Remove-FarmPairing -Paths $paths
        if ($gone.Ok) {
            $stillPaired = $false
            Write-Ok ('Blossom (' + $pairing.AppOrigin + ') no longer accepts anything from this computer.')
        } else {
            Write-Warn ('Blossom could not be told (' + $gone.Message + '). Revoke this computer there instead: Phone Farm -> Farm setup -> the site -> Unpair computer.')
        }
    }

    Write-Step 'Removing the Windows services'
    $nssm = $paths.Nssm
    if (-not (Test-Path -LiteralPath $nssm)) { $nssm = Find-FarmTool -Command 'nssm' }
    foreach ($name in (Get-FarmServiceNames)) {
        if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { Write-Note ($name + ': not installed'); continue }
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        $code = 1
        if ($nssm) { $code = Invoke-Nssm -Nssm $nssm -Arguments @('remove', $name, 'confirm') }
        if ($code -ne 0) { $null = Invoke-Native -File 'sc.exe' -Arguments @('delete', $name) }
        Write-Ok ($name + ' removed')
    }

    $removedRules = Remove-FarmFirewallBlock
    if ($removedRules -gt 0) { Write-Ok ('' + $removedRules + ' Windows Firewall rule(s) of the kit removed.') }

    if ($RemoveData) {
        Write-Step 'Deleting the tunnel at Cloudflare'
        $cert = Join-Path $paths.Cloudflared 'cert.pem'
        $cloudflared = Find-FarmTool -Command 'cloudflared'
        $tunnelId = $null
        if ($farm) { $tunnelId = [string](Get-JsonProperty -Object $farm -Name 'tunnelId') }
        if ($cloudflared -and $tunnelId -and (Test-Path -LiteralPath $cert)) {
            $env:TUNNEL_ORIGIN_CERT = $cert
            $r = Invoke-Native -File $cloudflared -Arguments @('tunnel', 'delete', '-f', $tunnelId)
            Remove-Item Env:\TUNNEL_ORIGIN_CERT -ErrorAction SilentlyContinue
            if ($r.Code -eq 0) { Write-Ok 'Tunnel deleted.' }
            else { Write-Warn ('The tunnel could not be deleted from here (' + ($r.Output -join ' ') + '). Delete it in the Cloudflare dashboard: Zero Trust -> Networks -> Tunnels.') }
        } else {
            Write-Warn 'The tunnel cannot be deleted from here. Delete it in the Cloudflare dashboard: Zero Trust -> Networks -> Tunnels.'
        }

        Write-Step 'Deleting the GADS database'
        $mongosh = Find-FarmTool -Command 'mongosh'
        if ($mongosh) {
            $r = Invoke-Native -File $mongosh -Arguments @('--quiet', 'mongodb://127.0.0.1:27017/gads', '--eval', 'db.dropDatabase()')
            if ($r.Code -eq 0) { Write-Ok 'Database "gads" dropped.' } else { Write-Warn 'mongosh could not drop the database "gads".' }
        } else {
            Write-Warn 'mongosh is not installed, so the database "gads" was NOT deleted. It holds the hub''s users and passwords. Either uninstall MongoDB and delete its data folder (C:\Program Files\MongoDB\Server\<version>\data), or install mongosh and run:  mongosh mongodb://127.0.0.1:27017/gads --eval "db.dropDatabase()"'
        }

        Write-Step 'Deleting C:\farm'
        if (Test-Path -LiteralPath $paths.Root) {
            Remove-Item -LiteralPath $paths.Root -Recurse -Force
            Write-Ok 'C:\farm deleted (secrets, tunnel credentials, pairings, logs).'
        }
    }

    Write-Step 'What is left, and how to remove it'
    if ($farm) {
        Write-Note ('DNS records at Cloudflare (dashboard -> your domain -> DNS): ' + $farm.hubHost + ', ' + $farm.providerHost + ', ' + $farm.restartHost)
        Write-Note 'The site in Blossom CRM: Phone Farm -> Farm setup -> Remove.'
    }
    if ($stillPaired -and $RemoveData) {
        Write-Note ('The pairing with Blossom (' + $pairing.AppOrigin + ') was not given up; its token went with C:\farm. Unless the farm moved to another computer, revoke it in Blossom: Phone Farm -> Farm setup -> the site -> Unpair computer.')
    } elseif ($stillPaired) {
        Write-Note ('The pairing with Blossom (' + $pairing.AppOrigin + ') was kept in C:\farm. To give it up:   scripts\uninstall.ps1 -Unpair')
    }
    Write-Note 'Programs (only if nothing else on this computer uses them):'
    foreach ($id in @('Cloudflare.cloudflared', 'Gyan.FFmpeg', 'OpenJS.NodeJS.LTS', 'NSSM.NSSM', 'MongoDB.Server', 'MongoDB.DatabaseTools')) {
        Write-Note ('   winget uninstall --id ' + $id)
    }
    Write-Note 'Sleep on mains power was switched off by install.ps1: Windows Settings -> System -> Power.'
    if (-not $RemoveData) { Write-Note 'C:\farm and the database were kept. Run install.ps1 to bring the farm back, or this script with -RemoveData to delete them.' }
    exit 0
}
catch { Write-FarmFailure -ErrorRecord $_; exit 1 }
