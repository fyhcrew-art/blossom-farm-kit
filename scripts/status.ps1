<#
.SYNOPSIS
    Shows the state of the farm on this computer: services, ports, versions.
.DESCRIPTION
        powershell -ExecutionPolicy Bypass -File .\scripts\status.ps1
        powershell -ExecutionPolicy Bypass -File .\scripts\status.ps1 -Logs
    Changes nothing. Prints no secrets.
.PARAMETER Logs
    Also print the last 15 lines of every service log.
#>
[CmdletBinding()]
param([switch]$Logs)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

try {
    Assert-Administrator
    $paths = Get-FarmPaths
    $farm = Read-FarmConfig -Paths $paths
    $problems = 0

    Write-Step 'Installation'
    if (-not $farm) {
        Write-Warn 'No installation record (C:\farm\config\farm.json). Run install.ps1.'
        $problems++
    } else {
        Write-Note ('Kit ' + $farm.kit + ', installed ' + $farm.installedAt)
        Write-Note ('Hub        https://' + $farm.hubHost)
        Write-Note ('Provider   https://' + $farm.providerHost + '   (nickname ' + $farm.nickname + ')')
        Write-Note ('Restart    https://' + $farm.restartHost)
    }

    Write-Step 'Windows services'
    foreach ($name in @('MongoDB', 'GadsHub', 'GadsProvider', 'FarmGate', 'KeepAvailable', 'FarmRestart', 'Cloudflared')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Warn ($name.PadRight(14) + ' not installed'); $problems++; continue }
        $startType = ''
        try { $startType = [string](Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $name + "'")).StartMode } catch { $startType = '?' }
        if ($svc.Status -eq 'Running') { Write-Ok ($name.PadRight(14) + ' Running   (start: ' + $startType + ')') }
        else { Write-Warn ($name.PadRight(14) + ' ' + $svc.Status + '   (start: ' + $startType + ')'); $problems++ }
    }

    Write-Step 'Ports (everything must listen on 127.0.0.1 only)'
    $ports = @(@(27017, 'MongoDB'), @(10000, 'GADS hub'), @(10001, 'GADS provider'), @(10002, 'provider gate'), @(19999, 'restart service'))
    foreach ($p in $ports) {
        $listeners = @()
        try { $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $p[0] -ErrorAction SilentlyContinue) } catch { $listeners = @() }
        if ($listeners.Count -eq 0) { Write-Warn (([string]$p[0]).PadRight(6) + $p[1] + ': nothing is listening'); $problems++; continue }
        $addresses = @($listeners | ForEach-Object { $_.LocalAddress } | Sort-Object -Unique)
        $outside = @($addresses | Where-Object { $_ -ne '127.0.0.1' -and $_ -ne '::1' })
        if ($outside.Count -gt 0) { Write-Warn (([string]$p[0]).PadRight(6) + $p[1] + ': listens on ' + ($addresses -join ', ') + ' - REACHABLE FROM YOUR NETWORK, see docs\security.md'); $problems++ }
        else { Write-Ok (([string]$p[0]).PadRight(6) + $p[1] + ': ' + ($addresses -join ', ')) }
    }

    Write-Step 'Local answers'
    $r = Invoke-FarmHttp -Url 'http://127.0.0.1:10000/health' -TimeoutSec 5
    if ($r.Status -eq 401 -or $r.Status -eq 200) { Write-Ok ('Hub answers (HTTP ' + $r.Status + ').') } else { Write-Warn ('Hub: HTTP ' + $r.Status + ' ' + $r.Error); $problems++ }
    $r = Invoke-FarmHttp -Url 'http://127.0.0.1:10002/devices' -TimeoutSec 5
    if ($r.Status -eq 401) { Write-Ok 'Provider gate answers and refuses a request without a token (401).' } else { Write-Warn ('Provider gate: HTTP ' + $r.Status + ' ' + $r.Error + ' (expected 401)'); $problems++ }
    $r = Invoke-FarmHttp -Url 'http://127.0.0.1:10001/info' -TimeoutSec 5
    if ($r.Status -eq 200) { Write-Ok 'Provider answers locally.' } else { Write-Warn ('Provider: HTTP ' + $r.Status + ' ' + $r.Error + '. Read C:\farm\logs\provider.log (docs\phones.md explains the WebDriverAgent message).'); $problems++ }
    $r = Invoke-FarmHttp -Url 'http://127.0.0.1:19999/status' -TimeoutSec 5
    if ($r.Status -eq 401) { Write-Ok 'Restart service answers and refuses a request without the secret (401).' } else { Write-Warn ('Restart service: HTTP ' + $r.Status + ' ' + $r.Error + ' (expected 401)'); $problems++ }

    Write-Step 'Programs'
    $installed = $null
    $installedFile = Join-Path $paths.Config 'versions.json'
    if (Test-Path -LiteralPath $installedFile) { $installed = Get-Content -LiteralPath $installedFile -Raw | ConvertFrom-Json }
    if ($installed) {
        foreach ($item in @(@($paths.HubExe, [string]$installed.gads.hubExeSha256, ('GADS hub ' + $installed.gads.version)), @($paths.ProviderExe, [string]$installed.gadsDrag.sha256, ('GADS provider ' + $installed.gadsDrag.version)))) {
            if (-not (Test-Path -LiteralPath $item[0])) { Write-Warn ($item[2] + ': file missing'); $problems++; continue }
            if ((Get-FileSha256 -Path $item[0]) -eq $item[1].ToLowerInvariant()) { Write-Ok ($item[2] + ': SHA-256 matches the pinned value') }
            else { Write-Warn ($item[2] + ': the file on disk does NOT match the pinned SHA-256'); $problems++ }
        }
    }
    foreach ($tool in @('node', 'ffmpeg', 'cloudflared', 'mongod')) {
        $where = Find-FarmTool -Command $tool
        if ($where) { Write-Ok ($tool.PadRight(12) + $where) } else { Write-Warn ($tool.PadRight(12) + 'not found'); $problems++ }
    }
    $drive = Get-PSDrive -Name 'C'
    if ($drive.Free -lt 5GB) { Write-Warn ('Only ' + [Math]::Round($drive.Free / 1GB, 1) + ' GB free on C:.'); $problems++ }
    else { Write-Ok ('' + [Math]::Round($drive.Free / 1GB) + ' GB free on C:.') }

    if ($Logs) {
        foreach ($log in @('hub.log', 'provider.log', 'provider-gate.log', 'keep-available.log', 'restart-server.log', 'cloudflared.log')) {
            $file = Join-Path $paths.Logs $log
            Write-Step ('Last lines of ' + $file)
            if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Tail 15 | ForEach-Object { Write-Host ('   ' + $_) } }
            else { Write-Note '(no such file yet)' }
        }
    }

    Write-Host ''
    if ($problems -eq 0) { Write-Ok 'No problem found on this computer. To test the public side: scripts\self-test.ps1'; exit 0 }
    Write-Warn ('' + $problems + ' point(s) need attention (marked [warn] above). README, section Troubleshooting, lists the usual causes.')
    exit 2
}
catch { Write-FarmFailure -ErrorRecord $_; exit 1 }
