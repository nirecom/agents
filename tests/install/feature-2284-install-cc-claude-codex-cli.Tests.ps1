# Tests: install/lib/wait-cc-exit.ps1, install/win/claude-code.ps1, install/win/codex.ps1
# Tags: installer, wait-cc-exit, scope:issue-specific, pwsh-required, TL2
# TL2: executes the real .ps1 sources in a child pwsh with a per-process environment
# (WAIT_CC_PROCESS_OVERRIDE seam, PATH stubs for claude/codex, mock AGENTS_ROOT).
# Migrated from the pwsh-executing cases of tests/install/feature-2284-install-cc-claude-codex-cli.sh
# (static A9/A10, C4/D4 detectors stay there).
# TL3 gap: real process detection of a live Claude Code and a real `claude update` /
# `codex update` against npm. Closest-to-action: bin/check-verification-gate.sh category: installer.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\pester-process-helpers.ps1')
    $script:AgentsDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:WaitPs    = Join-Path $script:AgentsDir 'install\lib\wait-cc-exit.ps1'
    $script:CcPs      = Join-Path $script:AgentsDir 'install\win\claude-code.ps1'
    $script:CodexPs   = Join-Path $script:AgentsDir 'install\win\codex.ps1'

    # Child env base: never inherit a parent memo (#2476) that would short-circuit the helper.
    function Invoke-WaitPs([string]$Override) {
        Invoke-PwshChild -File $script:WaitPs -TimeoutSec 30 -Environment @{
            WAIT_CC_RESULT            = $null
            WAIT_CC_PROCESS_OVERRIDE  = $Override
            WAIT_CC_POLL_INTERVAL     = '1'
            WAIT_CC_MAX_POLLS         = '3'
        }
    }

    # Group F stub factory: a mock AGENTS_ROOT whose wait helper exits $WaitExit, and a
    # PATH-first stub for $Cli that appends its arguments to a call log and exits $CliExit.
    # The real installer (not a copy) runs, so AGENTS_ROOT is the only redirect seam.
    function Invoke-InstallerWithStubs([string]$Installer, [string]$Cli, [int]$CliExit, [int]$WaitExit, [string]$Label) {
        $root = Join-Path $TestDrive "root-$Label"
        $stub = Join-Path $TestDrive "stub-$Label"
        $log  = Join-Path $TestDrive "call-log-$Label.txt"
        New-Item -ItemType Directory -Path (Join-Path $root 'install\lib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'install\lib\wait-cc-exit.ps1') -Value "exit $WaitExit"
        if ($IsWindows) {
            New-CmdStub -Directory $stub -Name $Cli -Line @('@echo off', "echo %* >> `"$log`"", "exit /b $CliExit") | Out-Null
        } else {
            New-ShStub -Directory $stub -Name $Cli -Line @("echo `"`$@`" >> '$log'", "exit $CliExit") | Out-Null
        }
        $r = Invoke-PwshChild -File $Installer -TimeoutSec 60 -Environment @{
            PATH           = $stub + [IO.Path]::PathSeparator + $env:PATH
            AGENTS_ROOT    = $root
            WAIT_CC_RESULT = $null
        }
        $updated = (Test-Path -LiteralPath $log) -and
            [bool](Get-Content -LiteralPath $log | Where-Object { $_ -match '^update' })
        [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Updated = $updated }
    }
}

Describe 'wait-ps-polls-until-claude-exits' {
    It 'A4: pwsh helper, no CC -> exit 0 immediately' {
        $r = Invoke-WaitPs 'none'
        $r.ExitCode | Should -Be 0
        $r.Seconds  | Should -BeLessThan 4
    }

    It 'A5: pwsh helper, CC alive throughout -> exit 1 with warning' {
        $r = Invoke-WaitPs 'alive'
        $r.ExitCode | Should -Be 1
        $r.Output.Trim() | Should -Not -BeNullOrEmpty
    }

    It 'A6: pwsh helper, CC exits before timeout -> exit 0' {
        $r = Invoke-WaitPs 'alive:2'
        $r.ExitCode | Should -Be 0
    }
}

Describe 'ps-update-failure-keeps-caller-exit-0' {
    # The original used `& /usr/bin/false`, which is absent on Windows (E2 failed there and
    # E2b passed only through CommandNotFound). A child pwsh `exit 1` is a real failing
    # native command on every platform, so both shapes now exercise a genuine non-zero exit.
    BeforeAll {
        $script:FailingNative = "& '$($script:PwshExe -replace "'", "''")' -NoProfile -NonInteractive -Command 'exit 1'"
    }

    It 'E2: PSNativeCommandUseErrorActionPreference=false -LASTEXITCODE soft-fail exits 0' {
        $caller = Join-Path $TestDrive 'caller.ps1'
        Set-Content -LiteralPath $caller -Value @(
            'Set-StrictMode -Version Latest'
            '$ErrorActionPreference = "Stop"'
            '$PSNativeCommandUseErrorActionPreference = $false'
            $script:FailingNative
            'if ($LASTEXITCODE -ne 0) {'
            '    Write-Warning "update failed; continuing"'
            '}'
            'Write-Output "continued"'
            'exit 0'
        )
        $r = Invoke-PwshChild -File $caller -TimeoutSec 30
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'continued'
        $r.Output   | Should -Match 'update failed; continuing'
    }

    It 'E2b: PSNativeCommandUseErrorActionPreference=true -try/catch soft-fail exits 0' {
        $caller = Join-Path $TestDrive 'caller-trycatch.ps1'
        Set-Content -LiteralPath $caller -Value @(
            'Set-StrictMode -Version Latest'
            '$ErrorActionPreference = "Stop"'
            '$PSNativeCommandUseErrorActionPreference = $true'
            'try {'
            "    $script:FailingNative"
            '} catch {'
            '    Write-Warning "update failed; continuing"'
            '}'
            'Write-Output "continued"'
            'exit 0'
        )
        $r = Invoke-PwshChild -File $caller -TimeoutSec 30
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'continued'
        $r.Output   | Should -Match 'update failed; continuing'
    }
}

Describe 'claude-code-ps-exec-update-gated' {
    It 'F3-a: claude-code.ps1 -guard passes -> `claude update` invoked' {
        $r = Invoke-InstallerWithStubs $script:CcPs 'claude' 0 0 'F3a'
        $r.Updated | Should -BeTrue -Because "rc=$($r.ExitCode) out=$($r.Output)"
    }

    It 'F3-b: claude-code.ps1 -guard timeout -> update skipped, exits 0' {
        $r = Invoke-InstallerWithStubs $script:CcPs 'claude' 0 1 'F3b'
        $r.Updated  | Should -BeFalse
        $r.ExitCode | Should -Be 0
    }

    It 'F3-c: claude-code.ps1 -update failure soft-failed (exits 0)' {
        $r = Invoke-InstallerWithStubs $script:CcPs 'claude' 1 0 'F3c'
        $r.Updated  | Should -BeTrue -Because 'the failing update must actually have been attempted'
        $r.ExitCode | Should -Be 0
    }
}

Describe 'codex-ps-exec-update-gated' {
    It 'F4-a: codex.ps1 -guard passes -> `codex update` invoked' {
        $r = Invoke-InstallerWithStubs $script:CodexPs 'codex' 0 0 'F4a'
        $r.Updated | Should -BeTrue -Because "rc=$($r.ExitCode) out=$($r.Output)"
    }

    It 'F4-b: codex.ps1 -guard timeout -> update skipped, exits 0' {
        $r = Invoke-InstallerWithStubs $script:CodexPs 'codex' 0 1 'F4b'
        $r.Updated  | Should -BeFalse
        $r.ExitCode | Should -Be 0
    }

    It 'F4-c: codex.ps1 -update failure soft-failed (exits 0)' {
        $r = Invoke-InstallerWithStubs $script:CodexPs 'codex' 1 0 'F4c'
        $r.Updated  | Should -BeTrue -Because 'the failing update must actually have been attempted'
        $r.ExitCode | Should -Be 0
    }
}
