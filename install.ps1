<#
.SYNOPSIS
    Blossom farm kit - sets up a phone-farm computer from start to finish.

.DESCRIPTION
    Run from an Administrator PowerShell, inside the kit folder:

        powershell -ExecutionPolicy Bypass -File .\install.ps1

    The script can be run again at any time. It keeps what is already in place
    (programs, the tunnel, secrets, the database) and only fills in what is
    missing. See README.md for what each step does.

.PARAMETER HubHost
    Public host name for the hub, for example farm-hub.yourdomain.com.
.PARAMETER ProviderHost
    Public host name for the provider, for example farm-provider.yourdomain.com.
.PARAMETER RestartHost
    Public host name for the restart service, for example farm-restart.yourdomain.com.
.PARAMETER Nickname
    The provider's nickname in the hub (default Provider1).
.PARAMETER TunnelName
    Name of the Cloudflare tunnel to create (default blossom-farm).
.PARAMETER OverwriteDns
    Replace DNS records that already exist for the three host names.
.PARAMETER ResetHubUser
    Give the hub user "blossom" a new password even when the user exists.
.PARAMETER WithAppium
    Also install Appium and its iOS driver and let the provider start an
    Appium server per phone. No screen of Blossom CRM needs it (see README,
    "Appium: off unless you ask for it"). Once chosen it is remembered for
    later runs.
.PARAMETER SkipPowerSettings
    Do not switch off sleep on mains power.
.PARAMETER SkipSelfTest
    Do not run the connection test at the end.
#>
[CmdletBinding()]
param(
    [string]$HubHost = '',
    [string]$ProviderHost = '',
    [string]$RestartHost = '',
    [string]$Nickname = '',
    [string]$TunnelName = 'blossom-farm',
    [switch]$OverwriteDns,
    [switch]$ResetHubUser,
    [switch]$WithAppium,
    [switch]$SkipPowerSettings,
    [switch]$SkipSelfTest
)

$ErrorActionPreference = 'Stop'
$KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $KitRoot 'lib\FarmKit.psm1') -Force -DisableNameChecking

$FarmRoot = 'C:\farm'
$HubPort = 10000
$ProviderPort = 10001
$GatePort = 10002
$RestartPort = 19999
$MongoPort = 27017
$HubUrl = 'http://127.0.0.1:' + $HubPort
$HubUserName = 'blossom'
$KeepUserName = 'farm-keepalive'

# Secrets created in this run. They are printed once at the very end - also
# when a later step fails, so that a value the hub already holds is not lost.
$script:NewHubPassword = $null
$script:NewRestartSecret = $null
$script:Summary = $null

function Show-FinalValues {
    if (-not $script:Summary) { return }
    $s = $script:Summary
    Write-Host ''
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host ' Paste these into Blossom CRM -> Phone Farm -> Farm setup -> Connect a farm' -ForegroundColor Cyan
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host ('   Hub address ............ https://' + $s.HubHost)
    Write-Host ('   Provider address ....... https://' + $s.ProviderHost)
    Write-Host ('   Provider nickname ...... ' + $s.Nickname)
    Write-Host ('   Hub user ............... ' + $HubUserName)
    if ($script:NewHubPassword) {
        Write-Host ('   Hub password ........... ' + $script:NewHubPassword)
    } else {
        Write-Host '   Hub password ........... (unchanged - the one shown when it was created)'
    }
    Write-Host ('   Restart service address  https://' + $s.RestartHost)
    if ($script:NewRestartSecret) {
        Write-Host ('   Restart secret ......... ' + $script:NewRestartSecret)
    } else {
        Write-Host '   Restart secret ......... (unchanged - the one shown when it was created)'
    }
    Write-Host ''
    if ($script:NewHubPassword -or $script:NewRestartSecret) {
        Write-Host ' WARNING: the password and the secret above are shown ONCE.' -ForegroundColor Yellow
        Write-Host ' Copy them into Blossom now (or into a password manager), then close this' -ForegroundColor Yellow
        Write-Host ' window. They are not written to any log. Whoever has them controls your' -ForegroundColor Yellow
        Write-Host ' phones. Lost them? scripts\rotate-secrets.ps1 makes new ones.' -ForegroundColor Yellow
    } else {
        Write-Host ' Nothing secret was changed in this run. Lost a value? scripts\rotate-secrets.ps1' -ForegroundColor Yellow
        Write-Host ' makes new ones.' -ForegroundColor Yellow
    }
    Write-Host ''
}

function Read-HostName {
    param([string]$Prompt, [string]$Current, [string]$Example)
    while ($true) {
        $shown = $Example
        if ($Current) { $shown = $Current }
        $answer = Read-Host -Prompt ($Prompt + ' [' + $shown + ']')
        if (-not $answer -and $Current) { $answer = $Current }
        $answer = ([string]$answer).Trim().ToLowerInvariant()
        $answer = $answer -replace '^https://', '' -replace '/+$', ''
        $reason = Test-FarmHostname -Name $answer
        if (-not $reason) { return $answer }
        Write-Warn $reason
    }
}

function Invoke-HubAdmin {
    # A call to the local hub with the admin token; stops with a clear message
    # when the hub does not answer.
    param([string]$Path, [string]$Method = 'GET', [string]$Body = $null, [string]$Token)
    $r = Invoke-FarmHttp -Url ($HubUrl + $Path) -Method $Method -Body $Body -Headers @{ Authorization = ('Bearer ' + $Token) } -TimeoutSec 20
    if ($r.Status -eq 0) {
        Stop-Farm -Problem ('The GADS hub stopped answering (' + $r.Error + ').') -WhatToDo 'Read the end of C:\farm\logs\hub.log, check Get-Service GadsHub, MongoDB, then run install.ps1 again.'
    }
    return $r
}

try {
    Write-Host ''
    Write-Host 'Blossom farm kit - installer' -ForegroundColor Cyan
    Write-Host 'Safe to run again: it keeps what is already set up.'

    # ------------------------------------------------------------------
    Write-Step '1/12  Checking this computer'
    # ------------------------------------------------------------------
    Assert-Administrator
    if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        Stop-Farm -Problem ('PowerShell ' + $PSVersionTable.PSVersion + ' is too old.') -WhatToDo 'Use Windows 10 (version 1809 or later) or Windows 11, which include Windows PowerShell 5.1.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Stop-Farm -Problem 'This is a 32-bit Windows.' -WhatToDo 'The farm programs need 64-bit Windows 10 or 11 on a 64-bit (x64) processor.'
    }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        Stop-Farm -Problem ('This PowerShell runs as ' + $env:PROCESSOR_ARCHITECTURE + ', not as 64-bit x64.') -WhatToDo 'Start "Windows PowerShell" (not "Windows PowerShell (x86)") as Administrator. ARM computers are not supported by this kit: the GADS build it installs is for x64.'
    }
    $os = [Environment]::OSVersion.Version
    if ($os.Major -lt 10 -or $os.Build -lt 17763) {
        Stop-Farm -Problem ('Windows build ' + $os.Build + ' is too old.') -WhatToDo 'Update to Windows 10 version 1809 (build 17763) or later, or Windows 11.'
    }
    $drive = Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue
    if (-not $drive) {
        Stop-Farm -Problem 'There is no drive C:.' -WhatToDo 'The kit installs to C:\farm. Use a computer whose Windows drive is C:.'
    }
    if ($drive.Free -lt 10GB) {
        Stop-Farm -Problem ('Only ' + [Math]::Round($drive.Free / 1GB, 1) + ' GB free on C:.') -WhatToDo 'Free at least 10 GB (the programs, the database and the logs need room), then run the script again.'
    }
    foreach ($needed in @('versions.json', 'services\restart-server.js', 'services\provider-gate.js', 'services\keep-available.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $needed))) {
            Stop-Farm -Problem ('The kit is incomplete: ' + $needed + ' is missing.') -WhatToDo 'Download the complete kit again and run install.ps1 from inside the unpacked folder.'
        }
    }
    Get-ChildItem -LiteralPath $KitRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    $versions = Read-KitVersions -KitRoot $KitRoot
    $paths = Get-FarmPaths -Root $FarmRoot
    $previous = Read-FarmConfig -Paths $paths
    Write-Ok ('Windows build ' + $os.Build + ', 64-bit, ' + [Math]::Round($drive.Free / 1GB) + ' GB free, Administrator.')

    if (-not $Nickname) {
        $Nickname = 'Provider1'
        if ($previous -and (Get-JsonProperty -Object $previous -Name 'nickname')) { $Nickname = [string]$previous.nickname }
    }
    if (-not $WithAppium -and $previous -and ((Get-JsonProperty -Object $previous -Name 'withAppium') -eq $true)) { $WithAppium = $true }
    $reason = Test-ProviderNickname -Nickname $Nickname
    if ($reason) { Stop-Farm -Problem ('The provider nickname "' + $Nickname + '" cannot be used.') -WhatToDo $reason }

    # ------------------------------------------------------------------
    Write-Step '2/12  Folders'
    # ------------------------------------------------------------------
    foreach ($dir in @($paths.Root, $paths.Bin, $paths.Config, $paths.Logs, $paths.Services, $paths.Downloads, $paths.Cloudflared)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    # Everything under C:\farm (secrets, pairing records of the phones, the
    # tunnel credentials, logs) is for Administrators and SYSTEM only.
    Protect-FarmPath -Path $paths.Root
    foreach ($file in @('restart-server.js', 'provider-gate.js', 'keep-available.ps1')) {
        Copy-Item -LiteralPath (Join-Path $KitRoot ('services\' + $file)) -Destination (Join-Path $paths.Services $file) -Force
    }
    Copy-Item -LiteralPath (Join-Path $KitRoot 'versions.json') -Destination (Join-Path $paths.Config 'versions.json') -Force
    Write-Ok ($paths.Root + ' is ready and readable by Administrators and SYSTEM only.')

    # ------------------------------------------------------------------
    Write-Step '3/12  Programs (winget, pinned versions)'
    # ------------------------------------------------------------------
    $w = $versions.winget
    Install-WingetPackage -Id $w.nssm.id -Version $w.nssm.version -Command 'nssm' -What 'NSSM (runs programs as Windows services)'
    Install-WingetPackage -Id $w.mongodb.id -Version $w.mongodb.version -Command 'mongod' -What 'MongoDB (the database GADS uses)'
    Install-WingetPackage -Id $w.node.id -Version $w.node.version -Command 'node' -What 'Node.js (runs the restart service and the provider gate)'
    Install-WingetPackage -Id $w.ffmpeg.id -Version $w.ffmpeg.version -Command 'ffmpeg' -What 'FFmpeg (the provider encodes the live video with it)'
    Install-WingetPackage -Id $w.cloudflared.id -Version $w.cloudflared.version -Command 'cloudflared' -What 'cloudflared (the tunnel)'

    $nodeExe = Find-FarmTool -Command 'node'
    $ffmpegExe = Find-FarmTool -Command 'ffmpeg'
    $cloudflaredExe = Find-FarmTool -Command 'cloudflared'
    $nssmSource = Find-FarmTool -Command 'nssm'
    # A private copy of nssm.exe: the services keep working when the package
    # manager later moves or removes its own copy.
    if (-not (Test-Path -LiteralPath $paths.Nssm)) { Copy-Item -LiteralPath $nssmSource -Destination $paths.Nssm -Force }
    $nssm = $paths.Nssm

    $npmPrefix = Join-Path $paths.Root 'npm'
    $appiumHome = Join-Path $paths.Root 'appium'
    if ($WithAppium) {
        # Installed under C:\farm, not in a user profile: the provider runs as
        # a Windows service and must find Appium, its driver and its plugin.
        $npmCmd = Join-Path (Split-Path -Parent $nodeExe) 'npm.cmd'
        if (-not (Test-Path -LiteralPath $npmCmd)) {
            Stop-Farm -Problem 'npm was not found next to node.exe.' -WhatToDo 'Reinstall Node.js (winget uninstall --id OpenJS.NodeJS.LTS, then run install.ps1 again).'
        }
        foreach ($dir in @($npmPrefix, $appiumHome)) {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }
        $env:APPIUM_HOME = $appiumHome
        $env:NPM_CONFIG_PREFIX = $npmPrefix
        $env:Path = $npmPrefix + ';' + (Split-Path -Parent $nodeExe) + ';' + $env:Path
        $appiumCmd = Join-Path $npmPrefix 'appium.cmd'
        if (-not (Test-Path -LiteralPath $appiumCmd)) {
            Write-Note ('Installing Appium ' + $versions.npm.appium + ' (a few minutes)...')
            $r = Invoke-Native -File $npmCmd -Arguments @('install', '--global', '--prefix', $npmPrefix, '--no-fund', '--no-audit', ('appium@' + $versions.npm.appium))
            if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $appiumCmd)) {
                Stop-Farm -Problem ('npm could not install Appium: ' + (($r.Output | Select-Object -Last 3) -join ' ')) -WhatToDo 'Check the internet connection and run install.ps1 -WithAppium again. To continue without Appium, delete C:\farm\npm and run install.ps1 without -WithAppium.'
            }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $appiumHome 'node_modules\appium-xcuitest-driver'))) {
            Write-Note ('Installing the Appium XCUITest driver ' + $versions.npm.xcuitestDriver + '...')
            $r = Invoke-Native -File $appiumCmd -Arguments @('driver', 'install', '--source=npm', ('appium-xcuitest-driver@' + $versions.npm.xcuitestDriver))
            if ($r.Code -ne 0) {
                Stop-Farm -Problem ('Appium could not install its iOS driver: ' + (($r.Output | Select-Object -Last 3) -join ' ')) -WhatToDo 'Run install.ps1 -WithAppium again. If it repeats, report the text above on the kit repository.'
            }
        }
        Write-Ok ('Appium ' + $versions.npm.appium + ' with the XCUITest driver is installed under C:\farm.')
    }

    $apple = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
    $appleStore = $null
    try { $appleStore = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AppleInc.AppleDevices*' -or $_.Name -like 'AppleInc.iTunes*' } | Select-Object -First 1 } catch { $appleStore = $null }
    if ($apple -or $appleStore) {
        Write-Ok 'Apple''s USB support for iPhones is installed.'
    } else {
        Write-Warn 'Apple''s USB support for iPhones was not found. Install "Apple Devices" (or iTunes) from the Microsoft Store before plugging in phones - see docs\phones.md. The rest of the setup continues.'
    }

    # ------------------------------------------------------------------
    Write-Step '4/12  GADS (hub from its publisher, patched provider from this kit''s release)'
    # ------------------------------------------------------------------
    $hubZip = Join-Path $paths.Downloads 'gads-win.zip'
    $hubHash = ([string]$versions.gads.hubExeSha256).ToLowerInvariant()
    $providerHash = ([string]$versions.gadsDrag.sha256).ToLowerInvariant()
    $haveHub = (Test-Path -LiteralPath $paths.HubExe) -and ((Get-FileSha256 -Path $paths.HubExe) -eq $hubHash)
    $haveProvider = (Test-Path -LiteralPath $paths.ProviderExe) -and ((Get-FileSha256 -Path $paths.ProviderExe) -eq $providerHash)
    if (-not $haveHub) {
        Get-VerifiedDownload -Url $versions.gads.hubZipUrl -Sha256 $versions.gads.hubZipSha256 -OutFile $hubZip -What ('GADS ' + $versions.gads.version + ' for Windows (from github.com/shamanec/GADS)')
        $unpack = Join-Path $paths.Downloads 'gads-win'
        if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        Expand-Archive -LiteralPath $hubZip -DestinationPath $unpack -Force
        $unpacked = Join-Path $unpack 'GADS.exe'
        if (-not (Test-Path -LiteralPath $unpacked) -or ((Get-FileSha256 -Path $unpacked) -ne $hubHash)) {
            Stop-Farm -Problem 'GADS.exe inside the downloaded archive does not have the expected SHA-256.' -WhatToDo 'Do not use it. Delete C:\farm\downloads and run install.ps1 again; if it repeats, report it on the kit repository.'
        }
        if (Get-Service -Name 'GadsHub' -ErrorAction SilentlyContinue) { Stop-Service -Name 'GadsHub' -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
        Copy-Item -LiteralPath $unpacked -Destination $paths.HubExe -Force
        Remove-Item -LiteralPath $unpack -Recurse -Force
    }
    Write-Ok ('GADS hub ' + $versions.gads.version + ' in place, SHA-256 verified.')
    if (-not $haveProvider) {
        $tmpProvider = Join-Path $paths.Downloads 'GADS-drag.exe'
        Get-VerifiedDownload -Url $versions.gadsDrag.url -Sha256 $versions.gadsDrag.sha256 -OutFile $tmpProvider -What ('the patched GADS provider ' + $versions.gadsDrag.version)
        if (Get-Service -Name 'GadsProvider' -ErrorAction SilentlyContinue) { Stop-Service -Name 'GadsProvider' -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
        Copy-Item -LiteralPath $tmpProvider -Destination $paths.ProviderExe -Force
    }
    Write-Ok ('GADS provider ' + $versions.gadsDrag.version + ' in place, SHA-256 verified.')

    # ------------------------------------------------------------------
    Write-Step '5/12  MongoDB'
    # ------------------------------------------------------------------
    $mongo = Get-Service -Name 'MongoDB' -ErrorAction SilentlyContinue
    if (-not $mongo) {
        Stop-Farm -Problem 'MongoDB is installed but has no Windows service called "MongoDB".' -WhatToDo 'Uninstall MongoDB in Windows Settings -> Apps, then run install.ps1 again so that it installs MongoDB with its service.'
    }
    Set-Service -Name 'MongoDB' -StartupType Automatic
    if (-not (Start-FarmService -Name 'MongoDB' -WaitSec 60) -or -not (Wait-TcpPort -Port $MongoPort -WaitSec 60)) {
        Stop-Farm -Problem ('MongoDB does not start or does not listen on 127.0.0.1:' + $MongoPort + '.') -WhatToDo 'Open Event Viewer -> Windows Logs -> Application and read the MongoDB entries, or the log file named in mongod.cfg (under C:\Program Files\MongoDB\Server\<version>\bin). A frequent cause is a full disk.'
    }
    # GADS keeps its users and passwords in MongoDB without encryption, and
    # this MongoDB has no login: it must not listen on the network.
    $exposed = @()
    try { $exposed = @(Get-NetTCPConnection -State Listen -LocalPort $MongoPort -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' }) } catch { $exposed = @() }
    if ($exposed.Count -gt 0) {
        Stop-Farm -Problem ('MongoDB listens on ' + $exposed[0].LocalAddress + ', not only on this computer. Its data (hub passwords included) would be readable from the network.') -WhatToDo 'Open mongod.cfg (C:\Program Files\MongoDB\Server\<version>\bin), set   net: bindIp: 127.0.0.1   , restart the MongoDB service, then run install.ps1 again.'
    }
    Write-Ok ('MongoDB is running and listens on this computer only (127.0.0.1:' + $MongoPort + ').')

    # ------------------------------------------------------------------
    Write-Step '6/12  GADS hub service and its administrator password'
    # ------------------------------------------------------------------
    Set-FarmService -Nssm $nssm -Name 'GadsHub' -DisplayName 'Blossom farm - GADS hub' -Description 'GADS device-farm hub (Blossom farm kit).' `
        -Application $paths.HubExe -Parameters ('hub --host-address=127.0.0.1 --port=' + $HubPort + ' --mongo-db=127.0.0.1:' + $MongoPort) `
        -Directory $paths.Root -LogFile (Join-Path $paths.Logs 'hub.log') -DependsOn @('MongoDB')
    if (-not (Start-FarmService -Name 'GadsHub' -WaitSec 40) -or -not (Wait-TcpPort -Port $HubPort -WaitSec 60)) {
        Stop-Farm -Problem 'The GADS hub does not start.' -WhatToDo 'Read the end of C:\farm\logs\hub.log. If it says the port is in use, another program occupies port 10000: stop it, then run install.ps1 again.'
    }
    Write-Ok ('The hub is running on this computer only (' + $HubUrl + ').')

    # GADS creates its administrator as "admin" with a published default
    # password. Nothing is opened to the internet while that is still valid.
    # This literal is GADS' own published default (its hub prints it at start).
    # It is only used here to detect and replace it; the kit never sets it.
    $defaultPassword = 'password'
    $adminToken = Connect-Hub -HubUrl $HubUrl -Username 'admin' -Password $defaultPassword
    $adminPassword = $null
    if ($adminToken) {
        if (Get-Service -Name 'Cloudflared' -ErrorAction SilentlyContinue) {
            Stop-Service -Name 'Cloudflared' -Force -ErrorAction SilentlyContinue
            Write-Warn 'The tunnel was stopped: the hub administrator still had the default password.'
        }
        Write-Host ''
        Write-Host '   The hub''s administrator is called "admin" and still has the default' -ForegroundColor Yellow
        Write-Host '   password that everybody can look up. Choose a new one now. You will use' -ForegroundColor Yellow
        Write-Host '   it to sign in to the hub''s own page; keep it in a password manager.' -ForegroundColor Yellow
        Write-Host '   Rules: at least 14 characters, mixing three of lower case, upper case,' -ForegroundColor Yellow
        Write-Host '   digits, other characters. Typing is hidden.' -ForegroundColor Yellow
        $adminPassword = Read-FarmPassword -Prompt 'New hub administrator password'
        $body = (@{ current_password = $defaultPassword; new_password = $adminPassword } | ConvertTo-Json -Compress)
        $r = Invoke-HubAdmin -Path '/change-password' -Method 'POST' -Body $body -Token $adminToken
        if ($r.Status -ne 200) {
            Stop-Farm -Problem ('The hub did not accept the new administrator password (HTTP ' + $r.Status + ').') -WhatToDo 'Run install.ps1 again. Nothing has been opened to the internet.'
        }
        if (Connect-Hub -HubUrl $HubUrl -Username 'admin' -Password $defaultPassword) {
            Stop-Farm -Problem 'The default administrator password still works after changing it.' -WhatToDo 'Do not continue. Run install.ps1 again; if this repeats, report it on the kit repository. Nothing has been opened to the internet.'
        }
        $adminToken = Connect-Hub -HubUrl $HubUrl -Username 'admin' -Password $adminPassword
        if (-not $adminToken) {
            Stop-Farm -Problem 'The hub does not accept the new administrator password.' -WhatToDo 'Run install.ps1 again. Nothing has been opened to the internet.'
        }
        Write-Ok 'The default administrator password is gone.'
    } else {
        Write-Note 'The hub administrator password was already changed. Enter it to continue (typing is hidden).'
        $attempts = 0
        while (-not $adminToken) {
            $attempts++
            if ($attempts -gt 5) {
                Stop-Farm -Problem 'The hub refused the administrator password five times.' -WhatToDo 'Find the password of the hub user "admin" (the one chosen at the first installation). If it is lost for good, see README, section Troubleshooting, "Lost hub administrator password".'
            }
            $adminPassword = ConvertFrom-SecureStringPlain -Secure (Read-Host -Prompt 'Hub administrator password (user admin)' -AsSecureString)
            $adminToken = Connect-Hub -HubUrl $HubUrl -Username 'admin' -Password $adminPassword
            if (-not $adminToken) { Write-Warn 'The hub refused that password.' }
        }
        Write-Ok 'Signed in to the hub as its administrator.'
    }

    # ------------------------------------------------------------------
    Write-Step '7/12  Hub users and the provider'
    # ------------------------------------------------------------------
    # The default workspace (new phones land there).
    $r = Invoke-HubAdmin -Path '/admin/workspaces?page=1&limit=100' -Token $adminToken
    $workspaces = @(Get-JsonProperty -Object (Get-JsonProperty -Object $r.Json -Name 'result') -Name 'workspaces')
    $workspaceIds = @($workspaces | Where-Object { $_ } | ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'id') } | Where-Object { $_ })
    if ($r.Status -ne 200 -or $workspaceIds.Count -eq 0) {
        Stop-Farm -Problem ('The hub did not list its workspaces (HTTP ' + $r.Status + ').') -WhatToDo 'Restart the hub (Restart-Service GadsHub), wait a minute and run install.ps1 again.'
    }

    # "blossom": the login Blossom CRM uses. Admin role, because the product
    # reads the device register and that needs it.
    $r = Invoke-HubAdmin -Path '/admin/users' -Token $adminToken
    $users = @(Get-JsonProperty -Object $r.Json -Name 'result')
    $userNames = @($users | Where-Object { $_ } | ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'username') })
    $hubUserExists = ($userNames -contains $HubUserName)
    $setHubUser = $true
    if ($hubUserExists -and -not $ResetHubUser) { $setHubUser = $false }
    if ($setHubUser) {
        $candidate = New-RandomSecret -Bytes 32 -Format Base64Url
        $body = (@{ username = $HubUserName; password = $candidate; role = 'admin'; workspace_ids = @() } | ConvertTo-Json -Compress)
        if ($hubUserExists) {
            $r = Invoke-HubAdmin -Path '/admin/user' -Method 'PUT' -Body $body -Token $adminToken
        } else {
            $r = Invoke-HubAdmin -Path '/admin/user' -Method 'POST' -Body $body -Token $adminToken
            if ($r.Status -eq 400 -and $r.Text -match '(?i)already exists') {
                # the user list did not show it, but the hub has it
                if ($ResetHubUser) { $r = Invoke-HubAdmin -Path '/admin/user' -Method 'PUT' -Body $body -Token $adminToken }
                else { $setHubUser = $false }
            }
        }
        if ($setHubUser -and $r.Status -ne 200) {
            Stop-Farm -Problem ('The hub did not create or update the user "' + $HubUserName + '" (HTTP ' + $r.Status + ').') -WhatToDo 'Run install.ps1 again. If it repeats, create the user by hand in the hub page (Admin -> Users, role admin) and run install.ps1 once more.'
        }
        if ($setHubUser) {
            $script:NewHubPassword = $candidate
            Write-Ok ('Hub user "' + $HubUserName + '" has a new random password (shown at the end).')
        }
        $candidate = $null
    }
    if (-not $setHubUser) {
        Write-Ok ('Hub user "' + $HubUserName + '" exists; its password is left as it is (-ResetHubUser makes a new one).')
    }

    # "farm-keepalive": the login of the keep-available service. Plain user
    # role, new random password on every run (nobody needs to know it).
    $keepPassword = New-RandomSecret -Bytes 32 -Format Base64Url
    $body = (@{ username = $KeepUserName; password = $keepPassword; role = 'user'; workspace_ids = $workspaceIds } | ConvertTo-Json -Compress)
    $r = Invoke-HubAdmin -Path '/admin/user' -Method 'PUT' -Body $body -Token $adminToken
    if ($r.Status -ne 200) { $r = Invoke-HubAdmin -Path '/admin/user' -Method 'POST' -Body $body -Token $adminToken }
    if ($r.Status -ne 200) {
        Stop-Farm -Problem ('The hub did not create or update the user "' + $KeepUserName + '" (HTTP ' + $r.Status + ').') -WhatToDo 'Run install.ps1 again.'
    }
    $keepConfig = (@{ hubUrl = $HubUrl; username = $KeepUserName; password = $keepPassword } | ConvertTo-Json)
    Write-SecretFile -Path $paths.KeepAvailable -Text $keepConfig
    $keepPassword = $null
    Write-Ok ('Hub user "' + $KeepUserName + '" (role user) is set up for the keep-available service.')

    # The provider's record in the hub. iOS is switched on later, in the hub
    # page, once a signed WebDriverAgent has been uploaded (docs\phones.md):
    # a provider with iOS on and no WebDriverAgent refuses to start.
    $r = Invoke-HubAdmin -Path '/admin/providers' -Token $adminToken
    $providers = @(Get-JsonProperty -Object $r.Json -Name 'result')
    $providerNames = @($providers | Where-Object { $_ } | ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'nickname') })
    if ($providerNames -contains $Nickname) {
        $mine = $providers | Where-Object { $_ -and (Get-JsonProperty -Object $_ -Name 'nickname') -eq $Nickname } | Select-Object -First 1
        $existingPort = Get-JsonProperty -Object $mine -Name 'port'
        $existingHost = [string](Get-JsonProperty -Object $mine -Name 'host_address')
        if ([int]$existingPort -ne $ProviderPort -or ($existingHost -ne '127.0.0.1' -and $existingHost -ne 'localhost')) {
            Stop-Farm -Problem ('The hub already has a provider "' + $Nickname + '" on ' + $existingHost + ':' + $existingPort + '. This kit needs it on 127.0.0.1:' + $ProviderPort + '.') -WhatToDo ('In the hub page (Admin -> Providers) set its host address to 127.0.0.1 and its port to ' + $ProviderPort + ', or run install.ps1 -Nickname <another name>.')
        }
        if ($WithAppium -and ((Get-JsonProperty -Object $mine -Name 'setup_appium_servers') -ne $true)) {
            if ($mine.PSObject.Properties['setup_appium_servers']) { $mine.setup_appium_servers = $true }
            else { $mine | Add-Member -NotePropertyName 'setup_appium_servers' -NotePropertyValue $true }
            $r = Invoke-HubAdmin -Path '/admin/providers/update' -Method 'POST' -Body ($mine | ConvertTo-Json -Compress -Depth 6) -Token $adminToken
            if ($r.Status -eq 200) { Write-Ok ('Provider "' + $Nickname + '" now sets up Appium servers.') }
            else { Write-Warn ('The hub did not switch Appium on for the provider (HTTP ' + $r.Status + '). Do it in the hub page: Admin -> Providers -> "Set up Appium servers".') }
        }
        Write-Ok ('Provider "' + $Nickname + '" exists in the hub.')
    } else {
        $body = (@{
                os = 'windows'; nickname = $Nickname; host_address = '127.0.0.1'; port = $ProviderPort
                provide_ios = $false; provide_android = $false; setup_appium_servers = [bool]$WithAppium; use_gads_ios_stream = $false
                wda_bundle_id = ''
            } | ConvertTo-Json -Compress)
        $r = Invoke-HubAdmin -Path '/admin/providers/add' -Method 'POST' -Body $body -Token $adminToken
        if ($r.Status -ne 200) {
            Stop-Farm -Problem ('The hub did not create the provider "' + $Nickname + '" (HTTP ' + $r.Status + ').') -WhatToDo 'Run install.ps1 again. If it repeats, create it in the hub page: Admin -> Providers -> New provider, OS windows, host address 127.0.0.1, port 10001.'
        }
        Write-Ok ('Provider "' + $Nickname + '" created in the hub (127.0.0.1:' + $ProviderPort + ', iOS to be switched on after WebDriverAgent is uploaded).')
    }

    # ------------------------------------------------------------------
    Write-Step '8/12  Public host names'
    # ------------------------------------------------------------------
    Write-Note 'Three host names under a domain that you own and that uses Cloudflare for its DNS.'
    Write-Note 'Use direct sub-domains (farm-hub.yourdomain.com), not deeper ones (hub.farm.yourdomain.com):'
    Write-Note 'Cloudflare''s free certificate covers one level only.'
    $prevHub = ''; $prevProvider = ''; $prevRestart = ''
    if ($previous) {
        $prevHub = [string](Get-JsonProperty -Object $previous -Name 'hubHost')
        $prevProvider = [string](Get-JsonProperty -Object $previous -Name 'providerHost')
        $prevRestart = [string](Get-JsonProperty -Object $previous -Name 'restartHost')
    }
    if (-not $HubHost) { $HubHost = Read-HostName -Prompt 'Host name for the hub' -Current $prevHub -Example 'farm-hub.yourdomain.com' }
    if (-not $ProviderHost) { $ProviderHost = Read-HostName -Prompt 'Host name for the provider' -Current $prevProvider -Example 'farm-provider.yourdomain.com' }
    if (-not $RestartHost) { $RestartHost = Read-HostName -Prompt 'Host name for the restart service' -Current $prevRestart -Example 'farm-restart.yourdomain.com' }
    $HubHost = $HubHost.Trim().ToLowerInvariant(); $ProviderHost = $ProviderHost.Trim().ToLowerInvariant(); $RestartHost = $RestartHost.Trim().ToLowerInvariant()
    $problems = Test-FarmHostnameSet -Hub $HubHost -Provider $ProviderHost -Restart $RestartHost
    if ($problems.Count -gt 0) {
        Stop-Farm -Problem ('The host names cannot be used: ' + ($problems -join ' ')) -WhatToDo 'Run install.ps1 again and enter three different names such as farm-hub.yourdomain.com, farm-provider.yourdomain.com, farm-restart.yourdomain.com.'
    }
    Write-Ok ($HubHost + ', ' + $ProviderHost + ', ' + $RestartHost)

    # ------------------------------------------------------------------
    Write-Step '9/12  Cloudflare tunnel'
    # ------------------------------------------------------------------
    $certProtected = Join-Path $paths.Cloudflared 'cert.pem'
    $certDefault = Join-Path (Join-Path $env:USERPROFILE '.cloudflared') 'cert.pem'
    $credFile = Join-Path $paths.Cloudflared 'tunnel-credentials.json'
    $tunnelId = $null
    if (Test-Path -LiteralPath $credFile) {
        try { $tunnelId = Get-TunnelIdFromText -Text ([string](Get-JsonProperty -Object (Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json) -Name 'TunnelID')) } catch { $tunnelId = $null }
    }
    $routesDone = $false
    if ($tunnelId -and $previous -and -not $OverwriteDns) {
        $routesDone = ((Get-JsonProperty -Object $previous -Name 'tunnelId') -eq $tunnelId) -and ($prevHub -eq $HubHost) -and ($prevProvider -eq $ProviderHost) -and ($prevRestart -eq $RestartHost) -and ((Get-JsonProperty -Object $previous -Name 'routesCreated') -eq $true)
    }

    if (-not $routesDone) {
        if (-not (Test-Path -LiteralPath $certProtected)) {
            if (-not (Test-Path -LiteralPath $certDefault)) {
                Write-Host ''
                Write-Host '   A browser window opens now (or an address is printed: open it in any browser).' -ForegroundColor Yellow
                Write-Host '   Sign in to Cloudflare, choose the domain of your host names, press Authorize.' -ForegroundColor Yellow
                Write-Host '   No Cloudflare account yet? See docs\network.md first, then run install.ps1 again.' -ForegroundColor Yellow
                Write-Host ''
                & $cloudflaredExe tunnel login
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $certDefault)) {
                    Stop-Farm -Problem 'The Cloudflare sign-in did not finish.' -WhatToDo 'Run install.ps1 again and complete the sign-in in the browser within a few minutes. The domain must already be added to your Cloudflare account (docs\network.md).'
                }
            }
            # The account certificate can create and delete tunnels and DNS
            # records. It is moved out of the user profile into the protected folder.
            Move-Item -LiteralPath $certDefault -Destination $certProtected -Force
            Protect-FarmPath -Path $certProtected
        }
        $env:TUNNEL_ORIGIN_CERT = $certProtected

        if (-not $tunnelId) {
            $r = Invoke-Native -File $cloudflaredExe -Arguments @('tunnel', 'create', '--credentials-file', $credFile, $TunnelName)
            if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $credFile)) {
                $text = ($r.Output -join ' ')
                if ($text -match '(?i)already exists') {
                    Stop-Farm -Problem ('Your Cloudflare account already has a tunnel called "' + $TunnelName + '", but its credentials are not on this computer.') -WhatToDo ('Either delete that tunnel in the Cloudflare dashboard (Zero Trust -> Networks -> Tunnels) and run install.ps1 again, or run   install.ps1 -TunnelName ' + $TunnelName + '-2   . When moving a farm to a new computer use scripts\export-farm.ps1 and scripts\import-farm.ps1 instead.')
                }
                Stop-Farm -Problem ('cloudflared could not create the tunnel: ' + $text) -WhatToDo 'Check the internet connection and that the Cloudflare sign-in was done with an account that may manage the domain, then run install.ps1 again.'
            }
            Protect-FarmPath -Path $credFile
            $tunnelId = Get-TunnelIdFromText -Text ([string](Get-JsonProperty -Object (Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json) -Name 'TunnelID'))
            if (-not $tunnelId) {
                Stop-Farm -Problem 'The tunnel was created but its credentials file has no tunnel id.' -WhatToDo 'Delete C:\farm\config\cloudflared\tunnel-credentials.json, delete the tunnel in the Cloudflare dashboard, and run install.ps1 again.'
            }
            Write-Ok ('Tunnel "' + $TunnelName + '" created.')
        } else {
            Write-Ok 'The tunnel of the earlier installation is reused.'
        }

        foreach ($name in @($HubHost, $ProviderHost, $RestartHost)) {
            $routeArgs = @('tunnel', 'route', 'dns')
            if ($OverwriteDns) { $routeArgs += '--overwrite-dns' }
            $routeArgs += @($tunnelId, $name)
            $r = Invoke-Native -File $cloudflaredExe -Arguments $routeArgs
            $text = ($r.Output -join ' ')
            if ($r.Code -ne 0 -and $text -notmatch '(?i)already configured to route to your tunnel') {
                if ($text -match '(?i)already exists') {
                    Stop-Farm -Problem ('A DNS record for ' + $name + ' already exists in your Cloudflare zone.') -WhatToDo ('If the name is free to use for the farm, run   install.ps1 -OverwriteDns   (it replaces the record). Otherwise choose another name.')
                }
                Stop-Farm -Problem ('cloudflared could not create the DNS record for ' + $name + ': ' + $text) -WhatToDo 'Check that the name belongs to the domain you authorised in the Cloudflare sign-in. To sign in again, delete C:\farm\config\cloudflared\cert.pem and run install.ps1 again.'
            }
        }
        Write-Ok 'DNS records created for the three host names.'
    } else {
        Write-Ok 'Tunnel and DNS records are already in place.'
    }
    Remove-Item Env:\TUNNEL_ORIGIN_CERT -ErrorAction SilentlyContinue

    $yml = Get-CloudflaredConfigText -TunnelId $tunnelId -CredentialsFile $credFile -HubHost $HubHost -ProviderHost $ProviderHost -RestartHost $RestartHost -HubPort $HubPort -GatePort $GatePort -RestartPort $RestartPort
    Write-TextFileUtf8 -Path $paths.CloudflaredYml -Text $yml
    $r = Invoke-Native -File $cloudflaredExe -Arguments @('tunnel', '--config', $paths.CloudflaredYml, 'ingress', 'validate')
    if ($r.Code -ne 0) {
        Stop-Farm -Problem ('cloudflared does not accept the tunnel configuration: ' + ($r.Output -join ' ')) -WhatToDo 'This is a fault in the kit, not in your setup: report it on the kit repository with the text above.'
    }
    Write-Ok ('Tunnel configuration written and validated (' + $paths.CloudflaredYml + ').')

    # the non-secret record of this installation
    $record = @{
        kit = [string]$versions.kit; installedAt = (Get-Date).ToString('s')
        nickname = $Nickname; hubHost = $HubHost; providerHost = $ProviderHost; restartHost = $RestartHost
        hubUser = $HubUserName; tunnelName = $TunnelName; tunnelId = $tunnelId; routesCreated = $true
        gads = [string]$versions.gads.version; gadsDrag = [string]$versions.gadsDrag.version
        withAppium = [bool]$WithAppium
    }
    Write-TextFileUtf8 -Path $paths.FarmJson -Text ($record | ConvertTo-Json)

    # ------------------------------------------------------------------
    Write-Step '10/12  Restart secret'
    # ------------------------------------------------------------------
    $haveSecret = $false
    if (Test-Path -LiteralPath $paths.RestartSecret) {
        $existingSecret = (Get-Content -LiteralPath $paths.RestartSecret -Raw)
        if ($existingSecret -and $existingSecret.Trim().Length -ge 32) { $haveSecret = $true }
        $existingSecret = $null
    }
    if ($haveSecret) {
        Write-Ok 'The restart secret of the earlier installation is kept.'
    } else {
        $script:NewRestartSecret = New-RandomSecret -Bytes 32 -Format Hex
        Write-SecretFile -Path $paths.RestartSecret -Text $script:NewRestartSecret
        Write-Ok 'A new random restart secret was generated (256 bits, shown at the end).'
    }
    $script:Summary = New-Object PSObject -Property @{ HubHost = $HubHost; ProviderHost = $ProviderHost; RestartHost = $RestartHost; Nickname = $Nickname }

    # ------------------------------------------------------------------
    Write-Step '11/12  Windows services'
    # ------------------------------------------------------------------
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $providerFolder = Join-Path $paths.Root $Nickname
    $providerEnv = @()
    if ($WithAppium) {
        $providerEnv += ('PATH=' + $npmPrefix + ';' + (Split-Path -Parent $nodeExe) + ';' + (Split-Path -Parent $ffmpegExe) + ';' + $machinePath)
        $providerEnv += ('APPIUM_HOME=' + $appiumHome)
        $providerEnv += ('NPM_CONFIG_PREFIX=' + $npmPrefix)
    } else {
        $providerEnv += ('PATH=' + (Split-Path -Parent $ffmpegExe) + ';' + $machinePath)
    }

    Set-FarmService -Nssm $nssm -Name 'GadsProvider' -DisplayName 'Blossom farm - GADS provider' -Description 'GADS device-farm provider, patched build (Blossom farm kit).' `
        -Application $paths.ProviderExe -Parameters ('provider --nickname=' + $Nickname + ' --hub=' + $HubUrl + ' --mongo-db=127.0.0.1:' + $MongoPort + ' --provider-folder=' + (ConvertTo-NssmArgument -Value $providerFolder) + ' --use-ios-pair-cache') `
        -Directory $paths.Root -LogFile (Join-Path $paths.Logs 'provider.log') -DependsOn @('GadsHub') -Environment $providerEnv

    Set-FarmService -Nssm $nssm -Name 'FarmGate' -DisplayName 'Blossom farm - provider gate' -Description 'Lets only requests with a valid hub token through to the GADS provider (Blossom farm kit).' `
        -Application $nodeExe -Parameters (ConvertTo-NssmArgument -Value (Join-Path $paths.Services 'provider-gate.js')) `
        -Directory $paths.Services -LogFile (Join-Path $paths.Logs 'provider-gate.log') `
        -Environment @(('FARM_GATE_PORT=' + $GatePort), ('FARM_GATE_HUB_PORT=' + $HubPort), ('FARM_GATE_PROVIDER_PORT=' + $ProviderPort))

    Set-FarmService -Nssm $nssm -Name 'KeepAvailable' -DisplayName 'Blossom farm - keep-available' -Description 'Keeps the GADS hub accepting commands (Blossom farm kit).' `
        -Application (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -Parameters ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-NssmArgument -Value (Join-Path $paths.Services 'keep-available.ps1'))) `
        -Directory $paths.Services -LogFile (Join-Path $paths.Logs 'keep-available.log') -DependsOn @('GadsHub')

    Set-FarmService -Nssm $nssm -Name 'FarmRestart' -DisplayName 'Blossom farm - restart service' -Description 'Lets Blossom CRM show and restart the farm programs; protected by the restart secret (Blossom farm kit).' `
        -Application $nodeExe -Parameters (ConvertTo-NssmArgument -Value (Join-Path $paths.Services 'restart-server.js')) `
        -Directory $paths.Services -LogFile (Join-Path $paths.Logs 'restart-server.log') `
        -Environment @(('GADS_RESTART_SECRET_FILE=' + $paths.RestartSecret), ('GADS_RESTART_PORT=' + $RestartPort))

    Set-FarmService -Nssm $nssm -Name 'Cloudflared' -DisplayName 'Blossom farm - Cloudflare tunnel' -Description 'cloudflared tunnel for the farm host names (Blossom farm kit).' `
        -Application $cloudflaredExe -Parameters ('tunnel --no-autoupdate --config ' + (ConvertTo-NssmArgument -Value $paths.CloudflaredYml) + ' run') `
        -Directory $paths.Cloudflared -LogFile (Join-Path $paths.Logs 'cloudflared.log') -DelayedStart

    # The tunnel is started last, and only now: the default password is gone,
    # the provider sits behind its gate, the restart service has its secret.
    $started = @()
    foreach ($name in @('GadsHub', 'GadsProvider', 'FarmGate', 'KeepAvailable', 'FarmRestart', 'Cloudflared')) {
        if (Start-FarmService -Name $name -WaitSec 40) { $started += $name }
        else { Write-Warn ('The service ' + $name + ' did not reach "Running" within 40 seconds. See C:\farm\logs.') }
    }
    foreach ($check in @(@($GatePort, 'provider gate', 'provider-gate.log'), @($RestartPort, 'restart service', 'restart-server.log'))) {
        if (-not (Wait-TcpPort -Port $check[0] -WaitSec 20)) {
            Stop-Farm -Problem ('The ' + $check[1] + ' does not listen on 127.0.0.1:' + $check[0] + '.') -WhatToDo ('Read the end of C:\farm\logs\' + $check[2] + ', then run install.ps1 again.')
        }
    }
    if (-not (Wait-TcpPort -Port $ProviderPort -WaitSec 30)) {
        Write-Warn 'The GADS provider is not listening yet. Read C:\farm\logs\provider.log; the self-test below will say more.'
    }
    # Nothing of the farm may listen on the network: everything is reached
    # through the tunnel, which connects outwards.
    $open = @()
    try { $open = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { @($HubPort, $ProviderPort, $GatePort, $RestartPort) -contains $_.LocalPort -and $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' }) } catch { $open = @() }
    if ($open.Count -gt 0) {
        Stop-Service -Name 'Cloudflared' -Force -ErrorAction SilentlyContinue
        Stop-Farm -Problem ('Port ' + $open[0].LocalPort + ' listens on ' + $open[0].LocalAddress + ', which other computers on your network can reach. The tunnel was stopped.') -WhatToDo 'If it is the provider port: open the hub page (Admin -> Providers) and set the host address to 127.0.0.1. Then run install.ps1 again.'
    }
    Write-Ok ('Services installed and set to start with Windows: ' + ($started -join ', ') + '.')

    if (-not $SkipPowerSettings) {
        $null = Invoke-Native -File 'powercfg.exe' -Arguments @('/change', 'standby-timeout-ac', '0')
        $null = Invoke-Native -File 'powercfg.exe' -Arguments @('/change', 'hibernate-timeout-ac', '0')
        Write-Ok 'Sleep and hibernation on mains power are switched off (a sleeping computer is an offline farm).'
    }

    # ------------------------------------------------------------------
    Write-Step '12/12  Self-test (the same checks as "Test connection" in Blossom)'
    # ------------------------------------------------------------------
    if ($SkipSelfTest) {
        Write-Note 'Skipped. Run scripts\self-test.ps1 later.'
    } else {
        $testUser = 'admin'; $testPassword = $adminPassword
        if ($script:NewHubPassword) { $testUser = $HubUserName; $testPassword = $script:NewHubPassword }
        else { Write-Note ('The test signs in as "admin": the password of "' + $HubUserName + '" is not stored on this computer.') }
        $restartSecret = (Get-Content -LiteralPath $paths.RestartSecret -Raw).Trim()
        $allOk = $false
        for ($try = 1; $try -le 6 -and -not $allOk; $try++) {
            if ($try -gt 1) { Write-Note ('Not everything answers yet (new DNS records and a new tunnel need a moment). Trying again in 20 seconds (' + $try + ' of 6)...'); Start-Sleep -Seconds 20 }
            $steps = Invoke-FarmSelfTest -HubHost $HubHost -ProviderHost $ProviderHost -RestartHost $RestartHost -Nickname $Nickname -HubUser $testUser -HubPassword $testPassword -RestartSecret $restartSecret
            $failed = @($steps | Where-Object { $_.State -eq 'fail' })
            $allOk = ($failed.Count -eq 0)
        }
        $restartSecret = $null
        $null = Write-SelfTestReport -Steps $steps
        if ($allOk) {
            Write-Ok 'The farm answers on its public addresses. ("CHECK" on Phones is expected until phones are added.)'
        } else {
            Write-Warn 'The self-test did not pass. The setup itself is complete; fix what the failed step says, then run scripts\self-test.ps1.'
            Write-Warn 'This test ran from this computer. "Test connection" in Blossom runs from Blossom''s servers and is the one that counts.'
        }
    }
    $adminPassword = $null

    Show-FinalValues
    Write-Host 'Next: prepare the phones - docs\phones.md. Then press "Test connection" in Blossom.' -ForegroundColor Cyan
    Write-Host ''
    exit 0
}
catch {
    Write-FarmFailure -ErrorRecord $_
    if ($script:NewHubPassword -or $script:NewRestartSecret) {
        Write-Host 'The script stopped, but it had already created new secrets. They are shown' -ForegroundColor Yellow
        Write-Host 'below so that they are not lost. Running install.ps1 again keeps them.' -ForegroundColor Yellow
        if (-not $script:Summary) {
            if ($script:NewHubPassword) { Write-Host ('   Hub user ' + $HubUserName + ', hub password: ' + $script:NewHubPassword) }
            if ($script:NewRestartSecret) { Write-Host ('   Restart secret: ' + $script:NewRestartSecret) }
            Write-Host ''
        } else {
            Show-FinalValues
        }
    }
    exit 1
}
