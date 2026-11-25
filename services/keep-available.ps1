# Blossom farm kit - keep-available.
#
# A GADS hub only marks a phone "available" while somebody is subscribed to its
# stream of available devices (the hub's own web page does that while it is
# open). A farm that is driven through Blossom CRM has nobody sitting on that
# page, and the hub then answers every tap with 422 "device is not available".
# This script stays subscribed, for every workspace its hub user can see.
#
# - Talks to the hub on this computer (http://127.0.0.1:<port>), never through
#   the public tunnel.
# - Reads the hub address and its own hub login from a file that only
#   Administrators and SYSTEM can read. Nothing secret is passed on a command
#   line or written to the log.
# - Its hub login is a dedicated user with the plain "user" role (not admin).
# - Reconnects with a growing pause (2 s up to 60 s) when the hub is away.
#
# Runs as the Windows service "KeepAvailable" (created by install.ps1).
# Windows PowerShell 5.1.

param(
    [string]$ConfigFile = 'C:\farm\config\keep-available.json',
    [string]$LogFolder = 'C:\farm\logs'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Write-Log {
    param([string]$Text)
    # Straight to standard output (the service wrapper writes it to the log
    # file); not Write-Output, which would become part of a function's result.
    [Console]::Out.WriteLine((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' [keep-available] ' + $Text)
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw ('Configuration file not found: ' + $ConfigFile + '. Run install.ps1 (or scripts\rotate-secrets.ps1 -KeepAvailable) to create it.')
    }
    $c = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    if (-not $c.hubUrl -or -not $c.username -or -not $c.password) {
        throw ('The configuration file ' + $ConfigFile + ' must contain hubUrl, username and password.')
    }
    $uri = [Uri]$c.hubUrl
    if ($uri.Scheme -ne 'http' -or ($uri.Host -ne '127.0.0.1' -and $uri.Host -ne 'localhost')) {
        throw 'hubUrl must be the hub on this computer, for example http://127.0.0.1:10000 (not the public address).'
    }
    return $c
}

function Get-HubToken {
    param($Client, $Config)
    $body = (@{ username = [string]$Config.username; password = [string]$Config.password } | ConvertTo-Json -Compress)
    $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
    $response = $Client.PostAsync(($Config.hubUrl.TrimEnd('/') + '/authenticate'), $content).GetAwaiter().GetResult()
    try {
        if (-not $response.IsSuccessStatusCode) { return $null }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ($json.result -and $json.result.access_token) { return [string]$json.result.access_token }
        if ($json.access_token) { return [string]$json.access_token }
        return $null
    } finally { $response.Dispose() }
}

function Get-WorkspaceIds {
    param($Client, $Config, [string]$Token)
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, ($Config.hubUrl.TrimEnd('/') + '/workspaces?page=1&limit=100'))
    $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)
    $response = $Client.SendAsync($request).GetAwaiter().GetResult()
    try {
        if (-not $response.IsSuccessStatusCode) { return @() }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $list = $json.result
        if ($list -and ($list.PSObject.Properties['workspaces'])) { $list = $list.workspaces }
        $ids = @()
        foreach ($w in @($list)) {
            if ($null -eq $w) { continue }
            if ($w.PSObject.Properties['id'] -and $w.id) { $ids += [string]$w.id }
            elseif ($w.PSObject.Properties['_id'] -and $w._id) { $ids += [string]$w._id }
        }
        return $ids
    } finally { $response.Dispose() }
}

function Remove-OldLogs {
    # nssm rotates the service logs into dated files; keep 30 days of them.
    if (-not (Test-Path -LiteralPath $LogFolder)) { return }
    $limit = (Get-Date).AddDays(-30)
    Get-ChildItem -LiteralPath $LogFolder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit -and $_.Name -match '-\d{8}T\d{6}\.\d{3}\.log$' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# One pass: sign in, find the workspaces, hold one stream per workspace until
# one of them ends or the list of workspaces is due for a refresh.
function Invoke-Subscription {
    param($Config)
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false           # the hub is on this computer
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $responses = @()
    $streams = @()
    try {
        $token = Get-HubToken -Client $client -Config $Config
        if (-not $token) { Write-Log 'the hub refused the login of the keep-available user'; return $false }
        $ids = @(Get-WorkspaceIds -Client $client -Config $Config -Token $token)
        if ($ids.Count -eq 0) { Write-Log 'the keep-available user sees no workspace'; return $false }

        foreach ($id in $ids) {
            $url = $Config.hubUrl.TrimEnd('/') + '/available-devices?workspaceId=' + [Uri]::EscapeDataString($id)
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
            $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $responses += $response
            if (-not $response.IsSuccessStatusCode) { Write-Log ('the hub answered HTTP ' + [int]$response.StatusCode + ' for a workspace stream'); return $false }
            $streams += $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        }
        Write-Log ('subscribed to ' + $ids.Count + ' workspace(s)')

        $buffers = @()
        $tasks = New-Object 'System.Threading.Tasks.Task[]' $streams.Count
        for ($i = 0; $i -lt $streams.Count; $i++) {
            $buffers += , (New-Object byte[] 65536)
            $tasks[$i] = $streams[$i].ReadAsync($buffers[$i], 0, 65536)
        }
        $refreshAt = (Get-Date).AddMinutes(15)   # new workspaces, and before the token gets old
        $lastData = Get-Date
        while ((Get-Date) -lt $refreshAt) {
            $index = [System.Threading.Tasks.Task]::WaitAny($tasks, 5000)
            if ($index -lt 0) {
                # the hub writes every second; a long silence means a dead connection
                if (((Get-Date) - $lastData).TotalSeconds -gt 60) { Write-Log 'no data for 60 s, reconnecting'; return $false }
                continue
            }
            $task = $tasks[$index]
            if ($task.IsFaulted -or $task.IsCanceled) { Write-Log 'a stream broke, reconnecting'; return $false }
            if ($task.Result -le 0) { Write-Log 'the hub closed a stream, reconnecting'; return $false }
            $lastData = Get-Date
            $tasks[$index] = $streams[$index].ReadAsync($buffers[$index], 0, 65536)
        }
        return $true   # planned refresh
    } finally {
        foreach ($s in $streams) { try { $s.Dispose() } catch { } }
        foreach ($r in $responses) { try { $r.Dispose() } catch { } }
        $client.Dispose()
    }
}

Write-Log 'starting'
$pause = 2
$lastCleanup = [DateTime]::MinValue
while ($true) {
    $ok = $false
    try {
        if (((Get-Date) - $lastCleanup).TotalHours -ge 24) { Remove-OldLogs; $lastCleanup = Get-Date }
        $config = Read-Config
        $ok = Invoke-Subscription -Config $config
    } catch {
        # Only the message: never the configuration, a token or a password.
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        Write-Log ('error: ' + $inner.Message)
    }
    if ($ok) { $pause = 2 } else { $pause = [Math]::Min($pause * 2, 60) }
    Start-Sleep -Seconds $pause
}
