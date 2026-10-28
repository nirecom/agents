# Tests: install/lib/wait-cc-exit.ps1, install/win/claude-code.ps1, install/win/codex.ps1
# Tags: installer, wait-cc-exit, scope:issue-specific, pwsh-required, TL2
# TL2: real .ps1 sources in a child pwsh; seams WAIT_CC_/WAIT_CODEX_PROCESS_OVERRIDE and
# WAIT_CC_EXIT_SCRIPT_OVERRIDE; PATH stubs (claude/codex/npm/fnm) from tests/lib/pester-process-helpers.ps1.
# Migrated from the pwsh-executing cases of feature-2284-install-cc-claude-codex-cli.sh (static A9-A11, C4/D4 stay there).
# #2808: codex.ps1 updates via npm after a serial claude -> codex wait, only for the codex under the npm prefix.
# TL3 gap: a real running codex process, real npm/fnm behavior, and the real Windows file lock behind the EPERM.
# Closest-to-action: bin/check-verification-gate.sh category: installer.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\pester-process-helpers.ps1')
    $script:AgentsDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:WaitPs    = Join-Path $script:AgentsDir 'install\lib\wait-cc-exit.ps1'
    $script:CcPs      = Join-Path $script:AgentsDir 'install\win\claude-code.ps1'
    $script:CodexPs   = Join-Path $script:AgentsDir 'install\win\codex.ps1'

    # Group F4 (codex): $Opt is splatted into New-InstallerStubSet.
    function New-CodexSet([string]$Label, [hashtable]$Opt = @{}) {
        New-InstallerStubSet -Base (Join-Path $TestDrive $Label) -Cli 'codex' @Opt
    }
    function Invoke-Codex($Set, [hashtable]$Env = @{}, [switch]$Restrict, [string]$Installer = $script:CodexPs) {
        Invoke-StubbedInstaller -Installer $Installer -Set $Set -Environment $Env -RestrictPath:$Restrict
    }

    # Child env base: never inherit a parent memo (#2476) that would short-circuit the helper.
    # $Override feeds the claude seam; codex-side seams and other variables go through $Extra.
    function Invoke-WaitPs([string]$Override, [string]$ProcessName = '', [hashtable]$Extra = @{}) {
        $envMap = @{
            WAIT_CC_RESULT              = $null
            WAIT_CC_PROCESS_OVERRIDE    = $Override
            WAIT_CODEX_PROCESS_OVERRIDE = $null
            WAIT_CC_POLL_INTERVAL       = '1'
            WAIT_CC_MAX_POLLS           = '3'
        }
        foreach ($k in $Extra.Keys) { $envMap[$k] = $Extra[$k] }
        $argList = @()
        if ($ProcessName) { $argList = @('-ProcessName', $ProcessName) }
        Invoke-PwshChild -File $script:WaitPs -ArgumentList $argList -TimeoutSec 30 -Environment $envMap
    }

    # Group F (claude): a stub wait helper that exits $WaitExit, handed over by the
    # WAIT_CC_EXIT_SCRIPT_OVERRIDE seam (the root itself comes from $PSScriptRoot), and a
    # PATH-first stub for $Cli that logs its arguments and exits $CliExit.
    function Invoke-InstallerWithStubs([string]$Installer, [string]$Cli, [int]$CliExit, [int]$WaitExit, [string]$Label) {
        $set = New-InstallerStubSet -Base (Join-Path $TestDrive $Label) -Cli $Cli -CliExit $CliExit -ClaudeWaitExit $WaitExit
        Invoke-StubbedInstaller -Installer $Installer -Set $set
    }
}

Describe 'wait-ps-polls-until-claude-exits' -Tag 'target:install/lib/wait-cc-exit.ps1' {
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

    # #2808: -ProcessName codex (own seam WAIT_CODEX_PROCESS_OVERRIDE, no memo, no Desktop filter).
    It 'A4c: -ProcessName codex, no codex -> exit 0 immediately' {
        $r = Invoke-WaitPs $null 'codex' @{ WAIT_CODEX_PROCESS_OVERRIDE = 'none' }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Seconds  | Should -BeLessThan 4
    }

    It 'A5c: -ProcessName codex, codex alive throughout -> exit 1, warning names Codex' {
        $r = Invoke-WaitPs $null 'codex' @{ WAIT_CODEX_PROCESS_OVERRIDE = 'alive' }
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'Codex'
    }

    It 'A6c: -ProcessName codex, codex exits before timeout -> exit 0' {
        $r = Invoke-WaitPs $null 'codex' @{ WAIT_CODEX_PROCESS_OVERRIDE = 'alive:2' }
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'A7a: seams are independent - codex stage ignores WAIT_CC_PROCESS_OVERRIDE=alive' {
        $r = Invoke-WaitPs 'alive' 'codex' @{ WAIT_CODEX_PROCESS_OVERRIDE = 'none' }
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'A7b: seams are independent - claude stage (no argument) ignores WAIT_CODEX_PROCESS_OVERRIDE=alive' {
        $r = Invoke-WaitPs 'none' '' @{ WAIT_CODEX_PROCESS_OVERRIDE = 'alive' }
        $r.ExitCode | Should -Be 0
    }

    It 'A8a: codex stage ignores the memo - WAIT_CC_RESULT=timeout + codex none -> exit 0' {
        $r = Invoke-WaitPs $null 'codex' @{ WAIT_CC_RESULT = 'timeout'; WAIT_CODEX_PROCESS_OVERRIDE = 'none' }
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'A8b: codex stage ignores the memo - WAIT_CC_RESULT=clear + codex alive -> exit 1' {
        $r = Invoke-WaitPs $null 'codex' @{ WAIT_CC_RESULT = 'clear'; WAIT_CODEX_PROCESS_OVERRIDE = 'alive' }
        $r.ExitCode | Should -Be 1
    }

    It 'A8c: codex stage never reads the memo - bogus value prints no "Ignoring invalid"' {
        $r = Invoke-WaitPs $null 'codex' @{ WAIT_CC_RESULT = 'bogus'; WAIT_CODEX_PROCESS_OVERRIDE = 'none' }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output   | Should -Not -Match 'Ignoring invalid'
    }

    It 'A9b: invalid -ProcessName is rejected by ValidateSet (non-zero, error names ProcessName)' {
        $r = Invoke-WaitPs 'none' 'foo'
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -Match 'ProcessName'
    }
}

Describe 'ps-update-failure-keeps-caller-exit-0' -Tag 'target:install/win/codex.ps1' {
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

Describe 'claude-code-ps-exec-update-gated' -Tag 'target:install/win/claude-code.ps1' {
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

Describe 'codex-ps-exec-update-gated' -Tag 'target:install/win/codex.ps1' {
    Context 'serial two-stage wait and npm update' {
        It 'F4-a: both stages clear -> npm install -g @openai/codex runs, `codex update` never does, wait order claude -> codex' {
            $s = New-CodexSet 'F4a'
            $r = Invoke-Codex $s
            $r.ExitCode     | Should -Be 0 -Because $r.Output
            $r.NpmInstalled | Should -BeTrue -Because "calls=$($r.Calls -join '|') out=$($r.Output)"
            $r.CodexUpdated | Should -BeFalse
            ($r.Waits -join ',') | Should -Be 'claude,codex'
        }

        It 'F4-b: claude stage timeout -> npm not run, exit 0, warning names Claude Code, codex stage never started' {
            $s = New-CodexSet 'F4b' @{ ClaudeWaitExit = 1 }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeFalse
            $r.CodexUpdated | Should -BeFalse
            $r.ExitCode     | Should -Be 0
            $r.Output       | Should -Match 'Claude Code'
            ($r.Waits -join ',') | Should -Be 'claude'
        }

        It 'F4-b2: claude clear, codex stage timeout -> npm not run, exit 0, warning names Codex' {
            $s = New-CodexSet 'F4b2' @{ CodexWaitExit = 1 }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeFalse
            $r.CodexUpdated | Should -BeFalse
            $r.ExitCode     | Should -Be 0
            $r.Output       | Should -Match 'Codex'
            ($r.Waits -join ',') | Should -Be 'claude,codex'
        }

        It 'F4-c: npm install fails -> attempted, warning with retry guidance, exit 0' {
            $s = New-CodexSet 'F4c' @{ NpmExit = 1 }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeTrue -Because 'the failing update must actually have been attempted'
            $r.ExitCode     | Should -Be 0
            $r.Output       | Should -Match 'retry manually'
        }
    }

    Context 'the codex that runs is the one npm updates' {
        It 'F4-i1: codex outside the npm global prefix -> no npm install, "not under the npm global prefix", exit 0' {
            $s = New-CodexSet 'F4i1' @{ PrefixOut = (Join-Path $TestDrive 'F4i1-other-prefix') }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeFalse
            $r.ExitCode     | Should -Be 0
            $r.Output       | Should -Match 'not under the npm global prefix'
        }

        It 'F4-i2: prefix differing only by case and trailing separator counts as the same install' -Skip:(-not $IsWindows) {
            $base = Join-Path $TestDrive 'F4i2'
            $s = New-CodexSet 'F4i2' @{ PrefixOut = ((Join-Path $base 'bin').ToUpperInvariant() + '\') }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeTrue -Because "calls=$($r.Calls -join '|') out=$($r.Output)"
            $r.ExitCode     | Should -Be 0
        }

        It 'F4-i3a: npm prefix -g fails -> update skipped with a warning, exit 0' {
            $s = New-CodexSet 'F4i3a' @{ PrefixExit = 1 }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeFalse
            $r.ExitCode     | Should -Be 0
            $r.Output       | Should -Match 'WARNING'
        }

        It 'F4-i3b: npm prefix -g prints nothing -> update skipped with a warning, exit 0' {
            $s = New-CodexSet 'F4i3b' @{ PrefixEmpty = $true }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeFalse
            $r.ExitCode     | Should -Be 0
            $r.Output       | Should -Match 'WARNING'
        }
    }

    Context 'native command failure contract under $ErrorActionPreference = Stop' {
        It 'F4-n1: fnm env fails -> warning, PATH npm still updates, exit 0' {
            $s = New-CodexSet 'F4n1' @{ FnmExit = 1 }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeTrue -Because "calls=$($r.Calls -join '|') out=$($r.Output)"
            $r.ExitCode     | Should -Be 0
            $r.Output       | Should -Match 'WARNING'
        }

        It 'F4-n3: npm writes stderr and exits non-zero -> warning, exit 0 (stderr is not a terminating error)' {
            $s = New-CodexSet 'F4n3' @{ NpmExit = 1; NpmStderr = $true }
            $r = Invoke-Codex $s
            $r.NpmInstalled | Should -BeTrue
            $r.ExitCode     | Should -Be 0
            $r.Output       | Should -Match 'WARNING'
        }

        It 'F4-n4: caller has PSNativeCommandUseErrorActionPreference = $true (install.ps1 same-process run) -> npm failure still exit 0 + warning' {
            $s = New-CodexSet 'F4n4' @{ NpmExit = 1 }
            $driver = Join-Path $TestDrive 'F4n4-driver.ps1'
            Set-Content -LiteralPath $driver -Value @(
                '$ErrorActionPreference = "Stop"'
                '$PSNativeCommandUseErrorActionPreference = $true'
                "& '$($script:CodexPs -replace "'", "''")'"
                'exit $LASTEXITCODE'
            )
            $r = Invoke-Codex $s -Installer $driver
            $r.NpmInstalled | Should -BeTrue -Because $r.Output
            $r.ExitCode     | Should -Be 0 -Because $r.Output
            $r.Output       | Should -Match 'WARNING'
        }

        It 'F4-n5: unexpected exception (fnm output is invalid code) -> caught, "codex update skipped", exit 0' {
            $s = New-CodexSet 'F4n5' @{ FnmOutput = "throw 'fnm boom'" }
            $r = Invoke-Codex $s
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output   | Should -Match 'codex update skipped'
        }

        It 'F4-h: npm not on PATH -> warning, exit 0, no update' {
            $s = New-CodexSet 'F4h' @{ NoNpm = $true }
            $r = Invoke-Codex $s -Restrict
            $r.NpmInstalled | Should -BeFalse
            $r.CodexUpdated | Should -BeFalse
            $r.ExitCode     | Should -Be 0 -Because $r.Output
            $r.Output       | Should -Match 'WARNING'
        }
    }

    Context 'fresh install branch (codex not installed) is unchanged' {
        It 'F4-f: codex absent -> fnm + npm install runs, no wait helper, exit 0' {
            # A claude stub keeps the set valid; codex itself is not provided.
            $s = New-InstallerStubSet -Base (Join-Path $TestDrive 'F4f') -Cli 'claude'
            $r = Invoke-Codex $s -Restrict
            $r.NpmInstalled | Should -BeTrue -Because "calls=$($r.Calls -join '|') out=$($r.Output)"
            $r.Waits.Count  | Should -Be 0
            $r.ExitCode     | Should -Be 0
        }
    }
}

Describe 'agents-root-env-does-not-redirect-wait-helper' -Tag 'target:install/win/claude-code.ps1' {
    # #2561: the root comes from $PSScriptRoot, so AGENTS_ROOT pointing at a root whose
    # helper reports a timeout is ignored; the real helper (no CC) clears and update runs.
    It 'R-cc: claude-code.ps1 ignores AGENTS_ROOT for the wait helper' {
        $decoy = Join-Path $TestDrive 'decoy-cc'
        New-Item -ItemType Directory -Path (Join-Path $decoy 'install\lib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $decoy 'install\lib\wait-cc-exit.ps1') -Value 'exit 1'
        $s = New-InstallerStubSet -Base (Join-Path $TestDrive 'R-cc') -Cli 'claude'
        $r = Invoke-Codex $s -Installer $script:CcPs -Env @{
            AGENTS_ROOT                  = $decoy
            WAIT_CC_EXIT_SCRIPT_OVERRIDE = $null
            WAIT_CC_PROCESS_OVERRIDE     = 'none'
            WAIT_CC_POLL_INTERVAL        = '1'
            WAIT_CC_MAX_POLLS            = '1'
        }
        $r.Updated | Should -BeTrue -Because 'the decoy helper (exit 1) must not be the one run'
    }
}

Describe 'agents-root-env-does-not-redirect-wait-helper-codex' -Tag 'target:install/win/codex.ps1' {
    It 'R-codex: codex.ps1 ignores AGENTS_ROOT for the wait helper (both stages)' {
        $decoy = Join-Path $TestDrive 'decoy-codex'
        New-Item -ItemType Directory -Path (Join-Path $decoy 'install\lib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $decoy 'install\lib\wait-cc-exit.ps1') -Value 'exit 1'
        $s = New-CodexSet 'R-codex'
        $r = Invoke-Codex $s -Env @{
            AGENTS_ROOT                  = $decoy
            WAIT_CC_EXIT_SCRIPT_OVERRIDE = $null
            WAIT_CC_PROCESS_OVERRIDE     = 'none'
            WAIT_CODEX_PROCESS_OVERRIDE  = 'none'
            WAIT_CC_POLL_INTERVAL        = '1'
            WAIT_CC_MAX_POLLS            = '1'
        }
        $r.NpmInstalled | Should -BeTrue -Because "the decoy helper (exit 1) must not be the one run; out=$($r.Output)"
    }
}
