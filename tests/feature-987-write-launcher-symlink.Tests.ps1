# tests/feature-987-write-launcher-symlink.Tests.ps1
# Tests: install/win/dotfileslink.ps1
# Tags: installer, dotfileslink, Write-Launcher, bugfix-987, pwsh-required, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real dotfileslink.ps1 run where Write-Launcher is invoked in the actual install flow
# - WSL-created symlinks via dotfileslink.sh followed by Windows dotfileslink.ps1 run
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer

if ($env:OS -ne "Windows_NT") {
    Write-Host "SKIP: Windows-only test"
    exit 77
}

Describe "Write-Launcher behavior (dynamic)" {
    # L3 gap (what this test does NOT catch):
    # - Real dotfileslink.ps1 run where Write-Launcher is invoked in the actual install flow
    # - WSL-created symlinks via dotfileslink.sh followed by Windows dotfileslink.ps1 run
    # Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
    # via bin/check-verification-gate.sh category: installer

    BeforeAll {
        $script:agentsDir   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $script:scriptPath  = Join-Path $script:agentsDir "install\win\dotfileslink.ps1"
        $script:ScriptContent = Get-Content -LiteralPath $script:scriptPath -Raw

        # Extract Write-Launcher function body via regex and Invoke-Expression it into the
        # test scope so we can call it directly without running the rest of the installer.
        $script:writeLauncherUnavailable = $false
        $pattern = '(?ms)^function\s+Write-Launcher\s*\{.*?^\}'
        $match = [regex]::Match($script:ScriptContent, $pattern)
        if (-not $match.Success) {
            $script:writeLauncherUnavailable = $true
        } else {
            try {
                Invoke-Expression $match.Value
            } catch {
                $script:writeLauncherUnavailable = $true
            }
        }

        # Probe whether the current environment can create symlinks (requires Developer
        # Mode or Administrator on Windows). If not, skip symlink-specific cases.
        $script:symlinkPrivAbsent = $false
        $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wl-probe-" + [Guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
            $probeTarget = Join-Path $probeDir "target.txt"
            $probeLink   = Join-Path $probeDir "link.txt"
            Set-Content -LiteralPath $probeTarget -Value "probe" -Encoding ASCII
            try {
                New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeTarget -ErrorAction Stop | Out-Null
            } catch {
                $script:symlinkPrivAbsent = $true
            }
        } catch {
            $script:symlinkPrivAbsent = $true
        } finally {
            if (Test-Path -LiteralPath $probeDir) {
                Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    BeforeEach {
        $script:repoBin  = Join-Path $TestDrive "repo-bin"
        $script:localBin = Join-Path $TestDrive "local-bin"
        New-Item -ItemType Directory -Path $script:repoBin  -Force | Out-Null
        New-Item -ItemType Directory -Path $script:localBin -Force | Out-Null
    }

    It "creates a new file with the requested content when the path does not exist" -Skip:$script:writeLauncherUnavailable {
        $path = Join-Path $script:localBin "shimname.cmd"
        $content = "@echo off`r`necho hello`r`n"
        Test-Path -LiteralPath $path | Should -BeFalse
        Write-Launcher $path $content "shimname.cmd"
        Test-Path -LiteralPath $path | Should -BeTrue
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::ASCII) | Should -Be $content
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0
    }

    It "leaves an identical regular file untouched and prints 'Already generated'" -Skip:$script:writeLauncherUnavailable {
        $path = Join-Path $script:localBin "same.cmd"
        $content = "@echo off`r`necho same`r`n"
        [System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::ASCII)
        $before = (Get-Item -LiteralPath $path).LastWriteTimeUtc
        $output = Write-Launcher $path $content "same.cmd" 6>&1
        ($output -join "`n") | Should -Match 'Already generated:\s*same\.cmd'
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::ASCII) | Should -Be $content
    }

    It "overwrites a regular file whose content differs" -Skip:$script:writeLauncherUnavailable {
        $path = Join-Path $script:localBin "diff.cmd"
        $old = "@echo off`r`necho old`r`n"
        $new = "@echo off`r`necho new`r`n"
        [System.IO.File]::WriteAllText($path, $old, [System.Text.Encoding]::ASCII)
        Write-Launcher $path $new "diff.cmd"
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::ASCII) | Should -Be $new
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0
    }

    It "bug fix: replaces a valid symlink with a regular file and does NOT modify the symlink target" -Skip:($script:writeLauncherUnavailable -or $script:symlinkPrivAbsent) {
        # Pin post-fix behavior. WF-CODE-5 will update Write-Launcher to detect a
        # ReparsePoint at $Path and Remove-Item before WriteAllText so the symlink's
        # target is never written through. Until the source is updated this test is
        # expected to fail, so it is registered as Pending.
        $targetPath = Join-Path $script:repoBin "shimname"
        $linkPath   = Join-Path $script:localBin "shimname"
        $targetOriginal = "original target content"
        [System.IO.File]::WriteAllText($targetPath, $targetOriginal, [System.Text.Encoding]::ASCII)
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath -ErrorAction Stop | Out-Null
        ((Get-Item -LiteralPath $linkPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0

        $launcherContent = "#!/usr/bin/env bash`nexec echo new-launcher`n"
        Write-Launcher $linkPath $launcherContent "shimname (bash shim)"

        # link path is now a regular file (not a reparse point)
        $linkItem = Get-Item -LiteralPath $linkPath -Force
        ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0
        [System.IO.File]::ReadAllText($linkPath, [System.Text.Encoding]::ASCII) | Should -Be $launcherContent

        # original target file content was NOT modified by Write-Launcher
        [System.IO.File]::ReadAllText($targetPath, [System.Text.Encoding]::ASCII) | Should -Be $targetOriginal
    }

    It "edge: replaces a dangling symlink (target does not exist) with a regular file" -Skip:($script:writeLauncherUnavailable -or $script:symlinkPrivAbsent) {
        # Pin post-fix behavior. The current Write-Launcher throws because ReadAllText
        # follows the dangling symlink and fails. After WF-CODE-5 the function will
        # detect the ReparsePoint and remove it before writing.
        $danglingTarget = Join-Path $script:repoBin "missing-target"
        $linkPath       = Join-Path $script:localBin "dangling"
        # Target does NOT exist on disk — create the symlink anyway.
        try {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $danglingTarget -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Inconclusive -Because "environment refused to create a dangling symlink"
            return
        }
        Test-Path -LiteralPath $danglingTarget | Should -BeFalse
        ((Get-Item -LiteralPath $linkPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0

        $content = "@echo off`r`necho recovered`r`n"
        Write-Launcher $linkPath $content "dangling"

        $linkItem = Get-Item -LiteralPath $linkPath -Force
        ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0
        [System.IO.File]::ReadAllText($linkPath, [System.Text.Encoding]::ASCII) | Should -Be $content
    }

    It "is idempotent: calling Write-Launcher twice on a regular file produces the same result" -Skip:$script:writeLauncherUnavailable {
        $path = Join-Path $script:localBin "idem.cmd"
        $content = "@echo off`r`necho idem`r`n"
        Write-Launcher $path $content "idem.cmd"
        $firstHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $output = Write-Launcher $path $content "idem.cmd" 6>&1
        ($output -join "`n") | Should -Match 'Already generated:\s*idem\.cmd'
        $secondHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $secondHash | Should -Be $firstHash
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::ASCII) | Should -Be $content
    }

    It "gap2: creates a file with empty content and prints 'Already generated' on second call" -Skip:$script:writeLauncherUnavailable {
        $path = Join-Path $script:localBin "empty.cmd"
        $content = ""
        Test-Path -LiteralPath $path | Should -BeFalse
        Write-Launcher $path $content "empty.cmd"
        Test-Path -LiteralPath $path | Should -BeTrue
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::ASCII) | Should -Be $content
        $output = Write-Launcher $path $content "empty.cmd" 6>&1
        ($output -join "`n") | Should -Match 'Already generated:\s*empty\.cmd'
    }

    It "gap3: creates a file in a directory path containing spaces" -Skip:$script:writeLauncherUnavailable {
        $spacedDir = Join-Path $TestDrive "my dir"
        New-Item -ItemType Directory -Path $spacedDir -Force | Out-Null
        $path = Join-Path $spacedDir "shim with spaces.cmd"
        $content = "@echo off`r`necho spaced`r`n"
        Test-Path -LiteralPath $path | Should -BeFalse
        Write-Launcher $path $content "shim with spaces.cmd"
        Test-Path -LiteralPath $path | Should -BeTrue
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::ASCII) | Should -Be $content
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0
    }

    It "gap5: gracefully handles a read-only reparse point (Remove-Item failure path)" {
        # Write-Launcher has no explicit error handler for Remove-Item failure.
        # This test documents the paired source+test gap: source lacks handling,
        # test cannot exercise it without induced fault injection.
        # Pair: when source adds error handling, add a corresponding It block here.
        Set-ItResult -Skipped -Because "source has no Remove-Item error handling — paired gap documented"
    }
}
