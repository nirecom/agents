# Tests: tests/lib/harness.ps1
# Tags: test-infra, pester, harness, TL2, scope:issue-specific, pwsh-required
# harness.ps1 contract (#2411): isolation enter/exit, fixture git repo, known failure,
# the RUN_TL3 gate, and loading through the real Pester wrapper from a copied tree.
# TL3 gap (what this test does NOT catch):
# - a tests/run-all.sh run, where the command guard git and the run-root pin are active
# - a host whose Pester is older than the registry minVersion
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: pwsh-required.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')

    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:helperPath = Join-Path $script:repoRoot 'tests' 'lib' 'harness.ps1'
    $script:pwshExe = (Get-Process -Id $PID).Path
    $script:registry = Get-Content -LiteralPath (Join-Path $script:repoRoot 'hooks' 'lib' 'test-language-registry.json') -Raw | ConvertFrom-Json
    $script:wrapperRel = 'bin/lib/test-wrappers/pester.ps1'
    $script:isoNames = @('WORKFLOW_STATE_DIR', 'WORKFLOW_PLANS_DIR', 'CLAUDE_CODE_SESSION_ID')
    $script:sentinel = @{}
    foreach ($n in $script:isoNames) { $script:sentinel[$n] = 'h2411-secret-' + [guid]::NewGuid().ToString('N') }

    # A temp tree shaped like the repo's tests/: tests/<category>/ and tests/lib/ with the real helper.
    function New-HarnessTree {
        param([Parameter(Mandatory)][string]$Category)
        $root = Join-Path $TestDrive ('tree-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'tests' $Category), (Join-Path $root 'tests' 'lib') -Force | Out-Null
        Copy-Item -LiteralPath $script:helperPath -Destination (Join-Path $root 'tests' 'lib' 'harness.ps1')
        $root
    }

    # Runs one test file through the real wrapper with the registry entry's launch.command.
    function Invoke-HarnessWrapper {
        param(
            [Parameter(Mandatory)][string]$TestFile,
            [Parameter(Mandatory)][string]$WorkingDirectory,
            [hashtable]$Environment = @{}
        )
        $entry = @($script:registry.entries | Where-Object {
                $_.PSObject.Properties['launch'] -and $_.launch -and $_.launch.PSObject.Properties['wrapper'] -and $_.launch.wrapper -eq $script:wrapperRel
            })[0]
        $resultDir = Join-Path $TestDrive ('result-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:pwshExe
        foreach ($a in @($entry.launch.command | Select-Object -Skip 1)) {
            $psi.ArgumentList.Add($a.Replace('{wrapper}', (Join-Path $script:repoRoot $script:wrapperRel)).Replace('{nativePath}', $TestFile).Replace('{minVersion}', $entry.launch.minVersion.version))
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.Environment['RUN_ALL_RESULT_DIR'] = $resultDir
        foreach ($k in $Environment.Keys) { $psi.Environment[$k] = [string]$Environment[$k] }
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $timedOut = -not $p.WaitForExit(100000)
        if ($timedOut) { $p.Kill($true) }
        $p.WaitForExit()
        $casesFile = Join-Path $resultDir 'cases.tsv'
        [pscustomobject]@{
            ExitCode = if ($timedOut) { 124 } else { $p.ExitCode }
            Output   = $outTask.Result + $errTask.Result
            Cases    = if (Test-Path -LiteralPath $casesFile) { (Get-Content -LiteralPath $casesFile -Raw) } else { '' }
        }
    }

    # Writes <Root>/bin/get-config-var: answers Value with ExitCode, and only to `RUN_TL3 off`.
    function New-Tl3Reader {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Value, [int]$ExitCode = 0)
        New-Item -ItemType Directory -Path (Join-Path $Root 'bin') -Force | Out-Null
        $body = "#!/usr/bin/env bash`n[ `"`$1`" = RUN_TL3 ] && [ `"`$2`" = off ] || exit 9`nprintf '%s\n' '$Value'`nexit $ExitCode`n"
        [System.IO.File]::WriteAllText((Join-Path $Root 'bin' 'get-config-var'), $body)
    }

    # Plants a failing pre-commit hook, then commits one file. Reports what the repo did.
    function Invoke-FixtureCommit {
        param([Parameter(Mandatory)][string]$Repo)
        $hook = Join-Path $Repo '.git' 'hooks' 'pre-commit'
        New-Item -ItemType Directory -Path (Split-Path -Parent $hook) -Force | Out-Null
        [System.IO.File]::WriteAllText($hook, "#!/bin/sh`necho ran > hook-ran.marker`nexit 1`n")
        if (-not $IsWindows) { & chmod +x $hook }
        Set-Content -LiteralPath (Join-Path $Repo 'tracked.txt') -Value 'x'
        Set-Content -LiteralPath (Join-Path $Repo 'ignored.txt') -Value 'x'
        $status = (& git -C $Repo status --porcelain --untracked-files=all) -join "`n"
        & git -C $Repo add tracked.txt 2>&1 | Out-Null
        & git -C $Repo -c user.name=t -c user.email=t@example.com commit -q -m init 2>&1 | Out-Null
        [pscustomobject]@{
            CommitExit = $LASTEXITCODE
            HookRan    = Test-Path -LiteralPath (Join-Path $Repo 'hook-ran.marker')
            Status     = $status
        }
    }
}

Describe 'harness-isolation' {
    BeforeEach {
        $script:saved = @{}
        foreach ($n in $script:isoNames) { $script:saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    }

    AfterEach {
        foreach ($n in $script:isoNames) { [Environment]::SetEnvironmentVariable($n, $script:saved[$n]) }
    }

    It 'ISO-enter-exit (<Label>): pins both dirs into temp, removes the session variables, restores exactly' -ForEach @(
        @{ Label = 'all set'; Preset = @{ WORKFLOW_STATE_DIR = 'h2411-state'; WORKFLOW_PLANS_DIR = 'h2411-plans'; CLAUDE_CODE_SESSION_ID = 'h2411-ccsid' } }
        @{ Label = 'all unset'; Preset = @{} }
        @{ Label = 'mixed'; Preset = @{ WORKFLOW_PLANS_DIR = 'h2411-plans'; CLAUDE_CODE_SESSION_ID = 'h2411-ccsid' } }
    ) {
        foreach ($n in $script:isoNames) { [Environment]::SetEnvironmentVariable($n, $Preset[$n]) }
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        Enter-HarnessIsolation | Out-Null
        try {
            foreach ($n in @('WORKFLOW_STATE_DIR', 'WORKFLOW_PLANS_DIR')) {
                $dir = [Environment]::GetEnvironmentVariable($n)
                $dir | Should -Not -BeNullOrEmpty
                $dir | Should -Not -Be $Preset[$n]
                Test-Path -LiteralPath $dir -PathType Container | Should -BeTrue
                [System.IO.Path]::GetFullPath($dir).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
            }
            [Environment]::GetEnvironmentVariable('CLAUDE_CODE_SESSION_ID') | Should -BeNullOrEmpty -Because 'CLAUDE_CODE_SESSION_ID is removed'
        } finally {
            Exit-HarnessIsolation | Out-Null
        }
        foreach ($n in $script:isoNames) {
            $actual = [Environment]::GetEnvironmentVariable($n)
            if ($null -eq $Preset[$n]) { $actual | Should -BeNullOrEmpty } else { $actual | Should -BeExactly $Preset[$n] }
        }
    }

    It 'ISO-fresh: every enter gets a directory of its own' {
        Enter-HarnessIsolation | Out-Null
        $first = $env:WORKFLOW_STATE_DIR
        Exit-HarnessIsolation | Out-Null
        Enter-HarnessIsolation | Out-Null
        try { $env:WORKFLOW_STATE_DIR | Should -Not -Be $first } finally { Exit-HarnessIsolation | Out-Null }
    }

    It 'ISO-exception: an exit in finally restores after the body threw' {
        $env:WORKFLOW_STATE_DIR = 'h2411-state'
        $env:CLAUDE_CODE_SESSION_ID = 'h2411-ccsid'
        Remove-Item -Path Env:WORKFLOW_PLANS_DIR -ErrorAction SilentlyContinue
        $thrown = $false
        try {
            Enter-HarnessIsolation | Out-Null
            try { throw 'body failed' } finally { Exit-HarnessIsolation | Out-Null }
        } catch {
            $thrown = $true
        }
        $thrown | Should -BeTrue
        $env:WORKFLOW_STATE_DIR | Should -BeExactly 'h2411-state'
        $env:CLAUDE_CODE_SESSION_ID | Should -BeExactly 'h2411-ccsid'
        $env:WORKFLOW_PLANS_DIR | Should -BeNullOrEmpty
    }

    It 'ISO-exit-twice: a second exit neither throws nor disturbs the restored values' {
        $env:WORKFLOW_STATE_DIR = 'h2411-state'
        Remove-Item -Path Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue
        Enter-HarnessIsolation | Out-Null
        Exit-HarnessIsolation | Out-Null
        { Exit-HarnessIsolation | Out-Null } | Should -Not -Throw
        $env:WORKFLOW_STATE_DIR | Should -BeExactly 'h2411-state'
        $env:CLAUDE_CODE_SESSION_ID | Should -BeNullOrEmpty
    }
}

Describe 'harness-git-repo' {
    BeforeAll {
        # A global config whose excludes file would hide ignored.txt, and no system config.
        $script:gitSaved = @{ GIT_CONFIG_GLOBAL = $env:GIT_CONFIG_GLOBAL; GIT_CONFIG_NOSYSTEM = $env:GIT_CONFIG_NOSYSTEM }
        $gitHome = Join-Path $TestDrive 'githome'
        New-Item -ItemType Directory -Path $gitHome -Force | Out-Null
        $ignoreFile = Join-Path $gitHome 'global-ignore'
        Set-Content -LiteralPath $ignoreFile -Value 'ignored.txt'
        $globalConfig = Join-Path $gitHome 'gitconfig'
        [System.IO.File]::WriteAllText($globalConfig, "[core]`n`texcludesFile = $($ignoreFile -replace '\\', '/')`n")
        $env:GIT_CONFIG_GLOBAL = $globalConfig
        $env:GIT_CONFIG_NOSYSTEM = '1'
    }

    AfterAll {
        foreach ($k in $script:gitSaved.Keys) { [Environment]::SetEnvironmentVariable($k, $script:gitSaved[$k]) }
    }

    It 'GIT-control: in a plain git init repo the planted hook fires and the global excludes file applies' {
        $repo = Join-Path $TestDrive 'control'
        & git init -q $repo
        $r = Invoke-FixtureCommit -Repo $repo
        $r.HookRan | Should -BeTrue
        $r.CommitExit | Should -Not -Be 0
        $r.Status | Should -Not -Match 'ignored\.txt'
    }

    It 'GIT-fixture (<Dir>): no hook runs, the global excludes file does not apply, re-init is harmless' -ForEach @(
        @{ Dir = 'plain' }
        @{ Dir = 'with space dir' }
    ) {
        $repo = Join-Path $TestDrive $Dir
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        New-HarnessGitRepo -Path $repo | Out-Null
        Join-Path $repo '.git' | Should -Exist
        $r = Invoke-FixtureCommit -Repo $repo
        $r.CommitExit | Should -Be 0
        $r.HookRan | Should -BeFalse
        $r.Status | Should -Match '\?\? ignored\.txt'
        $excludes = (& git -C $repo config --local --get core.excludesFile)
        $excludes | Should -Not -BeNullOrEmpty
        $repoFull = [System.IO.Path]::GetFullPath($repo)
        [System.IO.Path]::GetFullPath($excludes, $repoFull).StartsWith($repoFull, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue

        { New-HarnessGitRepo -Path $repo | Out-Null } | Should -Not -Throw
        (& git -C $repo rev-list --count HEAD) | Should -Be '1'
        Set-Content -LiteralPath (Join-Path $repo 'second.txt') -Value 'y'
        & git -C $repo add second.txt 2>&1 | Out-Null
        & git -C $repo -c user.name=t -c user.email=t@example.com commit -q -m second 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'harness-known-failure' {
    It 'KF-in-process: a throwing block and a failing assertion both pass' {
        { Invoke-HarnessKnownFailure -Because 'gap is open' -ScriptBlock { throw 'boom' } } | Should -Not -Throw
        { Invoke-HarnessKnownFailure -Because 'gap is open' -ScriptBlock { 1 | Should -Be 2 } } | Should -Not -Throw
    }

    It 'KF-child: a block that stops throwing FAILS the test in a real wrapper run' {
        $root = New-HarnessTree -Category 'tests'
        $file = Join-Path $root 'tests' 'tests' 'known-failure.Tests.ps1'
        Set-Content -LiteralPath $file -Value @(
            'BeforeAll {'
            "    . (Join-Path `$PSScriptRoot '..' 'lib' 'harness.ps1')"
            '}'
            "Describe 'kf' {"
            "    It 'still-throws' { Invoke-HarnessKnownFailure -Because 'open' -ScriptBlock { throw 'boom' } }"
            "    It 'stopped-throwing' { Invoke-HarnessKnownFailure -Because 'closed' -ScriptBlock { } }"
            '}'
        )
        $r = Invoke-HarnessWrapper -TestFile $file -WorkingDirectory $root
        $r.ExitCode | Should -Be 1
        $r.Cases | Should -Match '\tPASS\t[^\t\n]*still-throws\t'
        $r.Cases | Should -Match '\tFAIL\t[^\t\n]*stopped-throwing\t'
    }
}

Describe 'harness-load-and-tl3-gate' {
    It 'LOAD (<Category>, cwd <Cwd>, RUN_TL3 <Tl3>): loads by the canonical line; the gated case is <Gated>' -ForEach @(
        @{ Category = 'bin'; Cwd = 'inside'; Tl3 = 'off'; Gated = 'SKIP' }
        @{ Category = 'tests'; Cwd = 'inside'; Tl3 = 'on'; Gated = 'PASS' }
        @{ Category = 'bin'; Cwd = 'outside'; Tl3 = 'on'; Gated = 'PASS' }
        @{ Category = 'tests'; Cwd = 'outside'; Tl3 = 'off'; Gated = 'SKIP' }
    ) {
        $root = New-HarnessTree -Category $Category
        $dir = Join-Path $root 'tests' $Category
        $file = Join-Path $dir 'load.Tests.ps1'
        Set-Content -LiteralPath $file -Value @(
            'BeforeAll {'
            "    . (Join-Path `$PSScriptRoot '..' 'lib' 'harness.ps1')"
            '}'
            "Describe 'load' {"
            "    It 'calls-helper' {"
            '        Enter-HarnessIsolation | Out-Null'
            '        try {'
            '            $env:WORKFLOW_STATE_DIR | Should -Not -BeNullOrEmpty'
            '            $env:CLAUDE_CODE_SESSION_ID | Should -BeNullOrEmpty'
            '        } finally { Exit-HarnessIsolation | Out-Null }'
            "        Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'helper.marker') -Value 'ok'"
            '    }'
            "    It 'tl3-gated' {"
            '        Skip-HarnessUnlessTL3'
            "        Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'tl3.marker') -Value 'ok'"
            '    }'
            '}'
        )
        $cwd = $root
        if ($Cwd -eq 'outside') {
            $cwd = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $cwd -Force | Out-Null
        }
        $r = Invoke-HarnessWrapper -TestFile $file -WorkingDirectory $cwd -Environment ($script:sentinel + @{ RUN_TL3 = $Tl3 })
        $r.ExitCode | Should -Be 0
        $r.Cases | Should -Match '\tPASS\t[^\t\n]*calls-helper\t'
        $r.Cases | Should -Match "\t$Gated\t[^\t\n]*tl3-gated\t"
        Join-Path $dir 'helper.marker' | Should -Exist
        Test-Path -LiteralPath (Join-Path $dir 'tl3.marker') | Should -Be ($Tl3 -eq 'on')
        # Security: the removed and restored values never reach the output.
        foreach ($n in $script:isoNames) { $r.Output.Contains($script:sentinel[$n]) | Should -BeFalse }
    }

    It 'TL3-resolve (<Label>): the gated case is <Gated>' -ForEach @(
        @{ Label = 'reader answers on'; Reader = 'on'; ReaderExit = 0; Tl3 = $null; Gated = 'PASS' }
        @{ Label = 'reader answers off'; Reader = 'off'; ReaderExit = 0; Tl3 = $null; Gated = 'SKIP' }
        @{ Label = 'no reader'; Reader = $null; ReaderExit = 0; Tl3 = $null; Gated = 'SKIP' }
        @{ Label = 'reader fails after answering on'; Reader = 'on'; ReaderExit = 3; Tl3 = $null; Gated = 'SKIP' }
        @{ Label = 'reader answers padded mixed case'; Reader = ' On '; ReaderExit = 0; Tl3 = $null; Gated = 'PASS' }
        @{ Label = 'process off over reader on'; Reader = 'on'; ReaderExit = 0; Tl3 = 'off'; Gated = 'SKIP' }
        @{ Label = 'process on over reader off'; Reader = 'off'; ReaderExit = 0; Tl3 = 'on'; Gated = 'PASS' }
    ) {
        # The reader is found from the helper file, not the working directory, and the
        # developer's own RUN_TL3 never reaches the child.
        $root = New-HarnessTree -Category 'tests'
        if ($null -ne $Reader) { New-Tl3Reader -Root $root -Value $Reader -ExitCode $ReaderExit }
        $dir = Join-Path $root 'tests' 'tests'
        $file = Join-Path $dir 'tl3.Tests.ps1'
        Set-Content -LiteralPath $file -Value @(
            'BeforeAll {'
            "    . (Join-Path `$PSScriptRoot '..' 'lib' 'harness.ps1')"
            '}'
            "Describe 'tl3' {"
            "    It 'tl3-gated' {"
            '        Skip-HarnessUnlessTL3'
            "        Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'tl3.marker') -Value 'ok'"
            '    }'
            '}'
        )
        $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $extra = @{}
        if ($null -ne $Tl3) { $extra['RUN_TL3'] = $Tl3 }
        $saved = $env:RUN_TL3
        Remove-Item -Path Env:RUN_TL3 -ErrorAction SilentlyContinue
        try {
            $r = Invoke-HarnessWrapper -TestFile $file -WorkingDirectory $outside -Environment $extra
        } finally {
            [Environment]::SetEnvironmentVariable('RUN_TL3', $saved)
        }
        # The gated case is the child's only case, so a skip makes the wrapper answer 77.
        $r.ExitCode | Should -Be $(if ($Gated -eq 'PASS') { 0 } else { 77 })
        $r.Cases | Should -Match "\t$Gated\t[^\t\n]*tl3-gated\t"
        Test-Path -LiteralPath (Join-Path $dir 'tl3.marker') | Should -Be ($Gated -eq 'PASS')
    }

    It 'NOT-A-TEST: tests/lib/harness.ps1 exists and matches no supported test pattern' {
        $script:helperPath | Should -Exist
        $supported = @($script:registry.entries | Where-Object { $_.status -eq 'supported' })
        $supported.Count | Should -BeGreaterThan 0
        $matching = { param($name) @($supported | Where-Object { @($_.patterns | Where-Object { $name -like $_ }).Count -gt 0 }) }
        (& $matching 'harness.ps1').Count | Should -Be 0
        (& $matching 'feature-2411-harness.Tests.ps1').Count | Should -BeGreaterThan 0
    }
}
