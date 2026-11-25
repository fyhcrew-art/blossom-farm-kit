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
    # the nickname becomes a folder below the farm folder, on a disk that does
    # not tell upper case from lower case
    It 'refuses the kit''s own folder name <Nickname>' -ForEach @(
        @{ Nickname = 'logs' }
        @{ Nickname = 'Logs' }
        @{ Nickname = 'CONFIG' }
        @{ Nickname = 'Services' }
        @{ Nickname = 'bin' }
        @{ Nickname = 'export-stage' }
    ) {
        Test-ProviderNickname -Nickname $Nickname | Should -Match 'a folder the kit itself uses'
    }
    It 'accepts a name that only starts like one' { Test-ProviderNickname -Nickname 'Services2' | Should -BeNullOrEmpty }
}

Describe 'Test-KitFolderPlace (the kit''s scripts run as Administrator: nobody else may change them)' {
    It 'accepts <Folder>' -ForEach @(
        @{ Folder = 'C:\blossom-farm-kit' }
        @{ Folder = 'C:\blossom-farm-kit\' }
        @{ Folder = 'D:\kit' }
    ) {
        Test-KitFolderPlace -KitRoot $Folder | Should -BeNullOrEmpty
    }
    It 'refuses <Folder>' -ForEach @(
        @{ Folder = 'C:\Users\ada\Downloads\blossom-farm-kit' }
        @{ Folder = 'C:\Users\ada\blossom-farm-kit' }
        @{ Folder = 'C:\' }
        @{ Folder = '\\server\share\blossom-farm-kit' }
        @{ Folder = '' }
    ) {
        Test-KitFolderPlace -KitRoot $Folder | Should -Match 'not directly on a drive'
    }
    It 'is asked by the installer and by every script before anything else' {
        $root = Join-Path $PSScriptRoot '..'
        foreach ($file in @('install.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' | ForEach-Object { 'scripts\' + $_.Name })) {
            $text = Get-Content -LiteralPath (Join-Path $root $file) -Raw
            $text | Should -Match 'Assert-Administrator\s+Protect-KitFolder -KitRoot \$KitRoot' -Because $file
        }
    }
}

Describe 'Invoke-FarmSelfTest against stand-in answers' {
    BeforeAll {
        # The mocks run inside the module: what a test wants from them is said
        # through an environment variable.
        $env:FARMKIT_TEST_MODE = 'good'
        Mock -ModuleName FarmKit Resolve-FarmHostName { return @('104.16.0.1') }
        Mock -ModuleName FarmKit Invoke-FarmHttp {
            $mode = $env:FARMKIT_TEST_MODE
            $status = 200
            $json = New-Object PSObject
            if ($Url -like '*/authenticate') {
                if ($mode -eq 'badlogin') { $status = 401 } else { $json = ('{"result":{"access_token":"tok"}}' | ConvertFrom-Json) }
            } elseif ($Url -like '*/admin/devices') {
                $json = ('{"result":{"devices":[{"udid":"U1"}]}}' | ConvertFrom-Json)
            } elseif ($Url -like '*appium*' -or $Url -like '*/admin/provider/*/info') {
                $status = 403
            } elseif ($Url -like '*/provider-update') {
                $status = 403
                if ($mode -eq 'no-update-rule') { $status = 404 }
            } elseif ($Url -like 'https://p.yourdomain.com/devices') {
                $status = 401
            }
            return New-Object PSObject -Property @{ Status = $status; Text = '{}'; Json = $json; Error = $null; Challenge = $false; ErrorKind = $null; RetryAfter = $null }
        }
        function Invoke-TestSelfTest {
            param([string]$HubUser = 'blossom')
            return @(Invoke-FarmSelfTest -HubHost 'h.yourdomain.com' -ProviderHost 'p.yourdomain.com' -RestartHost 'r.yourdomain.com' -Nickname 'Provider1' -HubUser $HubUser -HubPassword 'pw' -RestartSecret 'secret')
        }
    }
    AfterAll { Remove-Item Env:\FARMKIT_TEST_MODE -ErrorAction SilentlyContinue }

    It 'checks all three paths the tunnel must refuse' {
        $env:FARMKIT_TEST_MODE = 'good'
        $steps = Invoke-TestSelfTest
        foreach ($id in @('hub-appium', 'hub-provider-info', 'hub-provider-update')) {
            ($steps | Where-Object { $_.Id -eq $id }).State | Should -BeExactly 'ok' -Because $id
        }
        Should -Invoke -ModuleName FarmKit Invoke-FarmHttp -ParameterFilter { $Url -eq 'https://h.yourdomain.com/provider-update' -and (-not $Headers -or -not $Headers.ContainsKey('Authorization')) }
    }
    It 'fails when only the /provider-update rule is missing from the tunnel' {
        $env:FARMKIT_TEST_MODE = 'no-update-rule'
        $steps = Invoke-TestSelfTest
        $step = $steps | Where-Object { $_.Id -eq 'hub-provider-update' }
        $step.State | Should -BeExactly 'fail'
        $step.Detail | Should -Match '/provider-update is not refused by the tunnel \(HTTP 404\)'
        ($steps | Where-Object { $_.Id -eq 'hub-appium' }).State | Should -BeExactly 'ok'
    }
    It 'tells a refused login of Blossom''s user from a refused administrator password' {
        $env:FARMKIT_TEST_MODE = 'badlogin'
        $step = (Invoke-TestSelfTest -HubUser 'blossom') | Where-Object { $_.Id -eq 'signin' }
        $step.State | Should -BeExactly 'fail'
        $step.Detail | Should -Match 'the user "blossom"'
        $step.Fix | Should -Match 'self-test\.ps1 -HubUser admin'
        $step = (Invoke-TestSelfTest -HubUser 'admin') | Where-Object { $_.Id -eq 'signin' }
        $step.Detail | Should -Match 'its administrator'
        $step.Fix | Should -Not -Match 'rotate-secrets'
    }
    It 'has a title for every step' {
        $env:FARMKIT_TEST_MODE = 'good'
        Mock -ModuleName FarmKit Write-Host { }
        $null = Write-SelfTestReport -Steps (Invoke-TestSelfTest)
        Should -Invoke -ModuleName FarmKit Write-Host -ParameterFilter { [string]$Object -match 'Hub refuses reports from outside: ' }
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
    It 'refuses the hub path that serves the provider record without a login, before the hub rule' {
        $block = [array]::IndexOf($script:lines, "    path: '^/admin/provider/[^/]+/info'")
        $hub = [array]::LastIndexOf($script:lines, '  - hostname: farm-hub.yourdomain.com')
        $block | Should -BeGreaterThan 0
        $block | Should -BeLessThan $hub
        $script:lines[$block - 1] | Should -Be '  - hostname: farm-hub.yourdomain.com'
        $script:lines[$block + 1] | Should -Be '    service: http_status:403'
        '/admin/provider/Provider1/info' | Should -Match '^/admin/provider/[^/]+/info'
        '/admin/providers' | Should -Not -Match '^/admin/provider/[^/]+/info'
        '/admin/providers/logs' | Should -Not -Match '^/admin/provider/[^/]+/info'
    }
    It 'has three refusal rules on the hub name and none on the others' {
        @($script:lines | Where-Object { $_ -eq '    service: http_status:403' }).Count | Should -Be 3
        @($script:lines | Where-Object { $_ -eq '  - hostname: farm-hub.yourdomain.com' }).Count | Should -Be 4
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

Describe 'Hide-LogSecret' {
    It 'masks a session token in a request address, as GADS logs it' {
        $line = '[GIN] 2026/01/01 - 10:00:00 | 101 | 12m3s | 127.0.0.1 | GET      "/device/00008030-AAAA/ios-webrtc?token=eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoiYiJ9.c2lnbmF0dXJl"'
        $out = Hide-LogSecret -Text $line
        $out | Should -Not -Match 'eyJ'
        $out | Should -Match 'ios-webrtc\?token=<hidden>'
        $out | Should -Match '^\[GIN\] 2026/01/01'
    }
    It 'masks the token wherever it stands in the query, and keeps the other parameters' {
        Hide-LogSecret -Text 'GET "/devices/control/x/lock?ttl_minutes=5&token=abc.def-123&x=1"' | Should -Be 'GET "/devices/control/x/lock?ttl_minutes=5&token=<hidden>&x=1"'
    }
    It 'masks a bare JWT and a bearer header' {
        Hide-LogSecret -Text 'token eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoiYiJ9.c2ln was refused' | Should -Be 'token <hidden-token> was refused'
        Hide-LogSecret -Text 'Authorization: Bearer 0123456789abcdef0123456789abcdef' | Should -Be 'Authorization: Bearer <hidden>'
    }
    It 'masks the given host names, in any letter case' {
        Hide-LogSecret -Text 'connected to Farm-Hub.yourdomain.com and farm-restart.yourdomain.com' -Names @('farm-hub.yourdomain.com', 'farm-restart.yourdomain.com') |
            Should -Be 'connected to <host-name> and <host-name>'
    }
    It 'leaves an ordinary line and an empty line alone' {
        Hide-LogSecret -Text 'provider started on 127.0.0.1:10001' | Should -Be 'provider started on 127.0.0.1:10001'
        Hide-LogSecret -Text '' | Should -Be ''
    }
}

Describe 'ConvertTo-WingetVersion' {
    It 'reads <Text> as <Want>' -ForEach @(
        @{ Text = 'v1.9.25200'; Want = '1.9' }
        @{ Text = 'v1.3.2691'; Want = '1.3' }
        @{ Text = 'v1.4.3531-preview'; Want = '1.4' }
        @{ Text = '1.12.350'; Want = '1.12' }
    ) {
        (ConvertTo-WingetVersion -Text $Text).ToString() | Should -Be $Want
    }
    It 'knows that 1.3 is older than 1.4 and 1.12 is newer' {
        (ConvertTo-WingetVersion -Text 'v1.3.2691') -lt (New-Object System.Version(1, 4)) | Should -BeTrue
        (ConvertTo-WingetVersion -Text 'v1.12.350') -ge (New-Object System.Version(1, 4)) | Should -BeTrue
    }
    It 'returns nothing for text without a version' {
        ConvertTo-WingetVersion -Text 'not recognized' | Should -BeNullOrEmpty
        ConvertTo-WingetVersion -Text '' | Should -BeNullOrEmpty
    }
}

Describe 'Protect-NativeArgument (Windows PowerShell 5.1 quoting)' {
    It 'doubles the backslashes at the end of a value with spaces' {
        Protect-NativeArgument -PSMajor 5 -Value 'PATH=C:\Program Files\nodejs;C:\Program Files (x86)\cloudflared\' | Should -Be 'PATH=C:\Program Files\nodejs;C:\Program Files (x86)\cloudflared\\'
        Protect-NativeArgument -PSMajor 5 -Value 'C:\My Folder\\' | Should -Be 'C:\My Folder\\\\'
    }
    It 'leaves a value without spaces, or without a backslash at the end, as it is' {
        Protect-NativeArgument -PSMajor 5 -Value 'C:\farm\bin\' | Should -Be 'C:\farm\bin\'
        Protect-NativeArgument -PSMajor 5 -Value 'C:\Program Files\nodejs' | Should -Be 'C:\Program Files\nodejs'
        Protect-NativeArgument -PSMajor 5 -Value '' | Should -Be ''
    }
    It 'changes nothing on PowerShell 7, which does this itself' {
        Protect-NativeArgument -PSMajor 7 -Value 'C:\My Folder\' | Should -Be 'C:\My Folder\'
    }
}

Describe 'ConvertTo-PathList' {
    It 'drops empty entries and the backslash at the end of an entry' {
        ConvertTo-PathList -Path 'C:\Windows\system32;;C:\Program Files\nodejs\; C:\Program Files (x86)\cloudflared\;' |
            Should -Be 'C:\Windows\system32;C:\Program Files\nodejs;C:\Program Files (x86)\cloudflared'
    }
    It 'never ends in a backslash, except for a drive root' {
        ConvertTo-PathList -Path 'C:\a\;D:\' | Should -Be 'C:\a;D:\'
        ConvertTo-PathList -Path 'C:\a\;C:\b\\' | Should -Not -Match '\\$'
    }
    It 'copes with an empty PATH' {
        ConvertTo-PathList -Path '' | Should -Be ''
        ConvertTo-PathList -Path $null | Should -Be ''
    }
}

Describe 'Test-ServiceConfigSame' {
    It 'is true for the same values, ignoring empty entries' {
        Test-ServiceConfigSame -Current @{ Application = 'C:\farm\bin\GADS.exe'; DependOnService = @('MongoDB', ''); AppEnvironmentExtra = $null; Extra = 'x' } `
            -Wanted @{ Application = 'C:\farm\bin\GADS.exe'; DependOnService = @('MongoDB'); AppEnvironmentExtra = @() } | Should -BeTrue
    }
    It 'is false when <Case>' -ForEach @(
        @{ Case = 'a value differs'; Current = @{ A = 'x' }; Wanted = @{ A = 'y' } }
        @{ Case = 'only the letter case differs'; Current = @{ A = 'path' }; Wanted = @{ A = 'PATH' } }
        @{ Case = 'a list is shorter'; Current = @{ A = @('1') }; Wanted = @{ A = @('1', '2') } }
        @{ Case = 'a list is in another order'; Current = @{ A = @('2', '1') }; Wanted = @{ A = @('1', '2') } }
        @{ Case = 'the value is missing'; Current = @{ }; Wanted = @{ A = 'x' } }
        @{ Case = 'three variables were merged into one'; Current = @{ A = @('PATH=C:\x" APPIUM_HOME=C:\farm\appium NPM_CONFIG_PREFIX=C:\farm\npm') }; Wanted = @{ A = @('APPIUM_HOME=C:\farm\appium', 'NPM_CONFIG_PREFIX=C:\farm\npm', 'PATH=C:\x') } }
    ) {
        Test-ServiceConfigSame -Current $Current -Wanted $Wanted | Should -BeFalse
    }
}

Describe 'Get-TextSha256' {
    It 'matches the known SHA-256 of "abc"' {
        Get-TextSha256 -Text 'abc' | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
}

Describe 'Test-FarmRootTrust (a C:\farm that exists before the kit runs)' {
    BeforeAll {
        $script:admins = 'S-1-5-32-544'; $script:system = 'S-1-5-18'
        $script:user = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $script:authUsers = 'S-1-5-11'; $script:users = 'S-1-5-32-545'
    }
    It 'uses a folder that the kit locked: owned by Administrators, only Administrators and SYSTEM on it' {
        (Test-FarmRootTrust -IsFolder $true -IsLink $false -IsEmpty $false -OwnerSid $script:admins -AllowSids @($script:admins, $script:system)).Action | Should -Be 'use'
    }
    It 'replaces an empty folder, whoever made it' {
        (Test-FarmRootTrust -IsFolder $true -IsLink $false -IsEmpty $true -OwnerSid $script:user -AllowSids @($script:authUsers)).Action | Should -Be 'recreate'
    }
    It 'refuses a folder with content that a standard user owns' {
        $v = Test-FarmRootTrust -IsFolder $true -IsLink $false -IsEmpty $false -OwnerSid $script:user -AllowSids @($script:admins, $script:system)
        $v.Action | Should -Be 'refuse'
        $v.Reason | Should -Not -BeNullOrEmpty
    }
    It 'refuses a folder with content that <Who> may write to, even when Administrators own it' -ForEach @(
        @{ Who = 'Authenticated Users'; Sid = 'S-1-5-11' }
        @{ Who = 'Users'; Sid = 'S-1-5-32-545' }
        @{ Who = 'Everyone'; Sid = 'S-1-1-0' }
        @{ Who = 'one user'; Sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001' }
        @{ Who = 'CREATOR OWNER'; Sid = 'S-1-3-0' }
    ) {
        (Test-FarmRootTrust -IsFolder $true -IsLink $false -IsEmpty $false -OwnerSid $script:admins -AllowSids @($script:admins, $script:system, $Sid)).Action | Should -Be 'refuse'
    }
    It 'refuses a link, a file, and a folder whose owner cannot be read' {
        (Test-FarmRootTrust -IsFolder $true -IsLink $true -IsEmpty $true -OwnerSid $script:admins -AllowSids @($script:admins)).Action | Should -Be 'refuse'
        (Test-FarmRootTrust -IsFolder $false -IsLink $false -IsEmpty $false -OwnerSid $script:admins -AllowSids @($script:admins)).Action | Should -Be 'refuse'
        (Test-FarmRootTrust -IsFolder $true -IsLink $false -IsEmpty $false -OwnerSid '' -AllowSids @()).Action | Should -Be 'refuse'
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
    It 'pins exact versions for the three npm packages of -WithAppium' {
        foreach ($name in @('appium', 'xcuitestDriver', 'gadsPlugin')) { [string]$script:v.npm.$name | Should -Match '^\d+\.\d+\.\d+$' }
    }
    It 'pins an exact version for every winget package' {
        foreach ($p in $script:v.winget.PSObject.Properties) {
            $p.Value.id | Should -Match '^[A-Za-z0-9]+(\.[A-Za-z0-9]+)+$'
            $p.Value.version | Should -Match '^\d'
        }
    }
}
