<#
.SYNOPSIS
    Shows the state of the farm on this computer: services, ports, versions.
.DESCRIPTION
        powershell -ExecutionPolicy Bypass -File .\scripts\status.ps1
        powershell -ExecutionPolicy Bypass -File .\scripts\status.ps1 -Logs
    Changes nothing. Prints no password and no secret file.

    With -Logs it prints the last lines of the service logs. Those logs are
    written by the farm programs, and GADS writes the address of every request
    into them, which can include a hub session token (valid for up to an
    hour). This script masks tokens and the farm's host names before printing,
    so its output is what to copy when you ask for help. Do not post the log
    FILES themselves anywhere: they are not masked.
.PARAMETER Logs
    Also print the last 15 lines of every service log, with tokens and host
    names masked.
#>
[CmdletBinding()]
param([switch]$Logs)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

try {
    Assert-Administrator
    Protect-KitFolder -KitRoot $KitRoot
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

    Write-Step 'Pairing with Blossom CRM'
    $pairing = Read-FarmPairing -Paths $paths
    if (-not $pairing) {
        Write-Note 'Not paired: Blossom has the values that were entered there by hand, if any. To pair: where Blossom offers "Connect a computer" under Phone Farm -> Farm setup, it shows one command for this computer.'
    } else {
        $state = Get-FarmPairingStatus -Paths $paths
        $where = $pairing.AppOrigin
        if ($state.Workspace) { $where += ', workspace "' + $state.Workspace + '"' } elseif ($pairing.Workspace) { $where += ', workspace "' + $pairing.Workspace + '"' }
        if ($state.SiteLabel) { $where += ', site "' + $state.SiteLabel + '"' }
        if ($state.Ok -and $state.State -eq 'active') {
            Write-Ok ('Paired with ' + $where + '. The site is active.')
            $line = Get-PairingCheckText -Status $state
            if ($state.CheckOk -eq $false) { Write-Warn $line; $problems++ } elseif ($line) { Write-Ok $line }
        } elseif ($state.Ok -and $state.State -eq 'awaiting_confirmation') {
            Write-Warn ('Paired with ' + $where + ', but nobody has confirmed this computer in Blossom yet: open Phone Farm -> Farm setup there and confirm it. Until then Blossom does not use the farm.'); $problems++
        } elseif ($state.Ok -and $state.State -eq 'checking') {
            Write-Note ('Paired with ' + $where + '. Blossom is checking the farm right now.')
        } elseif ($state.Ok -and $state.State -eq 'installing') {
            Write-Warn ('Paired with ' + $where + ', but the farm was never sent to Blossom. Run install.ps1 to the end.'); $problems++
        } elseif ($state.Ok) {
            Write-Warn ('The pairing with ' + $where + ' was declined or ran out. ' + (Get-FarmPairHelp)); $problems++
        } elseif ($state.Kind -eq 'refused') {
            Write-Warn ('Paired with ' + $pairing.AppOrigin + ', but: ' + $state.Message + ' ' + (Get-FarmPairHelp)); $problems++
        } else {
            Write-Note ('Paired with ' + $where + '. Its state could not be asked right now: ' + $state.Message)
        }
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

    $appleService = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
    if (-not $appleService) {
        Write-Warn 'Apple Mobile Device Service: not installed. iPhones are only served while somebody is signed in to Windows (Microsoft Store app), or not at all. Install iTunes from Apple''s own installer (docs\phones.md, section 0).'; $problems++
    } elseif ($appleService.Status -ne 'Running') {
        Write-Warn ('Apple Mobile Device Service: ' + $appleService.Status + '. Start it:  Start-Service ''Apple Mobile Device Service'''); $problems++
    } else {
        Write-Ok 'Apple Mobile Device Service  Running   (Apple''s USB support for iPhones)'
    }

    Write-Step 'Fixed ports (each must listen on 127.0.0.1 only)'
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

    Write-Step 'Other ports opened by the farm programs, and the firewall'
    # For every iPhone the GADS provider opens ports (WebDriverAgent, the
    # screen stream) on ALL addresses of this computer, on numbers chosen at
    # run time; an Appium server does the same. None of them asks for a login.
    # The kit's Windows Firewall rules keep other computers away from them.
    $fw = Get-FarmFirewallState
    $fixed = @($ports | ForEach-Object { [int]$_[0] })
    $farmExe = @{}
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { @('GADS', 'GADS-drag', 'node', 'mongod', 'ffmpeg', 'cloudflared') -contains $_.ProcessName })) {
        $exe = ''
        try { $exe = [string]$proc.Path } catch { $exe = '' }
        $farmExe[[int]$proc.Id] = New-Object PSObject -Property @{ Name = $proc.ProcessName; Path = $exe }
    }
    $wide = @()
    try {
        $wide = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
                $farmExe.ContainsKey([int]$_.OwningProcess) -and ($fixed -notcontains [int]$_.LocalPort) -and $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1'
            })
    } catch { $wide = @() }
    $unprotected = 0
    foreach ($group in @($wide | Group-Object -Property OwningProcess)) {
        $info = $farmExe[[int]$group.Name]
        $portList = (@($group.Group | ForEach-Object { $_.LocalPort } | Sort-Object -Unique) -join ', ')
        $covered = ($fw.Available -and $info.Path -and ($fw.Programs -contains $info.Path.ToLowerInvariant()) -and $fw.ProfilesOff.Count -eq 0)
        if ($covered) {
            Write-Ok ($info.Name + ' listens on all addresses, port(s) ' + $portList + ' (per-phone ports): closed to other computers by the kit''s firewall rule.')
        } else {
            Write-Warn ($info.Name + ' listens on all addresses, port(s) ' + $portList + ', and no kit firewall rule covers it - OTHER COMPUTERS ON YOUR NETWORK MAY REACH THESE PORTS, see docs\security.md, section 1')
            $unprotected++; $problems++
        }
    }
    if ($wide.Count -eq 0) { Write-Ok 'No farm program listens on a network address right now (the provider opens its per-phone ports when phones are connected).' }
    if (-not $fw.Available) {
        Write-Warn 'Windows Firewall could not be asked (is another firewall product in charge?). Make sure it blocks incoming connections to this computer.'; $problems++
    } else {
        if ($fw.ProfilesOff.Count -gt 0) { Write-Warn ('Windows Firewall is switched OFF for: ' + ($fw.ProfilesOff -join ', ') + '. The kit''s rules do nothing while it is off (docs\security.md, section 1).'); $problems++ }
        else { Write-Ok 'Windows Firewall is on for all network types.' }
        if ($fw.Programs -contains $paths.ProviderExe.ToLowerInvariant()) { Write-Ok 'The kit''s firewall rule for the GADS provider is in place.' }
        else { Write-Warn 'The kit''s firewall rule for the GADS provider is missing. Run install.ps1 again (it recreates the rules).'; $problems++ }
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
        $hide = @()
        if ($farm) { $hide = @([string]$farm.hubHost, [string]$farm.providerHost, [string]$farm.restartHost) | Where-Object { $_ } }
        Write-Host ''
        Write-Host '   Below: the end of each log, with session tokens and your host names masked.' -ForegroundColor Yellow
        Write-Host '   When asking for help, copy THIS output. Never post a log file itself.' -ForegroundColor Yellow
        foreach ($log in @('hub.log', 'provider.log', 'provider-gate.log', 'keep-available.log', 'restart-server.log', 'cloudflared.log')) {
            $file = Join-Path $paths.Logs $log
            Write-Step ('Last lines of ' + $file)
            if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Tail 15 | ForEach-Object { Write-Host ('   ' + (Hide-LogSecret -Text ([string]$_) -Names $hide)) } }
            else { Write-Note '(no such file yet)' }
        }
    }

    Write-Host ''
    if ($problems -eq 0) { Write-Ok 'No problem found on this computer. To test the public side: scripts\self-test.ps1'; exit 0 }
    Write-Warn ('' + $problems + ' point(s) need attention (marked [warn] above). README, section Troubleshooting, lists the usual causes.')
    exit 2
}
catch { Write-FarmFailure -ErrorRecord $_; exit 1 }
