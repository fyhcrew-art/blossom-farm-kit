<#
.SYNOPSIS
    Replaces secrets of the farm with new ones.
.DESCRIPTION
        powershell -ExecutionPolicy Bypass -File .\scripts\rotate-secrets.ps1 -RestartSecret
        powershell -ExecutionPolicy Bypass -File .\scripts\rotate-secrets.ps1 -HubUser
        powershell -ExecutionPolicy Bypass -File .\scripts\rotate-secrets.ps1 -AdminPassword
        powershell -ExecutionPolicy Bypass -File .\scripts\rotate-secrets.ps1 -All

    When somebody who had Phone Farm access in Blossom leaves: run it with
    -HubUser (and -AdminPassword if that person knew it). See docs\security.md.

    On a computer that is paired with Blossom, the new hub password and the
    new restart secret are sent to Blossom by this script (with the
    computer's farm token) and are not shown. Without a pairing, or when
    Blossom cannot be reached, they are shown once, to be entered in Blossom
    (Farm setup -> Edit), and written to no log.
.PARAMETER RestartSecret
    New restart secret.
.PARAMETER HubUser
    New random password for the hub user Blossom uses ("blossom").
.PARAMETER KeepAvailable
    New random password for the internal keep-available user (nothing to enter anywhere).
.PARAMETER AdminPassword
    Change the password of the hub administrator ("admin"); you choose it.
.PARAMETER All
    All of the above.
#>
[CmdletBinding()]
param([switch]$RestartSecret, [switch]$HubUser, [switch]$KeepAvailable, [switch]$AdminPassword, [switch]$All)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

$HubUrl = 'http://127.0.0.1:10000'
$newHubPassword = $null
$newRestartSecret = $null
$sentToBlossom = $false

function Show-New {
    if (-not $newHubPassword -and -not $newRestartSecret) { return }
    if ($sentToBlossom) { return }
    Write-Host ''
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host ' Enter these in Blossom CRM -> Phone Farm -> Farm setup -> Edit' -ForegroundColor Cyan
    Write-Host '======================================================================' -ForegroundColor Cyan
    if ($newHubPassword) { Write-Host ('   Hub user blossom, new hub password ... ' + $newHubPassword) }
    if ($newRestartSecret) { Write-Host ('   New restart secret ................... ' + $newRestartSecret) }
    Write-Host ''
    Write-Host ' WARNING: shown ONCE and written to no log. Until you enter them in Blossom,' -ForegroundColor Yellow
    Write-Host ' the site shows "Not reachable" there. The old values no longer work.' -ForegroundColor Yellow
    Write-Host ''
}

try {
    Assert-Administrator
    Protect-KitFolder -KitRoot $KitRoot
    if ($All) { $RestartSecret = $true; $HubUser = $true; $KeepAvailable = $true; $AdminPassword = $true }
    if (-not ($RestartSecret -or $HubUser -or $KeepAvailable -or $AdminPassword)) {
        Stop-Farm -Problem 'Nothing was chosen.' -WhatToDo 'Add -RestartSecret, -HubUser, -KeepAvailable, -AdminPassword or -All.'
    }
    $paths = Get-FarmPaths
    $farm = Read-FarmConfig -Paths $paths
    if (-not $farm) { Stop-Farm -Problem 'This computer has no farm installation.' -WhatToDo 'Run install.ps1 first.' }

    $adminToken = $null
    $adminCurrent = $null
    if ($HubUser -or $KeepAvailable -or $AdminPassword) {
        Write-Step 'Signing in to the hub as its administrator'
        $adminCurrent = ConvertFrom-SecureStringPlain -Secure (Read-Host -Prompt 'Current password of the hub user "admin" (hidden)' -AsSecureString)
        $adminToken = Connect-Hub -HubUrl $HubUrl -Username 'admin' -Password $adminCurrent
        if (-not $adminToken) {
            Stop-Farm -Problem 'The hub refused the administrator password.' -WhatToDo 'Run the script again with the right password. If it is lost, see README, section Troubleshooting, "Lost hub administrator password".'
        }
        Write-Ok 'Signed in.'
    }
    $auth = @{}
    if ($adminToken) { $auth = @{ Authorization = ('Bearer ' + $adminToken) } }

    if ($HubUser) {
        Write-Step 'New password for the hub user "blossom"'
        $candidate = New-RandomSecret -Bytes 32 -Format Base64Url
        $body = (@{ username = 'blossom'; password = $candidate; role = 'admin'; workspace_ids = @() } | ConvertTo-Json -Compress)
        $r = Invoke-FarmHttp -Url ($HubUrl + '/admin/user') -Method 'PUT' -Body $body -Headers $auth
        if ($r.Status -ne 200) {
            $r = Invoke-FarmHttp -Url ($HubUrl + '/admin/user') -Method 'POST' -Body $body -Headers $auth
        }
        if ($r.Status -ne 200) { Stop-Farm -Problem ('The hub did not update the user "blossom" (HTTP ' + $r.Status + ').') -WhatToDo 'Check Get-Service GadsHub and run the script again.' }
        $newHubPassword = $candidate
        Write-Ok 'Done. Sessions that were issued with the old password: see the note at the end.'
    }

    if ($KeepAvailable) {
        Write-Step 'New password for the internal user "farm-keepalive"'
        $r = Invoke-FarmHttp -Url ($HubUrl + '/admin/workspaces?page=1&limit=100') -Headers $auth
        $ids = @(@(Get-JsonProperty -Object (Get-JsonProperty -Object $r.Json -Name 'result') -Name 'workspaces') | Where-Object { $_ } | ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'id') } | Where-Object { $_ })
        if ($ids.Count -eq 0) { Stop-Farm -Problem 'The hub did not list its workspaces.' -WhatToDo 'Check Get-Service GadsHub and run the script again.' }
        $keep = New-RandomSecret -Bytes 32 -Format Base64Url
        $body = (@{ username = 'farm-keepalive'; password = $keep; role = 'user'; workspace_ids = $ids } | ConvertTo-Json -Compress)
        $r = Invoke-FarmHttp -Url ($HubUrl + '/admin/user') -Method 'PUT' -Body $body -Headers $auth
        if ($r.Status -ne 200) { $r = Invoke-FarmHttp -Url ($HubUrl + '/admin/user') -Method 'POST' -Body $body -Headers $auth }
        if ($r.Status -ne 200) { Stop-Farm -Problem ('The hub did not update the user "farm-keepalive" (HTTP ' + $r.Status + ').') -WhatToDo 'Run the script again.' }
        Write-SecretFile -Path $paths.KeepAvailable -Text (@{ hubUrl = $HubUrl; username = 'farm-keepalive'; password = $keep } | ConvertTo-Json)
        $keep = $null
        Restart-Service -Name 'KeepAvailable' -Force -ErrorAction SilentlyContinue
        Write-Ok 'Done, and the keep-available service was restarted. It now covers every workspace of the hub.'
    }

    if ($AdminPassword) {
        Write-Step 'New password for the hub administrator "admin"'
        Write-Note 'Rules: at least 14 characters, mixing three of lower case, upper case, digits, other characters.'
        $new = Read-FarmPassword -Prompt 'New hub administrator password'
        $body = (@{ current_password = $adminCurrent; new_password = $new } | ConvertTo-Json -Compress)
        $r = Invoke-FarmHttp -Url ($HubUrl + '/change-password') -Method 'POST' -Body $body -Headers $auth
        $new = $null
        if ($r.Status -ne 200) { Stop-Farm -Problem ('The hub did not change the administrator password (HTTP ' + $r.Status + ').') -WhatToDo 'The new password must differ from the current one. Run the script again.' }
        Write-Ok 'Done. Keep it in a password manager; it is stored nowhere on this computer except inside the hub''s database.'
    }
    $adminCurrent = $null

    if ($RestartSecret) {
        Write-Step 'New restart secret'
        $newRestartSecret = New-RandomSecret -Bytes 32 -Format Hex
        Write-SecretFile -Path $paths.RestartSecret -Text $newRestartSecret
        Restart-Service -Name 'FarmRestart' -Force -ErrorAction SilentlyContinue
        if (-not (Wait-TcpPort -Port 19999 -WaitSec 20)) {
            Write-Warn 'The restart service did not come back. Read C:\farm\logs\restart-server.log.'
        } else { Write-Ok 'Done, and the restart service was restarted with the new secret.' }
    }

    # Paired with Blossom: the new values go there with this computer's farm
    # token, and nobody has to copy them.
    if (($newHubPassword -or $newRestartSecret) -and (Read-FarmPairing -Paths $paths)) {
        Write-Step 'Blossom CRM'
        $secret = $null
        if (Test-Path -LiteralPath $paths.RestartSecret) { $secret = (Get-Content -LiteralPath $paths.RestartSecret -Raw).Trim() }
        $hubUserName = [string](Get-JsonProperty -Object $farm -Name 'hubUser')
        if (-not $hubUserName) { $hubUserName = 'blossom' }
        $sent = Send-FarmSite -Paths $paths -HubUrl ('https://' + $farm.hubHost) -ProviderUrl ('https://' + $farm.providerHost) -Nickname ([string]$farm.nickname) `
            -HubUser $hubUserName -HubPassword $newHubPassword -RestartUrl ('https://' + $farm.restartHost) -RestartSecret $secret
        $secret = $null
        if ($sent.Ok) {
            $sentToBlossom = $true
            Write-Ok ('Blossom (' + (Read-FarmPairing -Paths $paths).AppOrigin + ') received the new values through the pairing of this computer. Nothing has to be entered there, and they are not shown here.')
            if ($sent.NeedsConfirmation) { Write-Warn 'The site is waiting for an admin to confirm it in Blossom (Phone Farm -> Farm setup); until then Blossom does not use it.' }
        } else {
            Write-Warn ('The new values could not be sent to Blossom: ' + $sent.Message)
            Write-Warn 'They are shown below instead: enter them in Blossom by hand.'
        }
    }

    Show-New
    if ($HubUser -or $AdminPassword) {
        Write-Note 'About sessions already handed out: a browser that opened Phone Farm before the change holds a'
        Write-Note 'hub session token. In GADS 6.0.0 such a token stays valid until it expires, one hour after it'
        Write-Note 'was issued; a password change does not cancel it (docs\security.md). To cut every session'
        Write-Note 'at once, replace the signing key in the hub page (Admin -> Secret keys).'
    }
    exit 0
}
catch {
    Write-FarmFailure -ErrorRecord $_
    Show-New
    exit 1
}
