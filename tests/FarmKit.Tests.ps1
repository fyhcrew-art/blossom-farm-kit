# Pester 5 tests for the pure functions of lib\FarmKit.psm1.
#   Invoke-Pester .\tests
# Runs on Windows PowerShell 5.1 (CI) and on PowerShell 7.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\FarmKit.psm1') -Force -DisableNameChecking
}

Describe 'New-RandomSecret' {
    It 'returns 64 hex characters for 32 bytes' {
        (New-RandomSecret -Bytes 32 -Format Hex) | Should -Match '^[0-9a-f]{64}$'
    }
    It 'returns URL-safe base64 without padding' {
        $s = New-RandomSecret -Bytes 32 -Format Base64Url
        $s | Should -Match '^[A-Za-z0-9_-]{43}$'
    }
    It 'never returns the same value twice' {
        $all = 1..200 | ForEach-Object { New-RandomSecret }
        ($all | Sort-Object -Unique).Count | Should -Be 200
    }
    It 'refuses fewer than 16 bytes' {
        { New-RandomSecret -Bytes 8 } | Should -Throw
    }
    It 'is long enough for the restart service (32 characters minimum)' {
        (New-RandomSecret).Length | Should -BeGreaterOrEqual 32
    }
}

Describe 'Test-PasswordStrength' {
    It 'accepts a long mixed password' {
        (Test-PasswordStrength -Password 'Violet-Tram-93-harbour').Count | Should -Be 0
    }
    It 'refuses <Password>' -ForEach @(
        @{ Password = '' }
        @{ Password = 'short1A!' }
        @{ Password = 'password' }
        @{ Password = 'Password12345!' }
        @{ Password = 'MyAdminLogin-2026' }
        @{ Password = 'alllowercaseletters' }
        @{ Password = 'aaaaaaaaaaaaaaA1!' }
        @{ Password = ' Violet-Tram-93-harbour' }
        @{ Password = 'farm-blossom-2026-xyz' }
    ) {
        (Test-PasswordStrength -Password $Password).Count | Should -BeGreaterThan 0
    }
    It 'refuses a password containing a forbidden word' {
        (Test-PasswordStrength -Password 'Violet-Tram-93-harbour' -Forbidden @('harbour')).Count | Should -BeGreaterThan 0
    }
}

Describe 'Test-FarmHostname' {
    It 'accepts <Name>' -ForEach @(
        @{ Name = 'farm-hub.yourdomain.com' }
        @{ Name = 'farm-provider.agency.co.uk' }
        @{ Name = 'a1.b2.io' }
    ) {
        Test-FarmHostname -Name $Name | Should -BeNullOrEmpty
    }
    It 'refuses <Name>' -ForEach @(
        @{ Name = '' }
        @{ Name = 'https://farm-hub.yourdomain.com' }
        @{ Name = 'farm-hub.yourdomain.com/path' }
        @{ Name = 'farm-hub.yourdomain.com:10000' }
        @{ Name = 'Farm-Hub.yourdomain.com' }
        @{ Name = 'yourdomain.com' }
        @{ Name = 'localhost' }
        @{ Name = '192.168.1.10' }
        @{ Name = 'farm.hub.local' }
        @{ Name = 'farm.hub.internal' }
        @{ Name = 'farm-hub.example.com' }
        @{ Name = '-farm.yourdomain.com' }
        @{ Name = 'farm_hub.yourdomain.com' }
        @{ Name = 'farm hub.yourdomain.com' }
        @{ Name = 'abc.cfargotunnel.com' }
        @{ Name = 'farm..yourdomain.com' }
    ) {
        Test-FarmHostname -Name $Name | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-FarmHostnameSet' {
    It 'accepts three different valid names' {
        (Test-FarmHostnameSet -Hub 'farm-hub.yourdomain.com' -Provider 'farm-provider.yourdomain.com' -Restart 'farm-restart.yourdomain.com').Count | Should -Be 0
    }
    It 'refuses the same name twice' {
        (Test-FarmHostnameSet -Hub 'farm.yourdomain.com' -Provider 'farm.yourdomain.com' -Restart 'farm-restart.yourdomain.com').Count | Should -BeGreaterThan 0
    }
    It 'names the field that is wrong' {
        $p = Test-FarmHostnameSet -Hub 'farm-hub.yourdomain.com' -Provider 'localhost' -Restart 'farm-restart.yourdomain.com'
        ($p -join ' ') | Should -Match 'Provider host name'
    }
}

Describe 'Test-ProviderNickname' {
    It 'accepts Provider1' { Test-ProviderNickname -Nickname 'Provider1' | Should -BeNullOrEmpty }
    It 'refuses <Nickname>' -ForEach @(
        @{ Nickname = '' }
        @{ Nickname = '1provider' }
        @{ Nickname = 'my provider' }
        @{ Nickname = 'a' }
        @{ Nickname = 'prov/../x' }
        @{ Nickname = 'prov"x' }
    ) {
        Test-ProviderNickname -Nickname $Nickname | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-PublicIpAddress' {
    It 'treats <Address> as public' -ForEach @(
        @{ Address = '104.16.0.1' }
        @{ Address = '8.8.8.8' }
        @{ Address = '2606:4700::1111' }
    ) {
        Test-PublicIpAddress -Address $Address | Should -BeTrue
    }
    It 'treats <Address> as not public' -ForEach @(
        @{ Address = '127.0.0.1' }
        @{ Address = '10.1.2.3' }
        @{ Address = '172.16.0.1' }
        @{ Address = '172.31.255.255' }
        @{ Address = '192.168.1.1' }
        @{ Address = '169.254.169.254' }
        @{ Address = '100.64.0.1' }
        @{ Address = '0.0.0.0' }
        @{ Address = '224.0.0.1' }
        @{ Address = '::1' }
        @{ Address = 'fe80::1' }
        @{ Address = 'fd00::1' }
        @{ Address = '::ffff:192.168.1.1' }
        @{ Address = 'not-an-address' }
    ) {
        Test-PublicIpAddress -Address $Address | Should -BeFalse
    }
}

Describe 'Get-CloudflaredConfigText' {
    BeforeAll {
        $script:yml = Get-CloudflaredConfigText -TunnelId '6FF42AE2-765D-4ADF-8112-31C55C1551EF' `
            -CredentialsFile 'C:\farm\config\cloudflared\tunnel-credentials.json' `
            -HubHost 'farm-hub.yourdomain.com' -ProviderHost 'farm-provider.yourdomain.com' -RestartHost 'farm-restart.yourdomain.com'
        $script:lines = $script:yml -split "`n"
    }
    It 'names the tunnel (lower case) and the credentials file' {
        $script:lines | Should -Contain 'tunnel: 6ff42ae2-765d-4adf-8112-31c55c1551ef'
        $script:lines | Should -Contain "credentials-file: 'C:\farm\config\cloudflared\tunnel-credentials.json'"
    }
    It 'sends the hub name to the hub port' {
        $i = [array]::LastIndexOf($script:lines, '  - hostname: farm-hub.yourdomain.com')
        $script:lines[$i + 1] | Should -Be '    service: http://127.0.0.1:10000'
    }
    It 'sends the provider name to the gate, never to the provider port' {
        $i = [array]::IndexOf($script:lines, '  - hostname: farm-provider.yourdomain.com')
        $script:lines[$i + 1] | Should -Be '    service: http://127.0.0.1:10002'
        $script:yml | Should -Not -Match '127\.0\.0\.1:10001'
    }
    It 'sends the restart name to the restart service' {
        $i = [array]::IndexOf($script:lines, '  - hostname: farm-restart.yourdomain.com')
        $script:lines[$i + 1] | Should -Be '    service: http://127.0.0.1:19999'
    }
    It 'refuses hub paths containing "appium" before the hub rule' {
        $block = [array]::IndexOf($script:lines, "    path: '(?i)appium'")
        $hub = [array]::LastIndexOf($script:lines, '  - hostname: farm-hub.yourdomain.com')
        $block | Should -BeGreaterThan 0
        $block | Should -BeLessThan $hub
        $script:lines[$block + 1] | Should -Be '    service: http_status:403'
    }
    It 'ends with the catch-all rule' {
        ($script:lines | Where-Object { $_ })[-1] | Should -Be '  - service: http_status:404'
    }
    It 'only ever points at this computer' {
        $services = $script:lines | Where-Object { $_ -match '^\s+service: http://' }
        $services.Count | Should -Be 3
        $services | ForEach-Object { $_ | Should -Match 'service: http://127\.0\.0\.1:\d+$' }
    }
    It 'uses LF line ends and no tabs' {
        $script:yml | Should -Not -Match "`r"
        $script:yml | Should -Not -Match "`t"
    }
    It 'refuses a tunnel id that is not a UUID' {
        { Get-CloudflaredConfigText -TunnelId 'blossom-farm' -CredentialsFile 'C:\x.json' -HubHost 'a.yourdomain.com' -ProviderHost 'b.yourdomain.com' -RestartHost 'c.yourdomain.com' } | Should -Throw
    }
    It 'refuses a host name that is not valid' {
        { Get-CloudflaredConfigText -TunnelId '6ff42ae2-765d-4adf-8112-31c55c1551ef' -CredentialsFile 'C:\x.json' -HubHost 'localhost' -ProviderHost 'b.yourdomain.com' -RestartHost 'c.yourdomain.com' } | Should -Throw
    }
    It 'escapes a quote in the credentials path' {
        $y = Get-CloudflaredConfigText -TunnelId '6ff42ae2-765d-4adf-8112-31c55c1551ef' -CredentialsFile "C:\o'brien\t.json" -HubHost 'a.yourdomain.com' -ProviderHost 'b.yourdomain.com' -RestartHost 'c.yourdomain.com'
        $y | Should -Match "credentials-file: 'C:\\o''brien\\t.json'"
    }
}

Describe 'Small helpers' {
    It 'Get-TunnelIdFromText finds a UUID' {
        Get-TunnelIdFromText -Text 'Created tunnel blossom-farm with id 6FF42AE2-765d-4adf-8112-31c55c1551ef' | Should -Be '6ff42ae2-765d-4adf-8112-31c55c1551ef'
        Get-TunnelIdFromText -Text 'no id here' | Should -BeNullOrEmpty
    }
    It 'Test-Sha256Text accepts only 64 hex characters' {
        Test-Sha256Text -Text ('a' * 64) | Should -BeTrue
        Test-Sha256Text -Text ('a' * 63) | Should -BeFalse
        Test-Sha256Text -Text '' | Should -BeFalse
        Test-Sha256Text -Text ('g' * 64) | Should -BeFalse
    }
    It 'ConvertTo-NssmArgument quotes only when needed and refuses quotes' {
        ConvertTo-NssmArgument -Value 'C:\farm\x.js' | Should -Be 'C:\farm\x.js'
        ConvertTo-NssmArgument -Value 'C:\Program Files\x.js' | Should -Be '"C:\Program Files\x.js"'
        { ConvertTo-NssmArgument -Value 'a"b' } | Should -Throw
    }
    It 'Test-LooksDown follows the product rule' {
        Test-LooksDown -Status 502 -Text '' | Should -BeTrue
        Test-LooksDown -Status 200 -Text '<!DOCTYPE html><html>' | Should -BeTrue
        Test-LooksDown -Status 401 -Text '{"error":"x"}' | Should -BeFalse
    }
    It 'Get-JsonProperty reads missing properties as null' {
        $o = '{"a":{"b":1}}' | ConvertFrom-Json
        Get-JsonProperty -Object (Get-JsonProperty -Object $o -Name 'a') -Name 'b' | Should -Be 1
        Get-JsonProperty -Object $o -Name 'missing' | Should -BeNullOrEmpty
        Get-JsonProperty -Object $null -Name 'a' | Should -BeNullOrEmpty
    }
}

Describe 'versions.json' {
    BeforeAll { $script:v = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\versions.json') -Raw | ConvertFrom-Json }
    It 'pins a SHA-256 for every downloaded program' {
        Test-Sha256Text -Text $script:v.gads.hubZipSha256 | Should -BeTrue
        Test-Sha256Text -Text $script:v.gads.hubExeSha256 | Should -BeTrue
        Test-Sha256Text -Text $script:v.gadsDrag.sha256 | Should -BeTrue
    }
    It 'downloads over https from the two expected places only' {
        $script:v.gads.hubZipUrl | Should -Match '^https://github\.com/shamanec/GADS/releases/download/'
        $script:v.gadsDrag.url | Should -Match '^https://github\.com/fyhcrew-art/blossom-farm-kit/releases/download/'
        $script:v.gadsDrag.url | Should -Match ([regex]::Escape($script:v.gadsDrag.releaseTag))
    }
    It 'pins an exact version for every winget package' {
        foreach ($p in $script:v.winget.PSObject.Properties) {
            $p.Value.id | Should -Match '^[A-Za-z0-9]+(\.[A-Za-z0-9]+)+$'
            $p.Value.version | Should -Match '^\d'
        }
    }
}
