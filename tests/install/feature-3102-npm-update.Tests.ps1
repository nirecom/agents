# Tests: install/win/npm.ps1, install/lib/npm-engine-check.js
# Tags: installer, npm-update, scope:issue-specific, pwsh-required, TL2, test-lang-exception:e2e
# #3102: real npm.ps1 in a child pwsh -> real node + npm-engine-check.js; PATH-first stub npm supplies the range.
# Two cases only (minimum-test constraint): range met -> npm install runs; range unmet -> skipped with a manual command. exit 0.
# TL3 gap: real npm/fnm, package-manager / non-writable prefix skips, a failing `npm install`, and the absence of the update notice.
# Closest-to-action: bin/check-verification-gate.sh category: installer.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
    . (Join-Path $PSScriptRoot '..\lib\pester-process-helpers.ps1')
    $script:AgentsDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:NpmPs     = Join-Path $script:AgentsDir 'install\win\npm.ps1'

    # Run npm.ps1 with a stub npm that answers `root -g` / `prefix -g` with writable temp dirs
    # (<root>\npm exists, so the writability check passes) and `view` with $Range.
    function Invoke-NpmStep([string]$Label, [string]$Range) {
        $base   = Join-Path $TestDrive $Label
        $set    = New-InstallerStubSet -Base $base -Cli 'codex' -NoNpm
        $rootD  = Join-Path $base 'npm-root'
        $prefD  = Join-Path $base 'npm-prefix'
        New-Item -ItemType Directory -Path (Join-Path $rootD 'npm') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $prefD 'bin') -Force | Out-Null
        if ($IsWindows) {
            # '>' in the range must be escaped (^>) or cmd turns it into a redirect.
            $rangeEsc = $Range -replace '>', '^>'
            New-CmdStub -Directory $set.Stub -Name 'npm' -Line @(
                '@echo off'
                "echo npm %* >> `"$($set.Log)`""
                'if "%1"=="root" goto root'
                'if "%1"=="prefix" goto prefix'
                'if "%1"=="view" goto view'
                'exit /b 0'
                ':root'
                "echo $rootD"
                'exit /b 0'
                ':prefix'
                "echo $prefD"
                'exit /b 0'
                ':view'
                "echo $rangeEsc"
                'exit /b 0'
            ) | Out-Null
        } else {
            New-ShStub -Directory $set.Stub -Name 'npm' -Line @(
                "echo `"npm `$@`" >> '$($set.Log)'"
                'case "$1" in'
                "  root) echo '$rootD' ;;"
                "  prefix) echo '$prefD' ;;"
                "  view) echo '$Range' ;;"
                'esac'
                'exit 0'
            ) | Out-Null
        }
        Invoke-StubbedInstaller -Installer $script:NpmPs -Set $set
    }
}

Describe 'compatible-node-runs-npm-install' -Tag 'target:install/win/npm.ps1' {
    It 'range satisfied -> npm install -g npm@latest is called, exit 0' {
        $r = Invoke-NpmStep 'ok' '>=1.0.0'
        $r.ExitCode | Should -Be 0 -Because $r.Output
        @($r.Calls | Where-Object { $_ -match '^npm install -g npm@latest' }).Count | Should -BeGreaterThan 0 -Because ($r.Calls -join "`n")
    }
}

Describe 'incompatible-node-skips-with-manual-command' -Tag 'target:install/lib/npm-engine-check.js' {
    It 'range not satisfied -> no npm install, warning carries the manual command, exit 0' {
        $r = Invoke-NpmStep 'skip' '>=999.0.0'
        $r.ExitCode | Should -Be 0 -Because $r.Output
        @($r.Calls | Where-Object { $_ -match '^npm install' }).Count | Should -Be 0 -Because ($r.Calls -join "`n")
        $r.Output | Should -Match 'npm install -g npm@latest'
    }
}
