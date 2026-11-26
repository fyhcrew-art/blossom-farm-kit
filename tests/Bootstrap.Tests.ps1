# Pester 5 tests for the chain of checks that brings a kit onto a Windows
# computer (the mirror of tests/bootstrap.test.sh): bootstrap.ps1, the
# functions of lib\FarmKit.psm1 behind scripts\update.ps1 -Latest, and
# scripts\update.ps1 -Check and -Latest run as a whole. A small stand-in for
# the kit is packed the way GitHub packs a commit and served over https by
# tests/fake-blossom.js; the scripts are run against it. scripts\update.ps1
# runs unchanged from a copy of the kit whose library has a few lines added
# at its end: they point it at the stand-in server and replace the checks
# that need Administrator rights and an installed farm.
#   Invoke-Pester .\tests
# Needs node and openssl and a trusted certificate, exactly as
# tests\Pairing.Tests.ps1 does (see the top of that file).

Describe 'bootstrap.ps1 and the kit it fetches' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\lib\FarmKit.psm1') -Force -DisableNameChecking
        $script:Skip = $null
        $script:Process = $null
        $script:TrustedCert = $null
        $script:Kit = Join-Path $PSScriptRoot '..'
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('farmkit-bootstrap-' + [Guid]::NewGuid().ToString('N'))
        $script:Static = Join-Path $script:Work 'static'
        $script:Shell = (Get-Process -Id $PID).Path
        $script:K = '1' * 40
        $script:K2 = '2' * 40
        $script:Zero = '0' * 64
        New-Item -ItemType Directory -Path (Join-Path $script:Static 'archive') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Static 'raw/main') -Force | Out-Null
        $onWindows = ($env:OS -eq 'Windows_NT')
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        function Get-Sha { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
        function Get-KitFileNames {
            param([string]$Folder)
            $full = (Get-Item -LiteralPath $Folder).FullName.TrimEnd('\', '/')
            $names = @(Get-ChildItem -LiteralPath $Folder -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($full.Length + 1) -replace '\\', '/' })
            [Array]::Sort($names, [System.StringComparer]::Ordinal)
            return $names
        }
        function Write-Manifest {
            # What tools/make-manifest.sh --tree does: the list, and its SHA-256 in bootstrap.ps1.
            param([string]$Folder)
            $lines = @()
            foreach ($name in (Get-KitFileNames -Folder $Folder)) {
                if (@('MANIFEST.sha256', 'bootstrap.sh', 'bootstrap.ps1', 'pairing.json') -ccontains $name) { continue }
                $lines += ((Get-Sha (Join-Path $Folder $name)) + '  ' + $name)
            }
            [System.IO.File]::WriteAllText((Join-Path $Folder 'MANIFEST.sha256'), (($lines -join "`n") + "`n"))
            $sum = Get-Sha (Join-Path $Folder 'MANIFEST.sha256')
            $boot = Join-Path $Folder 'bootstrap.ps1'
            $text = [System.IO.File]::ReadAllText($boot)
            $text = [regex]::Replace($text, '(?m)^\$KitManifestSha256 = ''[0-9a-f]*''', ('$KitManifestSha256 = ''' + $sum + ''''))
            [System.IO.File]::WriteAllText($boot, $text)
            return $sum
        }
        function New-StandIn {
            # A stand-in for the kit whose install.ps1 writes down how it was called.
            param([string]$Folder, [string]$Version = '9.9.9', [string]$ProviderSha = ('1' * 64))
            if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force }
            New-Item -ItemType Directory -Path (Join-Path $Folder 'lib') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $Folder 'scripts') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:Kit 'bootstrap.ps1'), (Join-Path $script:Kit 'bootstrap.sh') -Destination $Folder
            [System.IO.File]::WriteAllText((Join-Path $Folder 'versions.json'), ('{ "kit": "' + $Version + '", "gads": { "version": "v6.0.0", "hubExeSha256": "' + ('7' * 64) + '" }, "gadsDrag": { "version": "v6.0.0-drag.1", "url": "https://example.org/GADS-drag.exe", "sha256": "' + $ProviderSha + '" } }' + "`n"))
            [System.IO.File]::WriteAllText((Join-Path $Folder 'pairing.json'), ('{ "kitVersion": "0.0.1", "kitCommit": "' + ('0' * 40) + '" }' + "`n"))
            [System.IO.File]::WriteAllText((Join-Path $Folder 'lib/FarmKit.psm1'), "# a library`n")
            [System.IO.File]::WriteAllText((Join-Path $Folder 'scripts/update.ps1'), "# an update script`n")
            [System.IO.File]::WriteAllText((Join-Path $Folder 'install.ps1'), ('Set-Content -LiteralPath (Join-Path $PSScriptRoot ''called-with.txt'') -Value (@($args.Count) + $args)' + "`n" + 'Write-Host ''the stand-in installer ran''' + "`n"))
        }
        function Publish-Kit {
            # Packs a folder the way GitHub packs a commit: <repository>-<commit>/..., names with "/".
            param([string]$Folder, [string]$Commit, [string]$TopCommit = '', [hashtable]$Also = @{})
            if (-not $TopCommit) { $TopCommit = $Commit }
            $top = 'blossom-farm-kit-' + $TopCommit
            $zip = Join-Path (Join-Path $script:Static 'archive') ($Commit + '.zip')
            foreach ($old in @($zip, ($zip + '.cut'))) { if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force } }
            $stream = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew)
            $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $null = $archive.CreateEntry($top + '/')
                foreach ($name in (Get-KitFileNames -Folder $Folder)) {
                    $entry = $archive.CreateEntry($top + '/' + $name)
                    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Folder $name))
                    $out = $entry.Open(); $out.Write($bytes, 0, $bytes.Length); $out.Dispose()
                }
                foreach ($name in $Also.Keys) {
                    $entry = $archive.CreateEntry($name)
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$Also[$name])
                    $out = $entry.Open(); $out.Write($bytes, 0, $bytes.Length); $out.Dispose()
                }
            } finally { $archive.Dispose(); $stream.Dispose() }
            return $zip
        }
        function Invoke-Bootstrap {
            param([string]$File, [string[]]$With = @())
            $out = & $script:Shell -NoProfile -ExecutionPolicy Bypass -File $File @With 2>&1 | ForEach-Object { [string]$_ }
            return New-Object PSObject -Property @{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
        }
        function Assert-NoStagingFolder {
            # Nothing named <folder>.new... is left next to a kit folder.
            param([string]$Beside)
            $parent = Split-Path -Parent $Beside
            if (-not (Test-Path -LiteralPath $parent)) { return }
            @(Get-ChildItem -LiteralPath $parent -Force | Where-Object { $_.Name -like ((Split-Path -Leaf $Beside) + '.new*') }).Count | Should -Be 0
        }
        function Assert-Refused {
            # The bootstrap stops, says why, runs nothing and leaves nothing.
            param([string]$Commit, [string]$Pattern)
            $dest = Join-Path $script:Work ('refused-' + [Guid]::NewGuid().ToString('N'))
            $r = Invoke-Bootstrap -File $script:Boot -With @('-KitCommit', $Commit, '-Destination', $dest)
            $r.Code | Should -Be 1
            $r.Text | Should -Match $Pattern
            $r.Text | Should -Not -Match 'the stand-in installer ran'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Assert-NoStagingFolder -Beside $dest
            (Invoke-Bootstrap -File $script:Boot -With @('-KitCommit', $Commit, '-VerifyOnly')).Code | Should -Be 1
        }

        $script:Src = Join-Path $script:Work 'src'
        New-StandIn -Folder $script:Src
        $script:List = Write-Manifest -Folder $script:Src

        $node = (Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $node) { $script:Skip = 'node is not installed' }
        else {
            $dir = Join-Path $script:Work 'fake'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $list = @(('"' + (Join-Path $PSScriptRoot 'fake-blossom.js') + '"'), '--dir', ('"' + $dir + '"'), '--static', ('"' + $script:Static + '"'))
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
                $script:Base = 'https://127.0.0.1:' + $port + '/static'
                $script:PlainBase = 'http://127.0.0.1:' + $port + '/static'
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
            # The bootstrap file under test: the one of the stand-in kit (it carries
            # the SHA-256 of the stand-in's list), fetching from the stand-in server.
            $script:Boot = Join-Path $script:Work 'blossom-bootstrap.ps1'
            $text = [System.IO.File]::ReadAllText((Join-Path $script:Src 'bootstrap.ps1'))
            [System.IO.File]::WriteAllText($script:Boot, [regex]::Replace($text, '(?m)^\$KitArchiveUrl = ''[^'']*''', ('$KitArchiveUrl = ''' + $script:Base + '/archive''')))
            $script:PlainBoot = Join-Path $script:Work 'plain.ps1'
            [System.IO.File]::WriteAllText($script:PlainBoot, [regex]::Replace($text, '(?m)^\$KitArchiveUrl = ''[^'']*''', ('$KitArchiveUrl = ''' + $script:PlainBase + '/archive''')))
            $null = Publish-Kit -Folder $script:Src -Commit $script:K
            Set-KitSource -RawUrl ($script:Base + '/raw') -ArchiveUrl ($script:Base + '/archive')
            $probe = Invoke-Bootstrap -File $script:Boot -With @('-KitCommit', $script:K, '-VerifyOnly')
            if ($probe.Code -ne 0 -and -not $onWindows) { $script:Skip = 'PowerShell does not trust the certificate of the run: start it with SSL_CERT_FILE set (see the top of Pairing.Tests.ps1)' }
        }
        if ($script:Skip -and $env:FARMKIT_REQUIRE_STAND_IN) { throw ('FARMKIT_REQUIRE_STAND_IN is set, and the stand-in server cannot be used: ' + $script:Skip) }
        if ($script:Skip) { Write-Warning ('The tests against a stand-in server are skipped: ' + $script:Skip) }
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

    Context 'the kit and its list of files' {
        It 'the bootstrap files carry the SHA-256 of MANIFEST.sha256' {
            $sum = Get-Sha (Join-Path $script:Kit 'MANIFEST.sha256')
            foreach ($f in @('bootstrap.ps1', 'bootstrap.sh')) {
                ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:Kit $f)), "'" + $sum + "'")).Count | Should -Be 1
            }
        }
        It 'the list names the files of the kit, and not the four that cannot be on it' {
            $names = @([System.IO.File]::ReadAllLines((Join-Path $script:Kit 'MANIFEST.sha256')) | ForEach-Object { ($_ -split '  ', 2)[1] })
            $names | Should -Contain 'install.ps1'
            $names | Should -Contain 'lib/FarmKit.psm1'
            foreach ($f in @('MANIFEST.sha256', 'bootstrap.ps1', 'bootstrap.sh', 'pairing.json')) { $names | Should -Not -Contain $f }
        }
        It 'bootstrap.ps1 is the same bytes in a checkout, in the archive and when fetched by itself (no CR)' {
            ([System.IO.File]::ReadAllBytes((Join-Path $script:Kit 'bootstrap.ps1')) -contains 13) | Should -BeFalse
        }
    }

    Context 'Test-KitTree' {
        It 'passes an unchanged kit' {
            Test-KitTree -Path $script:Src -ManifestSha256 $script:List | Should -BeNullOrEmpty
        }
        It 'refuses another list than the expected one' {
            Test-KitTree -Path $script:Src -ManifestSha256 ('5' * 64) | Should -Match 'not the expected one'
        }
        It 'names a changed file, a file too many and a missing file' {
            $t = Join-Path $script:Work 't1'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            Add-Content -LiteralPath (Join-Path $t 'install.ps1') -Value 'Write-Host evil'
            Test-KitTree -Path $t -ManifestSha256 $script:List | Should -Match 'install.ps1 is not the one the list names'
            $t = Join-Path $script:Work 't2'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            Set-Content -LiteralPath (Join-Path $t 'scripts/extra.ps1') -Value 'x'
            Test-KitTree -Path $t -ManifestSha256 $script:List | Should -Match 'does not name: scripts/extra.ps1'
            $t = Join-Path $script:Work 't3'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            Remove-Item -LiteralPath (Join-Path $t 'lib/FarmKit.psm1')
            Test-KitTree -Path $t -ManifestSha256 $script:List | Should -Match 'lib/FarmKit.psm1 is missing'
        }
        It 'refuses a list that points outside the kit' {
            $t = Join-Path $script:Work 't5'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            [System.IO.File]::AppendAllText((Join-Path $t 'MANIFEST.sha256'), (('3' * 64) + "  ../outside`n"))
            Test-KitTree -Path $t -ManifestSha256 (Get-Sha (Join-Path $t 'MANIFEST.sha256')) | Should -Match 'not a checksum and a file name'
        }
        It 'names a folder that holds no file of the list' {
            $t = Join-Path $script:Work 't7'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            New-Item -ItemType Directory -Path (Join-Path $t 'services/node_modules') -Force | Out-Null
            Test-KitTree -Path $t -ManifestSha256 $script:List | Should -Match 'a folder that its list names no file for: services'
            $t = Join-Path $script:Work 't8'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            New-Item -ItemType Directory -Path (Join-Path $t 'lib/deeper') -Force | Out-Null
            Test-KitTree -Path $t -ManifestSha256 $script:List | Should -Match 'a folder that its list names no file for: lib/deeper'
        }
        It 'does not count the files that cannot be on the list' {
            $t = Join-Path $script:Work 't6'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            Add-Content -LiteralPath (Join-Path $t 'bootstrap.sh') -Value 'changed'
            Remove-Item -LiteralPath (Join-Path $t 'pairing.json')
            Test-KitTree -Path $t -ManifestSha256 $script:List | Should -BeNullOrEmpty
        }
    }

    Context 'Test-KitUpdateRule and Compare-KitVersion' {
        BeforeAll {
            $script:Old = Get-Content -LiteralPath (Join-Path $script:Src 'versions.json') -Raw | ConvertFrom-Json
            function Get-Changed { param([string]$From, [string]$To) return ((Get-Content -LiteralPath (Join-Path $script:Src 'versions.json') -Raw).Replace('"kit": "9.9.9"', '"kit": "9.9.10"').Replace($From, $To) | ConvertFrom-Json) }
        }
        It 'compares dotted versions as numbers' {
            Compare-KitVersion -Have '1.10.0' -Want '1.9.9' | Should -Be 1
            Compare-KitVersion -Have '1.0' -Want '1.0.0' | Should -Be 0
            Compare-KitVersion -Have '1.0.0' -Want '1.0.1' | Should -Be -1
        }
        It 'accepts a newer kit with the same pins' {
            Test-KitUpdateRule -Current $script:Old -New (Get-Changed 'nothing' 'nothing') | Should -BeNullOrEmpty
        }
        It 'refuses the same and an older version' {
            Test-KitUpdateRule -Current $script:Old -New $script:Old | Should -Match 'not newer'
            Test-KitUpdateRule -Current (Get-Changed 'nothing' 'nothing') -New $script:Old | Should -Match 'not newer'
        }
        It 'refuses another file under a program version this kit pins, and accepts it under a new version' {
            Test-KitUpdateRule -Current $script:Old -New (Get-Changed ('1' * 64) ('2' * 64)) | Should -Match 'pins another file for the provider v6.0.0-drag.1.*gadsDrag.sha256'
            $renamed = (Get-Content -LiteralPath (Join-Path $script:Src 'versions.json') -Raw).Replace('"kit": "9.9.9"', '"kit": "9.9.10"').Replace(('1' * 64), ('2' * 64)).Replace('v6.0.0-drag.1', 'v6.0.0-drag.2') | ConvertFrom-Json
            Test-KitUpdateRule -Current $script:Old -New $renamed | Should -BeNullOrEmpty
            Test-KitUpdateRule -Current $script:Old -New (Get-Changed ('7' * 64) ('8' * 64)) | Should -Match 'pins another file for GADS v6.0.0'
        }
        It 'refuses a kit version in another spelling (sideways), like the bash twin' {
            foreach ($v in @('9.9.9.0', '9.9.09', '09.9.9', '9.9.9.0.9', '9.9', '9.9.9.', '9.9.10.0', '9.10', '010.0.0', '9.9.10 ', '10.0.0-1')) {
                Test-KitUpdateRule -Current $script:Old -New (Get-Changed '"kit": "9.9.10"' ('"kit": "' + $v + '"')) | Should -Match 'no usable kit version' -Because $v
            }
            $odd = (Get-Content -LiteralPath (Join-Path $script:Src 'versions.json') -Raw).Replace('"kit": "9.9.9"', '"kit": "9.9"') | ConvertFrom-Json
            Test-KitUpdateRule -Current $odd -New (Get-Changed 'nothing' 'nothing') | Should -Match 'not newer'
        }
        It 'refuses a program version that is not written the one way, so that a file cannot change under a respelled version' {
            foreach ($v in @('V6.0.0-drag.1', 'v6.0.0-drag.1 ', 'v6.0.0-DRAG.1', '6.0.0-drag.1', 'v6.0.0 drag')) {
                $new = (Get-Content -LiteralPath (Join-Path $script:Src 'versions.json') -Raw).Replace('"kit": "9.9.9"', '"kit": "9.9.10"').Replace('"version": "v6.0.0-drag.1"', ('"version": "' + $v + '"')).Replace(('1' * 64), ('2' * 64)) | ConvertFrom-Json
                Test-KitUpdateRule -Current $script:Old -New $new | Should -Match 'gadsDrag.version is not written like a version' -Because $v
            }
            Test-KitUpdateRule -Current $script:Old -New (Get-Changed '"version": "v6.0.0"' '"version": "V6.0.0"') | Should -Match 'gads.version is not written like a version'
            Test-KitUpdateRule -Current $script:Old -New ('{ "kit": "9.9.10" }' | ConvertFrom-Json) | Should -Match 'gads.version is not written like a version'
        }
        It 'Test-KitVersionText and Test-ProgramVersionText accept one spelling only' {
            Test-KitVersionText -Text '0.0.1' | Should -BeTrue
            foreach ($v in @('1.0', '1.0.0.0', '01.0.0', '1.0.0.', ' 1.0.0', '1.0.1234567', '', 'latest')) { Test-KitVersionText -Text $v | Should -BeFalse -Because $v }
            Test-ProgramVersionText -Text 'v6.0.0' | Should -BeTrue
            Test-ProgramVersionText -Text 'v6.0.0-drag.12' | Should -BeTrue
            foreach ($v in @('V6.0.0', 'v6.0.0-', '', 'v6.0.0 ')) { Test-ProgramVersionText -Text $v | Should -BeFalse -Because $v }
            Get-KitVersionLine -Versions $script:Old | Should -BeExactly 'kit 9.9.9, hub v6.0.0, provider v6.0.0-drag.1'
        }
        It 'New-KitStagingFolder: a new, empty folder with a name that cannot be guessed; never one that exists' {
            $beside = Join-Path $script:Work 'staging-kit'
            $a = New-KitStagingFolder -Beside $beside
            $b = New-KitStagingFolder -Beside ($beside + '/')
            $a.Error | Should -BeNullOrEmpty
            $a.Ok | Should -BeTrue
            $b.Ok | Should -BeTrue
            (Split-Path -Leaf $a.Path) | Should -Match '^staging-kit\.new-[0-9a-f]{32}$'
            (Split-Path -Leaf $b.Path) | Should -Match '^staging-kit\.new-[0-9a-f]{32}$'
            $a.Path | Should -Not -Be $b.Path
            Test-Path -LiteralPath $a.Path -PathType Container | Should -BeTrue
            @(Get-ChildItem -LiteralPath $a.Path -Force).Count | Should -Be 0
            $planted = $beside + '.new-planted'
            New-Item -ItemType Directory -Path $planted | Out-Null
            Set-Content -LiteralPath (Join-Path $planted 'install.ps1') -Value 'planted'
            $c = New-KitStagingFolder -Beside $beside -Suffix 'planted'
            $c.Ok | Should -BeFalse
            $c.Error | Should -Match 'exists already'
            Get-Content -LiteralPath (Join-Path $planted 'install.ps1') | Should -BeExactly 'planted'
        }
        It 'the scripts never use a staging folder with a fixed name' {
            foreach ($f in @('bootstrap.ps1', 'scripts/update.ps1', 'lib/FarmKit.psm1')) {
                [System.IO.File]::ReadAllText((Join-Path $script:Kit $f)) | Should -Not -Match "\+ '\.new'" -Because $f
            }
        }
        It 'refuses a download address that is not https, and a version that is not a number' {
            Test-KitUpdateRule -Current $script:Old -New (Get-Changed 'https://example.org' 'http://example.org') | Should -Match 'gadsDrag.url is not https'
            Test-KitUpdateRule -Current $script:Old -New ('{ "kit": "latest" }' | ConvertFrom-Json) | Should -Match 'no usable kit version'
        }
        It 'reads the real versions.json: one changed pin for another system is enough to refuse a successor' {
            $text = Get-Content -LiteralPath (Join-Path $script:Kit 'versions.json') -Raw
            $real = $text | ConvertFrom-Json
            $next = [regex]::Replace($text, '"kit": "[0-9.]*"', '"kit": "999.0.0"')
            Test-KitUpdateRule -Current $real -New $real | Should -Match 'not newer'
            Test-KitUpdateRule -Current $real -New ($next | ConvertFrom-Json) | Should -BeNullOrEmpty
            Test-KitUpdateRule -Current $real -New ($next.Replace([string]$real.macos.x86_64.provider.sha256, ('9' * 64)) | ConvertFrom-Json) | Should -Match 'macos.x86_64.provider.sha256'
        }
    }

    Context 'bootstrap.ps1' {
        It 'refuses to run without a commit, with a branch name, with a short commit' {
            $never = Join-Path $script:Work 'never'
            $boot = Join-Path $script:Kit 'bootstrap.ps1'
            $r = Invoke-Bootstrap -File $boot -With @('-Destination', $never)
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'KitCommit'
            (Invoke-Bootstrap -File $boot -With @('-KitCommit', 'main', '-Destination', $never)).Code | Should -Be 1
            (Invoke-Bootstrap -File $boot -With @('-KitCommit', ('1' * 39), '-Destination', $never)).Code | Should -Be 1
            Test-Path -LiteralPath $never | Should -BeFalse
        }

        It 'downloads, checks, unpacks and starts the installer with the options it was given' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $dest = Join-Path $script:Work 'kit1'
            $r = Invoke-Bootstrap -File $script:Boot -With @('-KitCommit', $script:K, '-Destination', $dest, '-AppOrigin', 'https://app.blossom.example', '-PairingCode', 'K7QM-2XVD-9HTR-4BWN-6CPA', '-Domain', 'agency.io', '-WithAppium')
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'every one of its 4 files has the SHA-256'
            $r.Text | Should -Match 'the stand-in installer ran'
            Test-Path -LiteralPath (Join-Path $dest 'install.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $dest 'MANIFEST.sha256') | Should -BeTrue
            foreach ($f in @('bootstrap.ps1', 'bootstrap.sh', 'pairing.json')) { Test-Path -LiteralPath (Join-Path $dest $f) | Should -BeFalse }
            (Get-Content -LiteralPath (Join-Path $dest 'called-with.txt')) -join ' ' | Should -BeExactly '7 -AppOrigin https://app.blossom.example -PairingCode K7QM-2XVD-9HTR-4BWN-6CPA -Domain agency.io -WithAppium'
            Assert-NoStagingFolder -Beside $dest
        }

        It 'replaces a kit that is there and keeps it as .previous' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $dest = Join-Path $script:Work 'kit1'
            Set-Content -LiteralPath (Join-Path $dest 'marker.txt') -Value 'kept from the first run'
            (Invoke-Bootstrap -File $script:Boot -With @('-KitCommit', $script:K, '-Destination', $dest)).Code | Should -Be 0
            Test-Path -LiteralPath (Join-Path $dest 'marker.txt') | Should -BeFalse
            Get-Content -LiteralPath (Join-Path ($dest + '.previous') 'marker.txt') | Should -BeExactly 'kept from the first run'
            (Get-Content -LiteralPath (Join-Path $dest 'called-with.txt'))[0] | Should -BeExactly '0'
        }

        It '-VerifyOnly checks the whole chain and installs nothing' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $dest = Join-Path $script:Work 'kit-verify'
            $r = Invoke-Bootstrap -File $script:Boot -With @('-KitCommit', $script:K, '-VerifyOnly', '-Destination', $dest, '-AppOrigin', 'https://app.blossom.example')
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'every one of its 4 files'
            $r.Text | Should -Match 'nothing was installed'
            $r.Text | Should -Not -Match 'the stand-in installer ran'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Assert-NoStagingFolder -Beside $dest
        }

        It 'refuses a changed file, also when the list was rewritten to match' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $evil = Join-Path $script:Work 'evil'; Copy-Item -LiteralPath $script:Src -Destination $evil -Recurse
            Add-Content -LiteralPath (Join-Path $evil 'install.ps1') -Value 'Write-Host evil'
            $null = Publish-Kit -Folder $evil -Commit $script:K2
            Assert-Refused -Commit $script:K2 -Pattern 'install.ps1 of the kit that was downloaded is not the one the list names'
            $null = Write-Manifest -Folder $evil
            $null = Publish-Kit -Folder $evil -Commit $script:K2
            Assert-Refused -Commit $script:K2 -Pattern 'list of files.*is not the one this file expects'
        }

        It 'refuses a file too many, a missing file and a kit without a list' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $t = Join-Path $script:Work 'evil2'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            Set-Content -LiteralPath (Join-Path $t 'scripts/extra.ps1') -Value 'Write-Host evil'
            $null = Publish-Kit -Folder $t -Commit $script:K2
            Assert-Refused -Commit $script:K2 -Pattern 'a file that its list does not name: scripts/extra.ps1'
            $t = Join-Path $script:Work 'evil3'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            Remove-Item -LiteralPath (Join-Path $t 'lib/FarmKit.psm1')
            $null = Publish-Kit -Folder $t -Commit $script:K2
            Assert-Refused -Commit $script:K2 -Pattern 'lacks the file lib/FarmKit.psm1'
            $t = Join-Path $script:Work 'evil5'; Copy-Item -LiteralPath $script:Src -Destination $t -Recurse
            Remove-Item -LiteralPath (Join-Path $t 'MANIFEST.sha256')
            $null = Publish-Kit -Folder $t -Commit $script:K2
            Assert-Refused -Commit $script:K2 -Pattern 'no MANIFEST.sha256'
        }

        It 'refuses a folder that holds no file of the list' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $null = Publish-Kit -Folder $script:Src -Commit $script:K2 -Also @{ ('blossom-farm-kit-' + $script:K2 + '/services/node_modules/') = '' }
            Assert-Refused -Commit $script:K2 -Pattern 'a folder that its list names no file for: services'
        }

        It 'refuses an archive with an entry outside the folder of the commit, before unpacking' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $null = Publish-Kit -Folder $script:Src -Commit $script:K2 -Also @{ 'other/file' = 'x' }
            Assert-Refused -Commit $script:K2 -Pattern 'outside the folder of this commit'
            $null = Publish-Kit -Folder $script:Src -Commit $script:K2 -Also @{ ('blossom-farm-kit-' + $script:K2 + '/../escape') = 'x' }
            Assert-Refused -Commit $script:K2 -Pattern 'outside the folder of this commit'
            Test-Path -LiteralPath (Join-Path $script:Work 'escape') | Should -BeFalse
            $null = Publish-Kit -Folder $script:Src -Commit $script:K2 -Also @{ ('blossom-farm-kit-' + $script:K2 + '\lib\back.ps1') = 'x' }
            Assert-Refused -Commit $script:K2 -Pattern 'outside the folder of this commit'
        }

        It 'refuses a kit whose list was not regenerated after a change' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $stale = Join-Path $script:Work 'stale'; Copy-Item -LiteralPath $script:Src -Destination $stale -Recurse
            Add-Content -LiteralPath (Join-Path $stale 'scripts/update.ps1') -Value '# a later change'
            $null = Publish-Kit -Folder $stale -Commit $script:K2
            Assert-Refused -Commit $script:K2 -Pattern 'scripts/update.ps1 of the kit that was downloaded is not the one the list names'
        }

        It 'refuses the kit of another commit' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $other = Join-Path $script:Work 'other'
            New-StandIn -Folder $other -Version '9.9.8'
            $null = Write-Manifest -Folder $other
            $null = Publish-Kit -Folder $other -Commit $script:K2
            Assert-Refused -Commit $script:K2 -Pattern 'list of files.*is not the one this file expects'
            $null = Publish-Kit -Folder $script:Src -Commit $script:K2 -TopCommit $script:K
            Assert-Refused -Commit $script:K2 -Pattern 'outside the folder of this commit'
            Assert-Refused -Commit ('3' * 40) -Pattern 'Downloading the kit failed'
        }

        It 'refuses a download that was cut short' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $zip = Publish-Kit -Folder $script:Src -Commit $script:K2
            $bytes = [System.IO.File]::ReadAllBytes($zip)
            [System.IO.File]::WriteAllText(($zip + '.cut'), [string][int]($bytes.Length / 2))
            Assert-Refused -Commit $script:K2 -Pattern 'Downloading the kit failed|incomplete or damaged'
            Remove-Item -LiteralPath ($zip + '.cut') -Force
            $half = New-Object byte[] ([int]($bytes.Length / 2))
            [Array]::Copy($bytes, $half, $half.Length)
            [System.IO.File]::WriteAllBytes($zip, $half)
            Assert-Refused -Commit $script:K2 -Pattern 'incomplete or damaged'
            [System.IO.File]::WriteAllBytes($zip, (New-Object byte[] 0))
            Assert-Refused -Commit $script:K2 -Pattern 'incomplete or damaged'
            $null = Publish-Kit -Folder $script:Src -Commit $script:K2
            (Invoke-Bootstrap -File $script:Boot -With @('-KitCommit', $script:K2, '-VerifyOnly')).Code | Should -Be 0
        }

        It 'refuses a download address that is not https' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $r = Invoke-Bootstrap -File $script:PlainBoot -With @('-KitCommit', $script:K, '-Destination', (Join-Path $script:Work 'kit3'))
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'not https'
            Test-Path -LiteralPath (Join-Path $script:Work 'kit3') | Should -BeFalse
        }
    }

    Context 'a newer kit (update.ps1 -Latest)' {
        BeforeAll {
            function Set-Main {
                param([string]$Versions, [string]$Pairing)
                foreach ($pair in @(@('versions.json', $Versions), @('pairing.json', $Pairing))) {
                    $file = Join-Path (Join-Path $script:Static 'raw/main') $pair[0]
                    if ($pair[1]) { [System.IO.File]::WriteAllText($file, $pair[1]) }
                    elseif (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
                }
            }
            function New-WorkFolder { $w = Join-Path $script:Work ('w-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $w -Force | Out-Null; return $w }
            $script:Versions = Get-Content -LiteralPath (Join-Path $script:Src 'versions.json') -Raw
            $script:Pairing = '{ "kitVersion": "9.9.9", "kitCommit": "' + $script:K + '", "manifestSha256": "' + $script:List + '" }'
        }

        It 'Get-ReleasedKit: reads version, commit and the SHA-256 of the list from main' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            Set-Main -Versions $script:Versions -Pairing $script:Pairing
            $r = Get-ReleasedKit -WorkFolder (New-WorkFolder)
            $r.Ok | Should -BeTrue
            $r.Version | Should -BeExactly '9.9.9'
            $r.Commit | Should -BeExactly $script:K
            $r.ManifestSha256 | Should -BeExactly $script:List
        }
        It 'Get-ReleasedKit: a version that pairing.json does not name yet is not released' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            Set-Main -Versions $script:Versions.Replace('"kit": "9.9.9"', '"kit": "9.9.10"') -Pairing $script:Pairing
            $r = Get-ReleasedKit -WorkFolder (New-WorkFolder)
            $r.Ok | Should -BeTrue
            $r.Version | Should -BeExactly '9.9.10'
            $r.Commit | Should -BeNullOrEmpty
            Set-Main -Versions $script:Versions -Pairing ''
            $r = Get-ReleasedKit -WorkFolder (New-WorkFolder)
            $r.Ok | Should -BeTrue
            $r.Commit | Should -BeNullOrEmpty
        }
        It 'Get-ReleasedKit: a pairing.json without a commit, and a main that cannot be read, are errors' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            Set-Main -Versions $script:Versions -Pairing $script:Pairing.Replace($script:K, 'main')
            $r = Get-ReleasedKit -WorkFolder (New-WorkFolder)
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'does not name a commit'
            Set-Main -Versions '' -Pairing $script:Pairing
            $r = Get-ReleasedKit -WorkFolder (New-WorkFolder)
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'could not be read'
        }
        It 'Save-KitCommit: downloads and checks the kit of a commit' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $null = Publish-Kit -Folder $script:Src -Commit $script:K
            $w = New-WorkFolder
            $r = Save-KitCommit -Commit $script:K -ManifestSha256 $script:List -WorkFolder $w
            $r.Error | Should -BeNullOrEmpty
            $r.Ok | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $r.Path 'install.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $r.Path 'bootstrap.ps1') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $r.Path 'pairing.json') | Should -BeFalse
            @(Get-ChildItem -LiteralPath $w -Force).Count | Should -Be 1
        }
        It 'Save-KitCommit: refuses a changed kit, a stale list, another commit, a cut download; leaves nothing' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            $w = New-WorkFolder
            $r = Save-KitCommit -Commit $script:K -ManifestSha256 ('4' * 64) -WorkFolder $w
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'not the expected one'
            @(Get-ChildItem -LiteralPath $w -Force).Count | Should -Be 0
            $evil = Join-Path $script:Work 'evil-u'; Copy-Item -LiteralPath $script:Src -Destination $evil -Recurse
            Add-Content -LiteralPath (Join-Path $evil 'scripts/update.ps1') -Value '# changed'
            $null = Publish-Kit -Folder $evil -Commit $script:K2
            $r = Save-KitCommit -Commit $script:K2 -ManifestSha256 $script:List -WorkFolder (New-WorkFolder)
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'scripts/update.ps1 is not the one the list names'
            $null = Publish-Kit -Folder $script:Src -Commit $script:K2 -TopCommit $script:K
            (Save-KitCommit -Commit $script:K2 -ManifestSha256 $script:List -WorkFolder (New-WorkFolder)).Error | Should -Match 'does not belong to the kit'
            $zip = Publish-Kit -Folder $script:Src -Commit $script:K2
            $bytes = [System.IO.File]::ReadAllBytes($zip)
            $half = New-Object byte[] ([int]($bytes.Length / 2))
            [Array]::Copy($bytes, $half, $half.Length)
            [System.IO.File]::WriteAllBytes($zip, $half)
            (Save-KitCommit -Commit $script:K2 -ManifestSha256 $script:List -WorkFolder (New-WorkFolder)).Error | Should -Match 'incomplete or damaged'
            (Save-KitCommit -Commit 'main' -ManifestSha256 $script:List -WorkFolder (New-WorkFolder)).Ok | Should -BeFalse
            (Save-KitCommit -Commit ('3' * 40) -ManifestSha256 $script:List -WorkFolder (New-WorkFolder)).Error | Should -Match 'could not be downloaded'
            $null = Publish-Kit -Folder $script:Src -Commit $script:K2 -Also @{ ('blossom-farm-kit-' + $script:K2 + '/extra-folder/') = '' }
            (Save-KitCommit -Commit $script:K2 -ManifestSha256 $script:List -WorkFolder (New-WorkFolder)).Error | Should -Match 'names no file for: extra-folder'
        }
    }

    # scripts\update.ps1 as a whole. The installed kit is a stand-in (version
    # 9.9.9) with the real lib\FarmKit.psm1 and scripts\update.ps1. The lines
    # added to the END of its library are the only difference to what runs on
    # a farm: where the kit is looked for, and no check for Administrator
    # rights, the kit folder's place and an installed farm. The kit that is
    # fetched is another stand-in whose scripts\update.ps1 writes down how it
    # was called.
    Context 'scripts\update.ps1 -Check and -Latest, run as a whole' {
        BeforeAll {
            $script:U = Join-Path $script:Work 'u'
            $script:Opt = Join-Path $script:U 'opt'
            $script:Inst = Join-Path $script:Opt 'blossom-farm-kit'
            $script:Farm = Join-Path $script:U 'farm'
            $script:K3 = '4' * 40
            $script:Next = Join-Path $script:Work 'next'
            function New-Installed {
                if (Test-Path -LiteralPath $script:U) { Remove-Item -LiteralPath $script:U -Recurse -Force }
                New-Item -ItemType Directory -Path $script:Opt -Force | Out-Null
                New-Item -ItemType Directory -Path $script:Farm -Force | Out-Null
                New-StandIn -Folder $script:Inst
                $added = @(
                    '# --- added by tests/Bootstrap.Tests.ps1 ---',
                    ('$script:KitSource.RawUrl = ''' + $script:Base + '/raw'''),
                    ('$script:KitSource.ArchiveUrl = ''' + $script:Base + '/archive'''),
                    'function Assert-Administrator { }',
                    'function Protect-KitFolder { param([string]$KitRoot) $null = $KitRoot }',
                    ('function Get-FarmPaths { return (New-Object PSObject -Property @{ Root = ''' + $script:Farm + ''' }) }'),
                    'function Read-FarmConfig { param($Paths) if (Test-Path -LiteralPath (Join-Path $Paths.Root ''installed'')) { return (New-Object PSObject -Property @{ kit = ''9.9.9'' }) }; return $null }',
                    'Export-ModuleMember -Function *'
                ) -join "`n"
                $lib = [System.IO.File]::ReadAllText((Join-Path $script:Kit 'lib/FarmKit.psm1'))
                $at = $lib.LastIndexOf('Export-ModuleMember -Function *')
                $at | Should -BeGreaterThan 0
                [System.IO.File]::WriteAllText((Join-Path $script:Inst 'lib/FarmKit.psm1'), ($lib.Substring(0, $at) + $added + "`n"))
                Copy-Item -LiteralPath (Join-Path $script:Kit 'scripts/update.ps1') -Destination (Join-Path $script:Inst 'scripts/update.ps1') -Force
                Set-Content -LiteralPath (Join-Path $script:Farm 'installed') -Value 'yes'
            }
            function New-Next {
                # The kit that main will announce; the SHA-256 of its list goes to $script:NextList.
                param([string]$Version = '9.9.10', [string]$ProviderSha = ('1' * 64), [string]$ProviderVersion = '')
                New-StandIn -Folder $script:Next -Version $Version -ProviderSha $ProviderSha
                if ($ProviderVersion) {
                    $file = Join-Path $script:Next 'versions.json'
                    [System.IO.File]::WriteAllText($file, [System.IO.File]::ReadAllText($file).Replace('v6.0.0-drag.1', $ProviderVersion))
                }
                [System.IO.File]::WriteAllText((Join-Path $script:Next 'scripts/update.ps1'), ('Set-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) ''update-called.txt'') -Value (@($args.Count) + $args)' + "`n" + 'Write-Host ''the update script of the new kit ran''' + "`n"))
                $script:NextList = Write-Manifest -Folder $script:Next
            }
            function Set-Announced {
                param([string]$Version, [string]$PairingVersion, [string]$Commit = $script:K3)
                $versions = [regex]::Replace([System.IO.File]::ReadAllText((Join-Path $script:Next 'versions.json')), '"kit": "[^"]*"', ('"kit": "' + $Version + '"'))
                [System.IO.File]::WriteAllText((Join-Path $script:Static 'raw/main/versions.json'), $versions)
                [System.IO.File]::WriteAllText((Join-Path $script:Static 'raw/main/pairing.json'), ('{ "kitVersion": "' + $PairingVersion + '", "kitCommit": "' + $Commit + '", "manifestSha256": "' + $script:NextList + '" }'))
            }
            function Get-Tree {
                param([string]$Folder)
                $full = (Get-Item -LiteralPath $Folder).FullName.TrimEnd('\', '/')
                $lines = @(Get-ChildItem -LiteralPath $Folder -Recurse -Force | ForEach-Object {
                        $name = $_.FullName.Substring($full.Length + 1) -replace '\\', '/'
                        if ($_.PSIsContainer) { $name + '/' } else { $name + ' ' + (Get-Sha $_.FullName) }
                    })
                [Array]::Sort($lines, [System.StringComparer]::Ordinal)
                return ($lines -join "`n")
            }
            function Invoke-Update { param([string[]]$With = @()) return (Invoke-Bootstrap -File (Join-Path $script:Inst 'scripts/update.ps1') -With $With) }
            function Assert-Unchanged {
                # The installed kit is the one from before, nothing is next to it, nothing of the fetched kit ran.
                param($Result)
                Get-Tree -Folder $script:Inst | Should -BeExactly $script:Before
                @(Get-ChildItem -LiteralPath $script:Opt -Force).Count | Should -Be 1
                $Result.Text | Should -Not -Match 'the update script of the new kit ran'
            }
            if (-not $script:Skip) {
                New-Next
                $null = Publish-Kit -Folder $script:Next -Commit $script:K3
                New-Installed
                $script:Before = Get-Tree -Folder $script:Inst
            }
        }

        It '-Check says that a newer kit is released, and changes nothing' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            Set-Announced -Version '9.9.10' -PairingVersion '9.9.10'
            $r = Invoke-Update -With @('-Check')
            $r.Code | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'Kit 9\.9\.10 is available \(commit 4444'
            Assert-Unchanged $r
        }
        It '-Latest fetches nothing for the same version, an older one, or one that is not released yet' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            foreach ($v in @('9.9.9', '9.9.8')) {
                Set-Announced -Version $v -PairingVersion $v
                $r = Invoke-Update -With @('-Latest')
                $r.Code | Should -Be 0
                $r.Text | Should -Match 'This kit is the newest one'
                Assert-Unchanged $r
            }
            Set-Announced -Version '9.9.10' -PairingVersion '9.9.9'
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'being prepared'
            Assert-Unchanged $r
        }
        It '-Latest refuses a kit version on main in another spelling' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            foreach ($v in @('9.9.9.1', '9.9.10.0', '9.10', '09.9.10', 'latest')) {
                Set-Announced -Version $v -PairingVersion $v
                $r = Invoke-Update -With @('-Latest')
                $r.Code | Should -Be 1 -Because $v
                $r.Text | Should -Match 'names no kit version'
                Assert-Unchanged $r
            }
        }
        It '-Latest refuses a kit that says another version than main announced' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            Set-Announced -Version '9.9.11' -PairingVersion '9.9.11'
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'says it is kit 9\.9\.10, but the repository announced kit 9\.9\.11'
            Assert-Unchanged $r
        }
        It '-Latest refuses a changed archive, a folder too many, a cut download and a missing commit' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            Set-Announced -Version '9.9.10' -PairingVersion '9.9.10'
            $evil = Join-Path $script:Work 'next-evil'; Copy-Item -LiteralPath $script:Next -Destination $evil -Recurse
            Add-Content -LiteralPath (Join-Path $evil 'scripts/update.ps1') -Value 'Write-Host evil'
            $null = Publish-Kit -Folder $evil -Commit $script:K3
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'did not pass its check.*scripts/update.ps1 is not the one the list names'
            Assert-Unchanged $r
            $null = Write-Manifest -Folder $evil
            $null = Publish-Kit -Folder $evil -Commit $script:K3
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'list of files is not the expected one'
            Assert-Unchanged $r
            $null = Publish-Kit -Folder $script:Next -Commit $script:K3 -Also @{ ('blossom-farm-kit-' + $script:K3 + '/extra-folder/') = '' }
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'names no file for: extra-folder'
            Assert-Unchanged $r
            $zip = Publish-Kit -Folder $script:Next -Commit $script:K3
            $bytes = [System.IO.File]::ReadAllBytes($zip)
            [System.IO.File]::WriteAllText(($zip + '.cut'), [string][int]($bytes.Length / 2))
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'could not be downloaded|incomplete or damaged'
            Assert-Unchanged $r
            Remove-Item -LiteralPath ($zip + '.cut') -Force
            $half = New-Object byte[] ([int]($bytes.Length / 2))
            [Array]::Copy($bytes, $half, $half.Length)
            [System.IO.File]::WriteAllBytes($zip, $half)
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'incomplete or damaged'
            Assert-Unchanged $r
            Set-Announced -Version '9.9.10' -PairingVersion '9.9.10' -Commit ('5' * 40)
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            Assert-Unchanged $r
        }
        It '-Latest refuses another provider file under the provider version this kit pins, also under a respelled version' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            New-Next -ProviderSha ('2' * 64)
            $null = Publish-Kit -Folder $script:Next -Commit $script:K3
            Set-Announced -Version '9.9.10' -PairingVersion '9.9.10'
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'was refused\. It pins another file for the provider v6\.0\.0-drag\.1'
            Assert-Unchanged $r
            New-Next -ProviderSha ('2' * 64) -ProviderVersion 'V6.0.0-drag.1'
            $null = Publish-Kit -Folder $script:Next -Commit $script:K3
            Set-Announced -Version '9.9.10' -PairingVersion '9.9.10'
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'was refused\. Its gadsDrag\.version is not written like a version'
            Assert-Unchanged $r
        }
        It '-Latest refuses to fetch anything on a computer without a farm, and two options at a time' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            New-Next
            $null = Publish-Kit -Folder $script:Next -Commit $script:K3
            Set-Announced -Version '9.9.10' -PairingVersion '9.9.10'
            Remove-Item -LiteralPath (Join-Path $script:Farm 'installed') -Force
            $r = Invoke-Update -With @('-Latest')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'no farm installation'
            Assert-Unchanged $r
            Set-Content -LiteralPath (Join-Path $script:Farm 'installed') -Value 'yes'
            $r = Invoke-Update -With @('-Check', '-Latest')
            $r.Code | Should -Be 1
            Assert-Unchanged $r
        }
        It '-Latest fetches a newer kit, checks it, shows what changes, puts it in place and continues with it' {
            if ($script:Skip) { Set-ItResult -Skipped -Because $script:Skip; return }
            New-Next
            $null = Publish-Kit -Folder $script:Next -Commit $script:K3
            Set-Announced -Version '9.9.10' -PairingVersion '9.9.10'
            $r = Invoke-Update -With @('-Latest', '-ProviderExe', 'C:\a path\GADS-drag.exe')
            $r.Code | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match ('Commit:    ' + $script:K3)
            $r.Text | Should -Match 'This kit:  kit 9\.9\.9, hub v6\.0\.0, provider v6\.0\.0-drag\.1'
            $r.Text | Should -Match 'New kit:   kit 9\.9\.10, hub v6\.0\.0, provider v6\.0\.0-drag\.1'
            $r.Text | Should -Match 'the update script of the new kit ran'
            $r.Text.IndexOf('New kit:') | Should -BeLessThan $r.Text.IndexOf('the update script of the new kit ran')
            (Get-Content -LiteralPath (Join-Path $script:Inst 'update-called.txt')) -join '|' | Should -BeExactly '2|-ProviderExe|C:\a path\GADS-drag.exe'
            (Get-Content -LiteralPath (Join-Path $script:Inst 'versions.json') -Raw | ConvertFrom-Json).kit | Should -BeExactly '9.9.10'
            Get-Sha (Join-Path $script:Inst 'MANIFEST.sha256') | Should -BeExactly $script:NextList
            foreach ($f in @('bootstrap.ps1', 'bootstrap.sh', 'pairing.json')) { Test-Path -LiteralPath (Join-Path $script:Inst $f) | Should -BeFalse }
            Get-Sha (Join-Path ($script:Inst + '.previous') 'scripts/update.ps1') | Should -BeExactly (Get-Sha (Join-Path $script:Kit 'scripts/update.ps1'))
            (@(Get-ChildItem -LiteralPath $script:Opt -Force | ForEach-Object { $_.Name } | Sort-Object) -join ' ') | Should -BeExactly 'blossom-farm-kit blossom-farm-kit.previous'
        }
    }
}
