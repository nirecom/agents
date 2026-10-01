# Tests: tests/lib/pester-process-helpers.ps1
# Tags: test-infra, pester, pester-process-helpers, TL2, scope:issue-specific, pwsh-required
# Invoke-PwshChild contract: exit code propagation, timeout (TimedOut, 124, child killed),
# and the per-call environment overlay ($null removes; the parent is never mutated).

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'pester-process-helpers.ps1')
    $script:ProbeName = 'PESTER_HELPER_PROBE_2476'
    $script:ProbePrior = [Environment]::GetEnvironmentVariable($script:ProbeName)
    [Environment]::SetEnvironmentVariable($script:ProbeName, 'parent-value')
}

AfterAll {
    [Environment]::SetEnvironmentVariable($script:ProbeName, $script:ProbePrior)
}

Describe 'invoke-pwsh-child-contract' {
    It 'IPC-exit: child exit code <Code> propagates, TimedOut false' -ForEach @(
        @{ Code = 0 }
        @{ Code = 3 }
    ) {
        $f = Join-Path $TestDrive "exit-$Code.ps1"
        Set-Content -LiteralPath $f -Value @("Write-Output 'out-line'", "[Console]::Error.WriteLine('err-line')", "exit $Code")
        $r = Invoke-PwshChild -File $f -TimeoutSec 30
        $r.ExitCode | Should -Be $Code
        $r.TimedOut | Should -BeFalse
        $r.StdOut   | Should -Match 'out-line'
        $r.StdErr   | Should -Match 'err-line'
        $r.Output   | Should -Match 'out-line'
        $r.Output   | Should -Match 'err-line'
    }

    It 'IPC-timeout: a hung child is killed at the deadline, TimedOut true, exit 124' {
        $pidFile = Join-Path $TestDrive 'child.pid'
        $f = Join-Path $TestDrive 'hang.ps1'
        Set-Content -LiteralPath $f -Value @("Set-Content -LiteralPath '$pidFile' -Value `$PID", 'Start-Sleep -Seconds 60', 'exit 0')
        $r = Invoke-PwshChild -File $f -TimeoutSec 3
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -Be 124
        $r.Seconds  | Should -BeLessThan 30
        $pidFile | Should -Exist
        $childPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
        Get-Process -Id $childPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'IPC-env-null-removes: a $null overlay value removes the inherited variable in the child only' {
        $f = Join-Path $TestDrive 'env-probe.ps1'
        Set-Content -LiteralPath $f -Value @(
            "`$v = [Environment]::GetEnvironmentVariable('$script:ProbeName')"
            "if (`$null -eq `$v) { Write-Output 'PROBE=<absent>' } else { Write-Output ('PROBE=' + `$v) }"
        )
        $inherited = Invoke-PwshChild -File $f -TimeoutSec 30
        $inherited.Output | Should -Match 'PROBE=parent-value'
        $removed = Invoke-PwshChild -File $f -TimeoutSec 30 -Environment @{ $script:ProbeName = $null }
        $removed.Output | Should -Match 'PROBE=<absent>'
        $set = Invoke-PwshChild -File $f -TimeoutSec 30 -Environment @{ $script:ProbeName = 'child-value' }
        $set.Output | Should -Match 'PROBE=child-value'
        [Environment]::GetEnvironmentVariable($script:ProbeName) | Should -BeExactly 'parent-value'
    }
}
