BeforeDiscovery {
    $ScriptPath = (Resolve-Path `
        -Path (Join-Path $PSScriptRoot '..\install\win\global-gitignore.ps1') `
        -ErrorAction SilentlyContinue).Path
    $ScriptExists = [bool]$ScriptPath -and `
        ($null -ne (Get-Command pwsh -ErrorAction SilentlyContinue))
    $IsPosixLike = [bool]($env:MSYSTEM -or $env:CYGWIN) -and (-not $IsWindows)
}

BeforeAll {
    $script:ScriptPath  = (Resolve-Path `
        -Path (Join-Path $PSScriptRoot '..\install\win\global-gitignore.ps1') `
        -ErrorAction SilentlyContinue).Path
    $script:OrigXdg     = $env:XDG_CONFIG_HOME
    $script:OrigHome    = $env:HOME

    function New-IsolatedXdg ([string]$Name) {
        $xdg = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path (Join-Path $xdg 'git')  | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $xdg 'home') | Out-Null
        return $xdg
    }

    function Invoke-Installer ([string]$Xdg) {
        $prevXdg  = $env:XDG_CONFIG_HOME
        $prevHome = $env:HOME
        try {
            $env:XDG_CONFIG_HOME = $Xdg
            $env:HOME            = Join-Path $Xdg 'home'
            $outFile = Join-Path $Xdg 'stdout.txt'
            $errFile = Join-Path $Xdg 'stderr.txt'
            $proc = Start-Process -FilePath pwsh `
                -ArgumentList '-NoProfile', '-NonInteractive', '-File', $script:ScriptPath `
                -RedirectStandardOutput $outFile `
                -RedirectStandardError  $errFile `
                -PassThru
            if (-not $proc.WaitForExit(60000)) {
                $proc.Kill()
                return [pscustomobject]@{ ExitCode = -1; Output = 'TIMEOUT' }
            }
            $exit = $proc.ExitCode
            $out  = ((Get-Content $outFile -Raw -ErrorAction SilentlyContinue) ?? '') +
                    ((Get-Content $errFile -Raw -ErrorAction SilentlyContinue) ?? '')
            return [pscustomobject]@{ ExitCode = $exit; Output = $out }
        } finally {
            if ($prevXdg)  { $env:XDG_CONFIG_HOME = $prevXdg }
            else           { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
            if ($prevHome) { $env:HOME = $prevHome }
            else           { Remove-Item Env:HOME -ErrorAction SilentlyContinue }
        }
    }

    function Get-IgnoreContent ([string]$Xdg) {
        $p = Join-Path $Xdg 'git\ignore'
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        return (Get-Content -LiteralPath $p -Raw) -replace "`r`n", "`n"
    }

    function Get-MarkerCount ([string]$Content, [string]$Marker) {
        if ($null -eq $Content) { return 0 }
        return @(($Content -split "`n") | Where-Object { $_.TrimEnd("`r") -eq $Marker }).Count
    }

    function Test-BlockPresent ([string]$Xdg) {
        $p = Join-Path $Xdg 'git\ignore'
        if (-not (Test-Path -LiteralPath $p)) { return $false }
        $c = Get-IgnoreContent -Xdg $Xdg
        return ($null -ne $c) `
            -and ((Get-MarkerCount $c '# --- BEGIN agents-managed ---') -eq 1) `
            -and ((Get-MarkerCount $c '# --- END agents-managed ---') -eq 1) `
            -and (($c -split "`n" | Where-Object { $_.TrimEnd("`r") -eq 'WORKTREE_NOTES.md' }).Count -eq 1)
    }
}

Describe "global-gitignore.ps1 (broad integration)" {

    AfterEach {
        if ($script:OrigXdg)  { $env:XDG_CONFIG_HOME = $script:OrigXdg }
        else                  { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
        if ($script:OrigHome) { $env:HOME = $script:OrigHome }
        else                  { Remove-Item Env:HOME -ErrorAction SilentlyContinue }
    }

    Context "Normal cases" {
        It "T01: creates ignore file with managed block when target does not exist" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-missing'
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Be 0
            Test-BlockPresent -Xdg $xdg | Should -BeTrue
        }

        It "T02: appends block while preserving unrelated entries" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-existing'
            [System.IO.File]::WriteAllText((Join-Path $xdg 'git\ignore'), "*.log`n*.tmp`n")
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Be 0
            Test-BlockPresent -Xdg $xdg | Should -BeTrue
            $c = Get-IgnoreContent -Xdg $xdg
            $c | Should -Match '(?m)^\*\.log$'
            $c | Should -Match '(?m)^\*\.tmp$'
        }

        It "T11: preserves other-tool managed blocks alongside agents block" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-other-tool'
            $init = "# --- BEGIN other-tool ---`n*.bak`n# --- END other-tool ---`n"
            [System.IO.File]::WriteAllText((Join-Path $xdg 'git\ignore'), $init)
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Be 0
            Test-BlockPresent -Xdg $xdg | Should -BeTrue
            $c = Get-IgnoreContent -Xdg $xdg
            $c | Should -Match '# --- BEGIN other-tool ---'
            $c | Should -Match '(?m)^\*\.bak$'
        }
    }

    Context "Idempotency cases" {
        It "T03: replaces stale agents-managed block content" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-replace'
            $old = "# --- BEGIN agents-managed ---`nOLD_ENTRY.md`n# --- END agents-managed ---`n"
            [System.IO.File]::WriteAllText((Join-Path $xdg 'git\ignore'), $old)
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Be 0
            Test-BlockPresent -Xdg $xdg | Should -BeTrue
            $c = Get-IgnoreContent -Xdg $xdg
            $c | Should -Not -Match 'OLD_ENTRY\.md'
        }

        It "T04: double-run produces exactly one block" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-double'
            Invoke-Installer -Xdg $xdg | Out-Null
            Invoke-Installer -Xdg $xdg | Out-Null
            $c = Get-IgnoreContent -Xdg $xdg
            Get-MarkerCount $c '# --- BEGIN agents-managed ---' | Should -Be 1
            ($c -split "`n" | Where-Object { $_.TrimEnd("`r") -eq 'WORKTREE_NOTES.md' }).Count | Should -Be 1
        }

        It "T12: triple-run produces exactly one block" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-triple'
            Invoke-Installer -Xdg $xdg | Out-Null
            Invoke-Installer -Xdg $xdg | Out-Null
            Invoke-Installer -Xdg $xdg | Out-Null
            $c = Get-IgnoreContent -Xdg $xdg
            Get-MarkerCount $c '# --- BEGIN agents-managed ---' | Should -Be 1
        }
    }

    Context "Edge cases" {
        It "T05: handles zero-byte ignore file" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-empty'
            [System.IO.File]::WriteAllBytes((Join-Path $xdg 'git\ignore'), @())
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Be 0
            Test-BlockPresent -Xdg $xdg | Should -BeTrue
        }

        It "T06: inserts separator newline when file lacks trailing newline" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-nonl'
            [System.IO.File]::WriteAllText((Join-Path $xdg 'git\ignore'), '*.log')
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Be 0
            Test-BlockPresent -Xdg $xdg | Should -BeTrue
            $c = Get-IgnoreContent -Xdg $xdg
            $c | Should -Not -Match '\*\.log# --- BEGIN'
        }

        It "T13: handles marker-like text in comments without treating as real markers" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-inject'
            $init = "# --- BEGIN agents-managed ---`nWORKTREE_NOTES.md`n# --- END agents-managed ---`n# user note: # --- BEGIN agents-managed --- (fake)`n# user note: # --- END agents-managed --- (fake)`n"
            [System.IO.File]::WriteAllText((Join-Path $xdg 'git\ignore'), $init)
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Be 0
            $c = Get-IgnoreContent -Xdg $xdg
            Get-MarkerCount $c '# --- BEGIN agents-managed ---' | Should -Be 1
            Get-MarkerCount $c '# --- END agents-managed ---'   | Should -Be 1
        }
    }

    Context "Error cases" {
        It "T07: aborts with non-zero exit on stray BEGIN marker (no END)" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-begin-only'
            [System.IO.File]::WriteAllText((Join-Path $xdg 'git\ignore'), "# --- BEGIN agents-managed ---`npartial`n")
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Not -Be 0
        }

        It "T08: aborts with non-zero exit on stray END marker (no BEGIN)" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-end-only'
            [System.IO.File]::WriteAllText((Join-Path $xdg 'git\ignore'), "partial`n# --- END agents-managed ---`n")
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Not -Be 0
        }

        It "T09: aborts with non-zero exit on duplicate BEGIN markers" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-two-begin'
            $init = "# --- BEGIN agents-managed ---`na`n# --- END agents-managed ---`n# --- BEGIN agents-managed ---`nb`n# --- END agents-managed ---`n"
            [System.IO.File]::WriteAllText((Join-Path $xdg 'git\ignore'), $init)
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Not -Be 0
        }

        It "T10: aborts with non-zero exit when target path is a directory" -Skip:(-not $ScriptExists) {
            $xdg = New-IsolatedXdg 'case-dir-target'
            New-Item -ItemType Directory -Force -Path (Join-Path $xdg 'git\ignore') | Out-Null
            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Not -Be 0
        }

        It "T15: aborts with non-zero exit when parent directory is unwritable" -Skip:((-not $ScriptExists) -or $IsPosixLike) {
            $xdg = New-IsolatedXdg 'case-unwritable-parent'
            Remove-Item -Recurse -Force (Join-Path $xdg 'git') -ErrorAction SilentlyContinue
            $gitDir = Join-Path $xdg 'git'
            New-Item -ItemType Directory -Force -Path $gitDir | Out-Null
            $denied = $false
            try {
                $icaclsResult = & icacls $gitDir /deny "$env:USERNAME:(W)" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $testFile = Join-Path $gitDir 'test-deny.tmp'
                    try { [System.IO.File]::WriteAllText($testFile, 'x'); Remove-Item $testFile -Force -ErrorAction SilentlyContinue }
                    catch { $denied = $true }
                }
            } catch { }

            if (-not $denied) {
                Set-ItResult -Skipped -Because "icacls deny did not take effect on TestDrive"
                return
            }

            $r = Invoke-Installer -Xdg $xdg
            $r.ExitCode | Should -Not -Be 0
        }
    }

    Context "Security cases" {
        It "T14: aborts with non-zero exit when target file is read-only" -Skip:((-not $ScriptExists) -or $IsPosixLike) {
            $xdg = New-IsolatedXdg 'case-readonly'
            $p = Join-Path $xdg 'git\ignore'
            [System.IO.File]::WriteAllText($p, "*.log`n")
            (Get-Item $p).IsReadOnly = $true
            try {
                $r = Invoke-Installer -Xdg $xdg
                $r.ExitCode | Should -Not -Be 0
            } finally {
                try { (Get-Item $p -ErrorAction SilentlyContinue).IsReadOnly = $false } catch { }
            }
        }
    }
}
