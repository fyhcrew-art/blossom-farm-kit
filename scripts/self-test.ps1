<#
.SYNOPSIS
    Runs the same checks as "Test connection" in Blossom CRM, from this
    computer, against the farm's public host names.
.DESCRIPTION
        powershell -ExecutionPolicy Bypass -File .\scripts\self-test.ps1
    Asks for the password of a hub user (hidden). Nothing is stored.
.PARAMETER HubUser
    Hub user to sign in with. Default: on a computer that is paired with
    Blossom, the hub administrator "admin" (the password of "blossom" went to
    Blossom and is stored nowhere on this computer); otherwise the user
    Blossom uses, "blossom".
#>
[CmdletBinding()]
param([string]$HubUser = '')

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

try {
    Assert-Administrator
    Protect-KitFolder -KitRoot $KitRoot
    $paths = Get-FarmPaths
    $farm = Read-FarmConfig -Paths $paths
    if (-not $farm) {
        Stop-Farm -Problem 'This computer has no farm installation (C:\farm\config\farm.json is missing).' -WhatToDo 'Run install.ps1 first.'
    }
    if (-not (Test-Path -LiteralPath $paths.RestartSecret)) {
        Stop-Farm -Problem 'The restart secret file is missing.' -WhatToDo 'Run scripts\rotate-secrets.ps1 -RestartSecret (on a computer that is not paired, enter the new secret in Blossom), then test again.'
    }
    if (-not $HubUser) {
        $HubUser = Get-SelfTestUser -Paths $paths -HubUser ([string]$farm.hubUser)
        if ($HubUser -ne [string]$farm.hubUser) {
            Write-Note ('The test signs in as "' + $HubUser + '", the hub administrator: this computer is paired, so the password of "' + [string]$farm.hubUser + '" went to Blossom and is not stored on this computer.')
        }
    }
    Write-Step ('Self-test of ' + $farm.hubHost + ', ' + $farm.providerHost + ', ' + $farm.restartHost)
    $password = ConvertFrom-SecureStringPlain -Secure (Read-Host -Prompt ('Password of the hub user "' + $HubUser + '" (hidden)') -AsSecureString)
    $secret = (Get-Content -LiteralPath $paths.RestartSecret -Raw).Trim()
    $steps = Invoke-FarmSelfTest -HubHost $farm.hubHost -ProviderHost $farm.providerHost -RestartHost $farm.restartHost -Nickname $farm.nickname -HubUser $HubUser -HubPassword $password -RestartSecret $secret
    $password = $null; $secret = $null
    $ok = Write-SelfTestReport -Steps $steps
    Write-Host ''
    if ($ok) {
        Write-Ok 'Everything that can be checked from this computer works. Now press "Test connection" in Blossom: that test runs from Blossom''s servers.'
        exit 0
    }
    Write-Warn 'At least one step failed. Fix the first failed step and run the test again.'
    exit 2
}
catch { Write-FarmFailure -ErrorRecord $_; exit 1 }
