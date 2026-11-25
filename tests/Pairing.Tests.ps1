# Pester 5 tests for the pairing client of lib\FarmKit.psm1 (the mirror of
# tests/pairing.test.sh), against tests/fake-blossom.js: a stand-in for
# Blossom CRM that serves the pairing API over https with a certificate made
# for the run.
#   Invoke-Pester .\tests
# Runs on Windows PowerShell 5.1 (CI) and on PowerShell 7. The tests against
# the stand-in need node and openssl, and on Windows an Administrator window
# (the certificate of the run is added to the machine's trusted roots and
# removed again afterwards). Nothing leaves this computer.
#
# On Linux and macOS, PowerShell decides which certificates it trusts before
# a test can tell it, so the certificate is made first:
#   node tests/fake-blossom.js --make-cert /tmp/fake-blossom-cert
#   SSL_CERT_FILE=/tmp/fake-blossom-cert/cert.pem pwsh -Command "Invoke-Pester ./tests"
# Without that, the tests against the stand-in are skipped there. With
# FARMKIT_REQUIRE_STAND_IN set (as in CI) a skip is a failure.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\FarmKit.psm1') -Force -DisableNameChecking
}

Describe 'Pairing codes' {
    It 'writes a code the way it is sent' {
        ConvertTo-PairingCode -Code 'k7qm-2xvd-9htr-4bwn-6cpa' | Should -BeExactly 'K7QM2XVD9HTR4BWN6CPA'
        ConvertTo-PairingCode -Code ' K7QM 2XVD 9HTR 4BWN 6CPA ' | Should -BeExactly 'K7QM2XVD9HTR4BWN6CPA'
        ConvertTo-PairingCode -Code 'OIL0-0000-0000-0000-0000' | Should -BeExactly '01100000000000000000'
    }
    It 'accepts <Code>' -ForEach @(
        @{ Code = 'K7QM-2XVD-9HTR-4BWN-6CPA' }
        @{ Code = 'k7qm2xvd9htr4bwn6cpa' }
    ) {
        Test-PairingCode -Code $Code | Should -BeNullOrEmpty
    }
    It 'refuses <Code>' -ForEach @(
        @{ Code = '' }
        @{ Code = 'K7QM-2XVD-9HTR' }
        @{ Code = 'K7QM-2XVD-9HTR-4BWN-6CPA-AAAA' }
        @{ Code = 'K7QM-2XVD-9HTR-4BWN-6CP!' }
        @{ Code = 'U7QM-2XVD-9HTR-4BWN-6CPA' }
        @{ Code = 'K7QM-2XVD-9HTR-4BWN-6CP$(id)' }
    ) {
        Test-PairingCode -Code $Code | Should -Not -BeNullOrEmpty
    }
    It 'carries 100 bits' {
        (ConvertTo-PairingCode -Code 'K7QM-2XVD-9HTR-4BWN-6CPA').Length * 5 | Should -Be 100
    }
}

Describe 'The address of Blossom' {
    It 'is stored in lower case, without a slash at the end' {
        ConvertTo-AppOrigin -Origin ' HTTPS://App.Example.org/ ' | Should -BeExactly 'https://app.example.org'
    }
    It 'accepts <Origin>' -ForEach @(
        @{ Origin = 'https://app.blossom.example' }
        @{ Origin = 'https://app.blossom.example:8443' }
        @{ Origin = 'https://127.0.0.1:4443' }
        @{ Origin = 'HTTPS://App.Blossom.Example/' }
    ) {
        Test-AppOrigin -Origin $Origin | Should -BeNullOrEmpty
    }
    It 'refuses <Origin>' -ForEach @(
        @{ Origin = '' }
        @{ Origin = 'http://app.blossom.example' }
        @{ Origin = 'app.blossom.example' }
        @{ Origin = 'ftp://app.blossom.example' }
        @{ Origin = 'https://' }
        @{ Origin = 'https://app.blossom.example/path' }
        @{ Origin = 'https://app.blossom.example?x=1' }
        @{ Origin = 'https://user:pw@app.blossom.example' }
        @{ Origin = 'https://app.blossom.example#x' }
        @{ Origin = 'https://app.blossom.example:port' }
        @{ Origin = 'https://app.blossom.example:0' }
        @{ Origin = 'https://app.blossom.example:70000' }
        @{ Origin = 'https://app..example' }
        @{ Origin = 'https://-app.example' }
        @{ Origin = 'https://[::1]:443' }
        @{ Origin = 'https://app.blossom.example evil' }
        @{ Origin = 'https://app.blossom.example\@evil.example' }
    ) {
        Test-AppOrigin -Origin $Origin | Should -Not -BeNullOrEmpty
    }
    It 'says that http is refused' {
        Test-AppOrigin -Origin 'http://app.blossom.example' | Should -Match 'https://'
    }
}

Describe 'Farm tokens' {
    It 'are bft_ and 256 random bits' {
        $t = New-FarmToken
        $t | Should -Match '^bft_[A-Za-z0-9_-]{43}$'
        Test-FarmToken -Token $t | Should -BeTrue
    }
    It 'are never the same twice' {
        (1..50 | ForEach-Object { New-FarmToken } | Sort-Object -Unique).Count | Should -Be 50
    }
    It 'refuses <Token>' -ForEach @(
        @{ Token = '' }
        @{ Token = 'bft_' }
        @{ Token = 'bft_short' }
        @{ Token = 'xft_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
        @{ Token = 'bft_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=' }
        @{ Token = 'BFT_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
    ) {
        Test-FarmToken -Token $Token | Should -BeFalse
    }
}

Describe 'The default host names' {
    It 'are three names under the domain' {
        (Get-DefaultFarmHostnames -Domain 'YourDomain.com') -join ' ' | Should -BeExactly 'farm-hub.yourdomain.com farm-provider.yourdomain.com farm-restart.yourdomain.com'
    }
    It 'take a pasted address' {
        ConvertTo-FarmDomain -Domain ' https://Agency.co.uk/ ' | Should -BeExactly 'agency.co.uk'
    }
    It 'pass the host name rules' {
        $n = Get-DefaultFarmHostnames -Domain 'agency.io'
        (Test-FarmHostnameSet -Hub $n[0] -Provider $n[1] -Restart $n[2]).Count | Should -Be 0
    }
    It 'accepts a domain' { Test-FarmDomain -Domain 'agency.co.uk' | Should -BeNullOrEmpty }
    It 'refuses <Domain>' -ForEach @(
        @{ Domain = '' }
        @{ Domain = 'com' }
        @{ Domain = 'example.com' }
        @{ Domain = 'my domain.com' }
        @{ Domain = 'agency.local' }
        @{ Domain = '192.168.1.1' }
    ) {
        Test-FarmDomain -Domain $Domain | Should -Not -BeNullOrEmpty
    }
}

Describe 'Texts' {
    It 'reduces a computer name to plain characters' {
        ConvertTo-ComputerLabel -Name 'Farm PC #1 (office)' | Should -BeExactly 'Farm PC 1 office'
        ConvertTo-ComputerLabel -Name '' | Should -BeExactly 'farm computer'
    }
    It 'takes the control characters out of a text from the network' {
        ConvertTo-RemoteText -Text ("one`ntwo" + [char]27 + '[31m red' + [char]1) | Should -BeExactly 'one two[31m red'
        (ConvertTo-RemoteText -Text ('x' * 400)).Length | Should -Be 300
    }
    It 'explains what Blossom answered' {
        Get-PairingMessage -Code 'pairing_code_expired' -Text '' | Should -Match '30 minutes'
        Get-PairingMessage -Code 'pairing_code_used' -Text '' | Should -Match 'another computer'
        Get-PairingMessage -Code 'something_new' -Text 'Text from Blossom.' | Should -BeExactly 'Text from Blossom.'
    }
}

Describe 'Pairing against the stand-in for Blossom' {
    BeforeAll {
        $script:Skip = $null
        $script:Fakes = @()
        $script:TrustedCert = $null
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('farmkit-pairing-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        $onWindows = ($env:OS -eq 'Windows_NT')

        function Start-Fake {
            param([string]$Name, [string]$CertDir = '')
            $dir = Join-Path $script:Work $Name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $node = (Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if (-not $node) { return $null }
            $startArgs = @{
                FilePath = $node; ArgumentList = @(('"' + (Join-Path $PSScriptRoot 'fake-blossom.js') + '"'), '--dir', ('"' + $dir + '"'))
                PassThru = $true; RedirectStandardOutput = (Join-Path $dir 'out.log'); RedirectStandardError = (Join-Path $dir 'err.log')
            }
            if ($CertDir) { $startArgs['ArgumentList'] += @('--cert-dir', ('"' + $CertDir + '"')) }
            if ($env:OS -eq 'Windows_NT') { $startArgs['WindowStyle'] = 'Hidden' }
            $process = Start-Process @startArgs
            $portsFile = Join-Path $dir 'ports.json'
            for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $portsFile); $i++) { Start-Sleep -Milliseconds 100 }
            if (-not (Test-Path -LiteralPath $portsFile)) { try { $process.Kill() } catch { $null = $_ }; return $null }
            Start-Sleep -Milliseconds 200
            $ports = Get-Content -LiteralPath $portsFile -Raw | ConvertFrom-Json
            return New-Object PSObject -Property @{
                Process = $process; Dir = $dir; Cert = (Join-Path $dir 'cert.pem')
                Origin = ('https://127.0.0.1:' + $ports.https); Control = ('http://127.0.0.1:' + $ports.http); HttpPort = $ports.http
            }
        }
        function Invoke-Switch {
            # One of the test switches of the stand-in.
            param([string]$Name, [hashtable]$With = @{}, $Fake = $script:Fake)
            return Invoke-RestMethod -Method Post -Uri ($Fake.Control + '/__test/' + $Name) -Body ($With | ConvertTo-Json -Compress) -ContentType 'application/json'
        }
        function New-Code { param([hashtable]$With = @{}) return [string](Invoke-Switch -Name 'new-code' -With $With).code }
        function Use-Farm {
            param([string]$Name)
            $paths = Get-FarmPaths -Root (Join-Path $script:Work $Name)
            New-Item -ItemType Directory -Path $paths.Config -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $paths.Config 'versions.json') -Value '{"kit":"9.9.9","gads":{"version":"v6.0.0"},"gadsDrag":{"version":"v6.0.0-drag.1"}}'
            return $paths
        }
        function Get-Mine {
            # What points a switch at the pairing of a farm.
            param($Paths, [hashtable]$With = @{})
            $p = Read-FarmPairing -Paths $Paths
            if ($p) { $With['token'] = $p.FarmToken }
            return $With
        }
        function Get-FakeState { param($Paths) return (Invoke-Switch -Name 'state' -With (Get-Mine -Paths $Paths)) }
        function Send-TestSite {
            param($Paths, [string]$HubPassword, [string]$RestartSecret, [string]$HubHost = 'farm-hub.agency.io')
            return Send-FarmSite -Paths $Paths -HubUrl ('https://' + $HubHost) -ProviderUrl 'https://farm-provider.agency.io' -Nickname 'Provider1' -HubUser 'blossom' -HubPassword $HubPassword -RestartUrl 'https://farm-restart.agency.io' -RestartSecret $RestartSecret
        }

        $certDir = ''
        if (-not $onWindows -and $env:SSL_CERT_FILE) { $certDir = Split-Path -Parent $env:SSL_CERT_FILE }
        $script:Fake = Start-Fake -Name 'fake' -CertDir $certDir
        $script:Stranger = Start-Fake -Name 'stranger'
        if (-not $script:Fake -or -not $script:Stranger) {
            $script:Skip = 'node or openssl is not installed'
        } else {
            $script:Fakes = @($script:Fake, $script:Stranger)
            if ($onWindows) {
                try {
                    $script:TrustedCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($script:Fake.Cert)
                    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
                    $store.Open('ReadWrite'); $store.Add($script:TrustedCert); $store.Close()
                } catch { $script:TrustedCert = $null; $script:Skip = 'the certificate of the run could not be added to the trusted roots (run as Administrator)' }
            } elseif ((Invoke-FarmHttp -Url ($script:Fake.Origin + '/api/farm/pair/status')).Status -eq 0) {
                $script:Skip = 'PowerShell does not trust the certificate of the run: start it with SSL_CERT_FILE set (see the top of this file)'
            }
        }
        if ($script:Skip -and $env:FARMKIT_REQUIRE_STAND_IN) { throw ('FARMKIT_REQUIRE_STAND_IN is set, and the stand-in for Blossom cannot be used: ' + $script:Skip) }
        if ($script:Skip) { Write-Warning ('The tests against the stand-in for Blossom are skipped: ' + $script:Skip) }
        else { $null = Invoke-Switch -Name 'reset-hits' }

        # The module locks its files with icacls; the tests work in a temporary folder.
        Mock -ModuleName FarmKit Protect-FarmPath { }
        Mock -ModuleName FarmKit Write-Host { }
        # Nobody is at a keyboard in a test: what "the person" types is said
        # through an environment variable (the mock runs inside the module).
        $env:FARMKIT_TEST_WORD = '<nobody>'
        Mock -ModuleName FarmKit Read-FarmTypedWord {
            if ($env:FARMKIT_TEST_WORD -eq '<nobody>') { return $null }
            return [string]$env:FARMKIT_TEST_WORD
        }
        InModuleScope FarmKit { $script:BlossomRetryDelaySec = 0; $script:BlossomTries = 3 }
    }

    AfterAll {
        foreach ($f in $script:Fakes) { try { $f.Process.Kill() } catch { $null = $_ } }
        if ($script:TrustedCert) {
            try {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
                $store.Open('ReadWrite'); $store.Remove($script:TrustedCert); $store.Close()
            } catch { Write-Warning 'The certificate of the run could not be removed from the trusted roots.' }
        }
        InModuleScope FarmKit { $script:BlossomRetryDelaySec = 2; $script:BlossomTries = 4 }
        Remove-Item Env:\FARMKIT_TEST_WORD -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'claims a fresh code, keeps the token and not the code' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        $script:Code1 = New-Code @{ workspace = 'Agency One' }
        $script:Code1 | Should -Match '^[0-9A-Z]{4}(-[0-9A-Z]{4}){4}$'
        $r = Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code $script:Code1
        $r.Ok | Should -BeTrue
        $r.Workspace | Should -BeExactly 'Agency One'
        Test-Path -LiteralPath $paths.PairingNew | Should -BeFalse
        $p = Read-FarmPairing -Paths $paths
        $p.AppOrigin | Should -BeExactly $script:Fake.Origin
        Test-FarmToken -Token $p.FarmToken | Should -BeTrue
        $script:Token1 = $p.FarmToken
        (Get-Content -LiteralPath $paths.Pairing -Raw) | Should -Not -Match ($script:Code1 -replace '-', '')
        $state = Get-FakeState -Paths $paths
        $state.pairing.state | Should -BeExactly 'installing'
        $state.pairing.computer.platform | Should -BeExactly 'windows'
        $state.pairing.computer.kit_version | Should -BeExactly '9.9.9'
        $state.hits[0].userAgent | Should -BeExactly 'blossom-farm-kit/9.9.9'
        $state.hits[0].secure | Should -BeTrue
    }

    It 'asks Blossom nothing when the same command is run again' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        $before = @((Get-FakeState -Paths $paths).hits).Count
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code $script:Code1).Ok | Should -BeTrue
        @((Get-FakeState -Paths $paths).hits).Count | Should -Be $before
        (Read-FarmPairing -Paths $paths).FarmToken | Should -BeExactly $script:Token1
    }

    It 'refuses a code that another computer used' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm2'
        $r = Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code $script:Code1
        $r.Ok | Should -BeFalse
        $r.Code | Should -BeExactly 'pairing_code_used'
        $r.Message | Should -Match 'another computer'
        Test-Path -LiteralPath $paths.Pairing | Should -BeFalse
        Test-Path -LiteralPath $paths.PairingNew | Should -BeFalse
    }

    It 'refuses an expired, an unknown and a cancelled code' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm2'
        $expired = New-Code @{ ttlSeconds = 0 }
        Start-Sleep -Milliseconds 200
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code $expired).Code | Should -BeExactly 'pairing_code_expired'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ').Code | Should -BeExactly 'pairing_code_unknown'
        $cancelled = New-Code
        $null = Invoke-Switch -Name 'cancel-code' -With @{ code = $cancelled }
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code $cancelled).Code | Should -BeExactly 'pairing_code_unknown'
        $before = @((Get-FakeState -Paths $paths).hits).Count
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code 'not-a-code').Kind | Should -BeExactly 'origin'
        @((Get-FakeState -Paths $paths).hits).Count | Should -Be $before
    }

    It 'completes the same claim when the answer was lost on the way' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm3'
        $code = New-Code
        $null = Invoke-Switch -Name 'fail-next' -With @{ count = 3; status = 503 }
        $r = Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code $code
        $r.Ok | Should -BeFalse
        $r.Kind | Should -BeExactly 'network'
        $pending = [string](Get-Content -LiteralPath $paths.PairingNew -Raw | ConvertFrom-Json).farmToken
        Test-FarmToken -Token $pending | Should -BeTrue
        # The claim reaches Blossom, but its answer never reaches the computer:
        $body = @{ protocol = 1; pairing_code = $code; farm_token = $pending; computer = @{ label = 'x'; platform = 'windows' } } | ConvertTo-Json -Compress
        (Invoke-FarmHttp -Url ($script:Fake.Origin + '/api/farm/pair/claim') -Method 'POST' -Body $body).Status | Should -Be 200
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code $code).Ok | Should -BeTrue
        (Read-FarmPairing -Paths $paths).FarmToken | Should -BeExactly $pending
        Test-Path -LiteralPath $paths.PairingNew | Should -BeFalse
    }

    It 'sends nothing to an address that is not an https origin' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm4'
        $code = New-Code
        $null = Invoke-Switch -Name 'reset-hits'
        $plain = 'http://127.0.0.1:' + $script:Fake.HttpPort
        $r = Register-FarmPairing -Paths $paths -Origin $plain -Code $code
        $r.Kind | Should -BeExactly 'origin'
        $r.Message | Should -Match 'https://'
        (Register-FarmPairing -Paths $paths -Origin ($script:Fake.Origin + '/api') -Code $code).Kind | Should -BeExactly 'origin'
        (Invoke-Blossom -Origin $plain -Method 'GET' -Path '/api/farm/pair/status' -Token $script:Token1).Kind | Should -BeExactly 'origin'
        $state = Invoke-Switch -Name 'state'
        $state.plainApiHits | Should -Be 0
        @($state.hits).Count | Should -Be 0
        Set-Content -LiteralPath $paths.Pairing -Value (@{ appOrigin = $plain; farmToken = $script:Token1 } | ConvertTo-Json)
        Read-FarmPairing -Paths $paths | Should -BeNullOrEmpty
    }

    It 'sends nothing when the certificate cannot be verified' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm-tls'
        Set-Content -LiteralPath $paths.Pairing -Value (@{ appOrigin = $script:Stranger.Origin; farmToken = (New-FarmToken) } | ConvertTo-Json)
        $r = Send-TestSite -Paths $paths -HubPassword 'hub-password-1' -RestartSecret 'restart-secret-1'
        $r.Ok | Should -BeFalse
        $r.Kind | Should -BeExactly 'tls'
        $r.Message | Should -Match 'could not be verified'
        @((Invoke-Switch -Name 'state' -Fake $script:Stranger).hits).Count | Should -Be 0
    }

    It 'refuses a redirect and does not follow it' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        $null = Invoke-Switch -Name 'redirect' -With @{ on = $true }
        try {
            $r = Send-TestSite -Paths $paths -HubPassword 'hub-password-1' -RestartSecret 'restart-secret-1'
            $r.Kind | Should -BeExactly 'redirect'
            $r.Message | Should -Match 'not followed'
            (Get-FarmPairingStatus -Paths $paths).Kind | Should -BeExactly 'redirect'
            (Invoke-Switch -Name 'state').redirectHits | Should -Be 0
        } finally { $null = Invoke-Switch -Name 'redirect' -With @{ on = $false } }
    }

    It 'recognises an address that is not Blossom' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        $null = Invoke-Switch -Name 'fail-next' -With @{ count = 1; status = 200; html = $true }
        (Get-FarmPairingStatus -Paths $paths -Tries 1).Kind | Should -BeExactly 'not_blossom'
        $null = Invoke-Switch -Name 'fail-next' -With @{ count = 1; status = 404; html = $true }
        (Get-FarmPairingStatus -Paths $paths -Tries 1).Kind | Should -BeExactly 'not_blossom'
    }

    It 'sends the farm, with both secrets the first time' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        (Send-TestSite -Paths $paths -HubPassword '' -RestartSecret 'restart-secret-1').Code | Should -BeExactly 'credentials_required'
        (Send-TestSite -Paths $paths -HubPassword 'hub-password-1' -RestartSecret '').Code | Should -BeExactly 'credentials_required'
        (Read-FarmPairing -Paths $paths).SiteSentAt | Should -BeNullOrEmpty
        (Send-FarmSite -Paths $paths -HubUrl 'http://farm-hub.agency.io' -ProviderUrl 'https://farm-provider.agency.io' -Nickname 'Provider1' -HubUser 'blossom' -HubPassword 'pw' -RestartUrl 'https://farm-restart.agency.io' -RestartSecret 's').Code | Should -BeExactly 'site_address_refused'
        $null = Invoke-Switch -Name 'set-check' -With @{ ok = $true; devices = 3 }
        $r = Send-TestSite -Paths $paths -HubPassword 'hub-password-1' -RestartSecret 'restart-secret-1'
        $r.Ok | Should -BeTrue
        $r.State | Should -BeExactly 'checking'
        $r.NeedsConfirmation | Should -BeTrue
        (Read-FarmPairing -Paths $paths).SiteSentAt | Should -Not -BeNullOrEmpty
        $state = Get-FakeState -Paths $paths
        $state.pairing.site.hub_url | Should -BeExactly 'https://farm-hub.agency.io'
        $state.pairing.site.provider_nickname | Should -BeExactly 'Provider1'
        $state.pairing.secrets.hub_password | Should -BeExactly 'hub-password-1'
        $state.pairing.secrets.restart_secret | Should -BeExactly 'restart-secret-1'
        $state.pairing.confirmed | Should -BeFalse
    }

    It 'follows the pairing until an admin confirms it' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        (Get-FarmPairingStatus -Paths $paths).State | Should -BeExactly 'checking'
        $s = Get-FarmPairingStatus -Paths $paths
        $s.State | Should -BeExactly 'awaiting_confirmation'
        $s.CheckOk | Should -BeTrue
        $s.Devices | Should -Be 3
        Get-PairingCheckText -Status $s | Should -BeExactly 'Blossom sees your farm: 3 phones.'
        Wait-FarmPairing -Paths $paths -MaxSec 0 | Should -Be 2
        $null = Invoke-Switch -Name 'confirm' -With (Get-Mine -Paths $paths -With @{ label = 'Milan' })
        Wait-FarmPairing -Paths $paths -MaxSec 20 | Should -Be 0
        Should -Invoke -ModuleName FarmKit Write-Host -ParameterFilter { [string]$Object -match 'Confirmed in Blossom as "Milan"\. Blossom sees your farm: 3 phones\.' }
        Should -Invoke -ModuleName FarmKit Write-Host -Exactly -Times 0 -ParameterFilter { [string]$Object -match 'bft_' }
        $null = Invoke-Switch -Name 'set-check' -With @{ ok = $false; devices = 0; failed_step = 'signin'; detail = 'The hub refused the user name or password.' }
        $null = Invoke-Switch -Name 'recheck' -With (Get-Mine -Paths $paths)
        Get-PairingCheckText -Status (Get-FarmPairingStatus -Paths $paths) | Should -Match 'could not use the farm yet \(step: signin\): The hub refused'
        $null = Invoke-Switch -Name 'set-check' -With @{ ok = $true; devices = 1 }
        $null = Invoke-Switch -Name 'recheck' -With (Get-Mine -Paths $paths)
        Get-PairingCheckText -Status (Get-FarmPairingStatus -Paths $paths) | Should -BeExactly 'Blossom sees your farm: 1 phone.'
    }

    It 'sends new credentials through the farm token, without a new confirmation' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        $r = Send-TestSite -Paths $paths -HubPassword 'hub-password-2' -RestartSecret ''
        $r.Ok | Should -BeTrue
        $r.NeedsConfirmation | Should -BeFalse
        $state = Get-FakeState -Paths $paths
        $state.pairing.secrets.hub_password | Should -BeExactly 'hub-password-2'
        $state.pairing.secrets.restart_secret | Should -BeExactly 'restart-secret-1'
        $state.pairing.confirmed | Should -BeTrue
        (Send-TestSite -Paths $paths -HubPassword '' -RestartSecret 'restart-secret-2').Ok | Should -BeTrue
        (Get-FakeState -Paths $paths).pairing.secrets.restart_secret | Should -BeExactly 'restart-secret-2'
        $same = Send-TestSite -Paths $paths -HubPassword '' -RestartSecret ''
        $same.Ok | Should -BeTrue
        $same.SiteChanged | Should -BeFalse
    }

    It 'needs a new confirmation for new addresses' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        (Send-TestSite -Paths $paths -HubPassword '' -RestartSecret '' -HubHost 'farm-hub.other.io').Code | Should -BeExactly 'credentials_required'
        (Get-FakeState -Paths $paths).pairing.site.hub_url | Should -BeExactly 'https://farm-hub.agency.io'
        $r = Send-TestSite -Paths $paths -HubPassword 'hub-password-3' -RestartSecret '' -HubHost 'farm-hub.other.io'
        $r.Ok | Should -BeTrue
        $r.NeedsConfirmation | Should -BeTrue
        # until an admin has confirmed, Blossom goes on using the confirmed
        # address: the token cannot take its site out of service
        $held = (Get-FakeState -Paths $paths).pairing
        $held.awaiting | Should -BeTrue
        $held.confirmed | Should -BeTrue
        $held.confirmedSite.hub_url | Should -BeExactly 'https://farm-hub.agency.io'
        $null = Get-FarmPairingStatus -Paths $paths
        $s = Get-FarmPairingStatus -Paths $paths
        $s.State | Should -BeExactly 'awaiting_confirmation'
        $s.NeedsConfirmation | Should -BeTrue
        # declined new addresses leave the site and the pairing as they were
        $null = Invoke-Switch -Name 'reject' -With (Get-Mine -Paths $paths)
        $s = Get-FarmPairingStatus -Paths $paths
        $s.Ok | Should -BeTrue
        $s.State | Should -BeExactly 'active'
    }

    It 'tells Blossom the versions after an update' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        Set-Content -LiteralPath (Join-Path $paths.Config 'versions.json') -Value '{"kit":"9.9.10","gads":{"version":"v6.0.1"},"gadsDrag":{"version":"v6.0.1-drag.1"}}'
        (Send-FarmComputer -Paths $paths).Ok | Should -BeTrue
        $state = Get-FakeState -Paths $paths
        $state.pairing.computer.kit_version | Should -BeExactly '9.9.10'
        $state.pairing.computer.gads_version | Should -BeExactly 'v6.0.1'
        $state.pairing.site.hub_url | Should -BeExactly 'https://farm-hub.agency.io'
    }

    It 'tries again when Blossom is busy, and not when it says no' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        $null = Invoke-Switch -Name 'reset-hits'
        $null = Invoke-Switch -Name 'fail-next' -With @{ count = 2; status = 503 }
        (Get-FarmPairingStatus -Paths $paths -Tries 3).Ok | Should -BeTrue
        @((Invoke-Switch -Name 'state').hits).Count | Should -Be 3
        $null = Invoke-Switch -Name 'fail-next' -With @{ count = 1; status = 429; code = 'rate_limited'; retryAfter = 1 }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        (Get-FarmPairingStatus -Paths $paths -Tries 2).Ok | Should -BeTrue
        $watch.Elapsed.TotalMilliseconds | Should -BeGreaterThan 900
        $null = Invoke-Switch -Name 'fail-next' -With @{ count = 5; status = 503 }
        (Get-FarmPairingStatus -Paths $paths -Tries 2).Kind | Should -BeExactly 'network'
        $null = Invoke-Switch -Name 'reset-hits'
        $null = Invoke-Switch -Name 'fail-next' -With @{ count = 1; status = 400; code = 'bad_request'; error = 'No.' }
        (Get-FarmPairingStatus -Paths $paths -Tries 3).Ok | Should -BeFalse
        @((Invoke-Switch -Name 'state').hits).Count | Should -Be 1
    }

    It 'is slowed down after too many wrong codes' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm5'
        $null = Invoke-Switch -Name 'limits' -With @{ claimFailureLimit = 2 }
        InModuleScope FarmKit { $script:BlossomTries = 1 }
        try {
            $null = Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code 'AAAA-AAAA-AAAA-AAAA-AAAA'
            $null = Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code 'BBBB-BBBB-BBBB-BBBB-BBBB'
            (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code 'CCCC-CCCC-CCCC-CCCC-CCCC').Status | Should -Be 429
        } finally {
            InModuleScope FarmKit { $script:BlossomTries = 3 }
            $null = Invoke-Switch -Name 'limits' -With @{ claimFailureLimit = 10 }
        }
    }

    It 'stops when the pairing was declined, expired or revoked' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm6'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code)).Ok | Should -BeTrue
        (Send-TestSite -Paths $paths -HubPassword 'pw' -RestartSecret 'secret').Ok | Should -BeTrue
        $null = Invoke-Switch -Name 'reject' -With (Get-Mine -Paths $paths)
        Wait-FarmPairing -Paths $paths -MaxSec 5 | Should -Be 1
        (Send-TestSite -Paths $paths -HubPassword 'pw' -RestartSecret 'secret').Code | Should -BeExactly 'pairing_rejected'

        $paths = Use-Farm 'farm7'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code)).Ok | Should -BeTrue
        $null = Invoke-Switch -Name 'expire-pairing' -With (Get-Mine -Paths $paths)
        (Get-FarmPairingStatus -Paths $paths).State | Should -BeExactly 'expired'

        $paths = Use-Farm 'farm1'
        $null = Invoke-Switch -Name 'revoke' -With @{ token = $script:Token1 }
        $s = Get-FarmPairingStatus -Paths $paths
        $s.Kind | Should -BeExactly 'refused'
        $s.Code | Should -BeExactly 'farm_token_revoked'
        (Send-TestSite -Paths $paths -HubPassword 'pw' -RestartSecret 'secret').Status | Should -Be 401
        Wait-FarmPairing -Paths $paths -MaxSec 5 | Should -Be 1
    }

    It 'unpairs' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm1'
        (Remove-FarmPairing -Paths $paths).Ok | Should -BeTrue      # Blossom had dropped this computer already
        Test-Path -LiteralPath $paths.Pairing | Should -BeFalse

        $paths = Use-Farm 'farm8'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code)).Ok | Should -BeTrue
        $token = (Read-FarmPairing -Paths $paths).FarmToken
        (Remove-FarmPairing -Paths $paths).Ok | Should -BeTrue
        (Invoke-Switch -Name 'state' -With @{ token = $token }).pairing.unpairedByComputer | Should -BeTrue
        Test-Path -LiteralPath $paths.Pairing | Should -BeFalse
        (Remove-FarmPairing -Paths $paths).Ok | Should -BeTrue      # twice is fine

        # Blossom cannot be reached: the pairing file stays, so that it can be tried again
        Set-Content -LiteralPath $paths.Pairing -Value (@{ appOrigin = 'https://127.0.0.1:1'; farmToken = $token } | ConvertTo-Json)
        (Remove-FarmPairing -Paths $paths).Ok | Should -BeFalse
        Test-Path -LiteralPath $paths.Pairing | Should -BeTrue
    }

    It 'lets a new code of the same workspace replace an earlier pairing, and a failing code change nothing' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $env:FARMKIT_TEST_WORD = '<nobody>'
        $paths = Use-Farm 'farm9'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code)).Ok | Should -BeTrue
        $first = Read-FarmPairing -Paths $paths
        $first.WorkspaceId | Should -Match '^[0-9a-f-]{36}$'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code)).Ok | Should -BeTrue
        Should -Invoke -ModuleName FarmKit Read-FarmTypedWord -Exactly -Times 0
        $now = Read-FarmPairing -Paths $paths
        $now.FarmToken | Should -Not -BeExactly $first.FarmToken
        (Invoke-Switch -Name 'state' -With @{ token = $first.FarmToken }).pairing.revoked | Should -BeExactly 'revoked'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ').Ok | Should -BeFalse
        (Read-FarmPairing -Paths $paths).FarmToken | Should -BeExactly $now.FarmToken
    }

    It 'compares workspaces by their identifier, never by their name' {
        Test-SameWorkspace -OriginA 'https://a.example' -IdA 'id-1' -OriginB 'https://a.example' -IdB 'id-1' | Should -BeTrue
        Test-SameWorkspace -OriginA 'https://a.example' -IdA 'id-1' -OriginB 'https://a.example' -IdB 'id-2' | Should -BeFalse
        Test-SameWorkspace -OriginA 'https://a.example' -IdA 'id-1' -OriginB 'https://b.example' -IdB 'id-1' | Should -BeFalse
        Test-SameWorkspace -OriginA 'https://a.example' -IdA '' -OriginB 'https://a.example' -IdB '' | Should -BeFalse
        ConvertTo-WorkspaceId -Id '0B0E6C1E-AAAA-4BBB-8CCC-000000000001' | Should -BeExactly '0b0e6c1e-aaaa-4bbb-8ccc-000000000001'
        ConvertTo-WorkspaceId -Id 'Agency "One"' | Should -BeExactly ''
    }

    It 'does not move the farm to another workspace without a yes at the keyboard' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        # a genuine Blossom, and a workspace that gave itself the same name
        $other = @{ workspace = 'Test Agency'; workspaceId = '11111111-2222-4333-8444-555555555555' }
        $env:FARMKIT_TEST_WORD = '<nobody>'
        $paths = Use-Farm 'farm9'
        $mine = Read-FarmPairing -Paths $paths
        $r = Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code -With $other)
        $r.Ok | Should -BeFalse
        $r.Kind | Should -BeExactly 'declined'
        $r.Message | Should -Match 'stays paired with'
        Should -Invoke -ModuleName FarmKit Read-FarmTypedWord -Exactly -Times 1
        Should -Invoke -ModuleName FarmKit Write-Host -ParameterFilter { [string]$Object -match 'A workspace name proves nothing' }
        $kept = Read-FarmPairing -Paths $paths
        $kept.FarmToken | Should -BeExactly $mine.FarmToken
        $kept.WorkspaceId | Should -BeExactly $mine.WorkspaceId
        (Get-FarmPairingStatus -Paths $paths).Ok | Should -BeTrue
        Test-Path -LiteralPath $paths.PairingNew | Should -BeFalse
        # the claim made in the other workspace was given up again, and it never got an address or a secret
        $latest = (Invoke-Switch -Name 'state').pairing
        $latest.workspaceId | Should -BeExactly '11111111-2222-4333-8444-555555555555'
        $latest.revoked | Should -BeExactly 'revoked'
        $latest.site | Should -BeNullOrEmpty

        # any answer but the word that is asked for is a no
        $env:FARMKIT_TEST_WORD = 'yes'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code -With $other)).Kind | Should -BeExactly 'declined'
        (Read-FarmPairing -Paths $paths).FarmToken | Should -BeExactly $mine.FarmToken
    }

    It 'moves the farm when the word is typed, or the switch is given' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $other = @{ workspace = 'Test Agency'; workspaceId = '11111111-2222-4333-8444-555555555555' }
        $paths = Use-Farm 'farm9'
        $mine = Read-FarmPairing -Paths $paths
        $env:FARMKIT_TEST_WORD = ' Replace '
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code -With $other)).Ok | Should -BeTrue
        $moved = Read-FarmPairing -Paths $paths
        $moved.WorkspaceId | Should -BeExactly '11111111-2222-4333-8444-555555555555'
        $moved.SiteSentAt | Should -BeNullOrEmpty
        (Invoke-Switch -Name 'state' -With @{ token = $mine.FarmToken }).pairing.revoked | Should -BeExactly 'revoked'
        # -ReplacePairing answers the question in advance, for a run without a keyboard
        $env:FARMKIT_TEST_WORD = '<nobody>'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code) -ReplacePairing).Ok | Should -BeTrue
        Should -Invoke -ModuleName FarmKit Read-FarmTypedWord -Exactly -Times 1
        (Read-FarmPairing -Paths $paths).FarmToken | Should -Not -BeExactly $moved.FarmToken
    }

    It 'asks before anything is sent to another Blossom' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $env:FARMKIT_TEST_WORD = '<nobody>'
        $paths = Use-Farm 'farm9'
        $mine = Read-FarmPairing -Paths $paths
        $null = Invoke-Switch -Name 'reset-hits' -Fake $script:Stranger
        $r = Register-FarmPairing -Paths $paths -Origin $script:Stranger.Origin -Code 'K7QM-2XVD-9HTR-4BWN-6CPA'
        $r.Kind | Should -BeExactly 'declined'
        Should -Invoke -ModuleName FarmKit Read-FarmTypedWord -Exactly -Times 1
        @((Invoke-Switch -Name 'state' -Fake $script:Stranger).hits).Count | Should -Be 0
        (Read-FarmPairing -Paths $paths).FarmToken | Should -BeExactly $mine.FarmToken
        Test-Path -LiteralPath $paths.PairingNew | Should -BeFalse
    }

    It 'tests with the hub administrator once Blossom alone has the password of its user' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Use-Farm 'farm10'
        Get-SelfTestUser -Paths $paths -HubUser 'blossom' | Should -BeExactly 'blossom'
        (Register-FarmPairing -Paths $paths -Origin $script:Fake.Origin -Code (New-Code)).Ok | Should -BeTrue
        Get-SelfTestUser -Paths $paths -HubUser 'blossom' | Should -BeExactly 'blossom'
        (Send-TestSite -Paths $paths -HubPassword 'hub-password-1' -RestartSecret 'restart-secret-1').Ok | Should -BeTrue
        Get-SelfTestUser -Paths $paths -HubUser 'blossom' | Should -BeExactly 'admin'
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\self-test.ps1') -Raw) | Should -Match 'Get-SelfTestUser'
    }
}

Describe 'The source of the pairing client' {
    It 'never switches certificate checks off and never follows a redirect' {
        $files = @('lib\FarmKit.psm1', 'install.ps1', 'bootstrap.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\scripts') -Filter '*.ps1' | ForEach-Object { 'scripts\' + $_.Name })
        foreach ($f in $files) {
            $text = Get-Content -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') $f) -Raw
            $text | Should -Not -Match 'ServerCertificateValidationCallback|SkipCertificateCheck|CheckCertificateRevocationList\s*=\s*\$false'
            $text | Should -Not -Match 'AllowAutoRedirect\s*=\s*\$true'
        }
    }
}
