# Pester 5 tests for bootstrap.ps1: the chain of checksums of the one-command
# setup on Windows (the mirror of tests/bootstrap.test.sh). A kit release is
# made here from a small stand-in for the kit, served over https by
# tests/fake-blossom.js, and bootstrap.ps1 is run against it.
#   Invoke-Pester .\tests
# Needs node and openssl and a trusted certificate, exactly as
# tests\Pairing.Tests.ps1 does (see the top of that file).

Describe 'bootstrap.ps1' {
    BeforeAll {
        $script:Skip = $null
        $script:Process = $null
        $script:TrustedCert = $null
        $script:Kit = Join-Path $PSScriptRoot '..'
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('farmkit-bootstrap-' + [Guid]::NewGuid().ToString('N'))
        $script:Release = Join-Path $script:Work 'release'
        $script:Shell = (Get-Process -Id $PID).Path
        New-Item -ItemType Directory -Path (Join-Path $script:Release 'kit-v9.9.9') -Force | Out-Null
        $onWindows = ($env:OS -eq 'Windows_NT')

        function Get-Sha { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
        function New-StandInRelease {
            # The files .github/scripts/make-kit-release.sh makes, for a stand-in kit whose
            # install.ps1 writes down how it was called.
            param([string]$Extra = '')
            $rel = Join-Path $script:Release 'kit-v9.9.9'
            $src = Join-Path $script:Work 'src\blossom-farm-kit-9.9.9'
            if (Test-Path -LiteralPath (Join-Path $script:Work 'src')) { Remove-Item -LiteralPath (Join-Path $script:Work 'src') -Recurse -Force }
            New-Item -ItemType Directory -Path $src -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src 'versions.json') -Value '{ "kit": "9.9.9" }'
            Set-Content -LiteralPath (Join-Path $src 'install.ps1') -Value ('Set-Content -LiteralPath (Join-Path $PSScriptRoot ''called-with.txt'') -Value (@($args.Count) + $args)' + "`n" + 'Write-Host ''the stand-in installer ran''' + "`n" + $Extra)
            $zip = Join-Path $rel 'blossom-farm-kit-9.9.9.zip'
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
            Compress-Archive -Path $src -DestinationPath $zip
            return $zip
        }
        function Write-Sums {
            $rel = Join-Path $script:Release 'kit-v9.9.9'
            [System.IO.File]::WriteAllText((Join-Path $rel 'SHA256SUMS'), ((Get-Sha (Join-Path $rel 'blossom-farm-kit-9.9.9.zip')) + "  blossom-farm-kit-9.9.9.zip`n"))
        }
        function New-Bootstrap {
            param([string]$BaseUrl, [string]$OutFile)
            $rel = Join-Path $script:Release 'kit-v9.9.9'
            $text = Get-Content -LiteralPath (Join-Path $script:Kit 'bootstrap.ps1') -Raw
            $text = $text.Replace("'@KIT_TAG@'", "'kit-v9.9.9'").Replace("'@KIT_BASE_URL@'", "'" + $BaseUrl + "'").Replace("'@KIT_ARCHIVE@'", "'blossom-farm-kit-9.9.9.zip'").Replace("'@KIT_SUMS_SHA256@'", "'" + (Get-Sha (Join-Path $rel 'SHA256SUMS')) + "'")
            [System.IO.File]::WriteAllText($OutFile, $text)
        }
        function Invoke-Bootstrap {
            param([string]$File, [string[]]$With = @())
            $out = & $script:Shell -NoProfile -ExecutionPolicy Bypass -File $File @With 2>&1 | ForEach-Object { [string]$_ }
            return New-Object PSObject -Property @{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
        }

        $node = (Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $node) { $script:Skip = 'node is not installed' }
        else {
            $dir = Join-Path $script:Work 'fake'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $list = @(('"' + (Join-Path $PSScriptRoot 'fake-blossom.js') + '"'), '--dir', ('"' + $dir + '"'), '--static', ('"' + $script:Release + '"'))
            if (-not $onWindows -and $env:SSL_CERT_FILE) { $list += @('--cert-dir', ('"' + (Split-Path -Parent $env:SSL_CERT_FILE) + '"')) }
            $startArgs = @{ FilePath = $node; ArgumentList = $list; PassThru = $true; RedirectStandardOutput = (Join-Path $dir 'out.log'); RedirectStandardError = (Join-Path $dir 'err.log') }
            if ($onWindows) { $startArgs['WindowStyle'] = 'Hidden' }
            $script:Process = Start-Process @startArgs
            $portsFile = Join-Path $dir 'ports.json'
            for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $portsFile); $i++) { Start-Sleep -Milliseconds 100 }
            if (-not (Test-Path -LiteralPath $portsFile)) { $script:Skip = 'the stand-in server did not start (is openssl installed?)' }
            else {
                Start-Sleep -Milliseconds 200
                $port = (Get-Content -LiteralPath $portsFile -Raw | ConvertFrom-Json).https
                $script:Base = 'https://127.0.0.1:' + $port + '/releases/kit-v9.9.9'
                $script:PlainBase = 'http://127.0.0.1:' + $port + '/releases/kit-v9.9.9'
                if ($onWindows) {
                    try {
                        $script:TrustedCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Join-Path $dir 'cert.pem'))
                        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
                        $store.Open('ReadWrite'); $store.Add($script:TrustedCert); $store.Close()
                    } catch { $script:TrustedCert = $null; $script:Skip = 'the certificate of the run could not be added to the trusted roots (run as Administrator)' }
                }
            }
        }
        if (-not $script:Skip) {
            $null = New-StandInRelease
            Write-Sums
            $script:Boot = Join-Path $script:Work 'blossom-bootstrap.ps1'
            New-Bootstrap -BaseUrl $script:Base -OutFile $script:Boot
            $probe = Invoke-Bootstrap -File $script:Boot -With @('-Destination', (Join-Path $script:Work 'probe'))
            if ($probe.Code -ne 0 -and -not $onWindows) { $script:Skip = 'PowerShell does not trust the certificate of the run: start it with SSL_CERT_FILE set (see the top of Pairing.Tests.ps1)' }
        }
        if ($script:Skip -and $env:FARMKIT_REQUIRE_STAND_IN) { throw ('FARMKIT_REQUIRE_STAND_IN is set, and the stand-in release cannot be used: ' + $script:Skip) }
        if ($script:Skip) { Write-Warning ('The tests of bootstrap.ps1 against a stand-in release are skipped: ' + $script:Skip) }
    }

    AfterAll {
        if ($script:Process) { try { $script:Process.Kill() } catch { $null = $_ } }
        if ($script:TrustedCert) {
            try {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
                $store.Open('ReadWrite'); $store.Remove($script:TrustedCert); $store.Close()
            } catch { Write-Warning 'The certificate of the run could not be removed from the trusted roots.' }
        }
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses to run as the template of the source tree' {
        $r = Invoke-Bootstrap -File (Join-Path $script:Kit 'bootstrap.ps1') -With @('-Destination', (Join-Path $script:Work 'never'))
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'template'
        Test-Path -LiteralPath (Join-Path $script:Work 'never') | Should -BeFalse
    }

    It 'sets each of the four values in exactly one place' {
        $text = Get-Content -LiteralPath (Join-Path $script:Kit 'bootstrap.ps1') -Raw
        foreach ($placeholder in @('@KIT_TAG@', '@KIT_BASE_URL@', '@KIT_ARCHIVE@', '@KIT_SUMS_SHA256@')) {
            ([regex]::Matches($text, [regex]::Escape("'" + $placeholder + "'"))).Count | Should -Be 1
        }
    }

    It 'downloads, verifies, unpacks and starts the installer with the options it was given' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $dest = Join-Path $script:Work 'kit1'
        $r = Invoke-Bootstrap -File $script:Boot -With @('-Destination', $dest, '-AppOrigin', 'https://app.blossom.example', '-PairingCode', 'K7QM-2XVD-9HTR-4BWN-6CPA', '-Domain', 'agency.io', '-WithAppium')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'SHA-256 verified'
        $r.Text | Should -Match 'the stand-in installer ran'
        Test-Path -LiteralPath (Join-Path $dest 'install.ps1') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $dest 'called-with.txt')) -join ' ' | Should -BeExactly '7 -AppOrigin https://app.blossom.example -PairingCode K7QM-2XVD-9HTR-4BWN-6CPA -Domain agency.io -WithAppium'
        Test-Path -LiteralPath ($dest + '.new') | Should -BeFalse
    }

    It 'replaces a kit that is there and keeps it as .previous' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $dest = Join-Path $script:Work 'kit1'
        Set-Content -LiteralPath (Join-Path $dest 'marker.txt') -Value 'kept from the first run'
        (Invoke-Bootstrap -File $script:Boot -With @('-Destination', $dest)).Code | Should -Be 0
        Test-Path -LiteralPath (Join-Path $dest 'marker.txt') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path ($dest + '.previous') 'marker.txt') | Should -BeExactly 'kept from the first run'
        (Get-Content -LiteralPath (Join-Path $dest 'called-with.txt'))[0] | Should -BeExactly '0'
    }

    It 'refuses an archive that was changed, and a list of checksums that was changed with it' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $rel = Join-Path $script:Release 'kit-v9.9.9'
        $good = Join-Path $script:Work 'good.zip'
        Copy-Item -LiteralPath (Join-Path $rel 'blossom-farm-kit-9.9.9.zip') -Destination $good -Force
        $goodSums = Get-Content -LiteralPath (Join-Path $rel 'SHA256SUMS') -Raw
        try {
            $null = New-StandInRelease -Extra 'Write-Host evil'
            $dest = Join-Path $script:Work 'kit2'
            $r = Invoke-Bootstrap -File $script:Boot -With @('-Destination', $dest)
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'SHA-256 is wrong'
            $r.Text | Should -Not -Match 'the stand-in installer ran'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Test-Path -LiteralPath ($dest + '.new') | Should -BeFalse
            Write-Sums
            $r = Invoke-Bootstrap -File $script:Boot -With @('-Destination', $dest)
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'list of checksums.*is not the one this file expects'
            Test-Path -LiteralPath $dest | Should -BeFalse
        } finally {
            Copy-Item -LiteralPath $good -Destination (Join-Path $rel 'blossom-farm-kit-9.9.9.zip') -Force
            [System.IO.File]::WriteAllText((Join-Path $rel 'SHA256SUMS'), $goodSums)
        }
        (Invoke-Bootstrap -File $script:Boot -With @('-Destination', (Join-Path $script:Work 'kit2'))).Code | Should -Be 0
    }

    It 'refuses a download address that is not https' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
        $plain = Join-Path $script:Work 'plain.ps1'
        New-Bootstrap -BaseUrl $script:PlainBase -OutFile $plain
        $r = Invoke-Bootstrap -File $plain -With @('-Destination', (Join-Path $script:Work 'kit3'))
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'not https'
        Test-Path -LiteralPath (Join-Path $script:Work 'kit3') | Should -BeFalse
    }
}
