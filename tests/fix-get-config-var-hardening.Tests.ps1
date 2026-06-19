# Tests: bin/get-config-var.ps1
# Tags: bin, pwsh, env, config, tests, scope:common, pwsh-required
# Pester tests for get-config-var.ps1 covering the #954 exit-code matrix
# and the #893 symlink/SCRIPT_DIR resolution path.
#
# Pre-implementation: most assertions will fail until /write-code updates
# bin/get-config-var.ps1. The OFF-value, explicit-ON, and value-mode
# $LASTEXITCODE=0 tests cover existing behaviour and must pass.

Describe 'get-config-var.ps1 --IsOff exit code matrix' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:helper = Join-Path $script:repoRoot 'bin\get-config-var.ps1'
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gcv-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:tmp) {
            Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        [System.Environment]::SetEnvironmentVariable('GETCFG_TESTVAR', $null, 'Process')
        [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $script:tmp, 'Process')
    }

    Context 'OFF values exit 0 (vocabulary: off only, case-insensitive)' {
        It "exits 0 for OFF value '<v>'" -TestCases @(
            @{ v = 'off' }, @{ v = 'OFF' }, @{ v = 'Off' }
        ) {
            param($v)
            [System.Environment]::SetEnvironmentVariable('GETCFG_TESTVAR', $v, 'Process')
            $null = & pwsh -NoProfile -File $script:helper -IsOff GETCFG_TESTVAR on 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context 'Explicit ON values exit 1 (vocabulary: on only, case-insensitive)' {
        It "exits 1 for ON value '<v>'" -TestCases @(
            @{ v = 'on' }, @{ v = 'ON' }, @{ v = 'On' }
        ) {
            param($v)
            [System.Environment]::SetEnvironmentVariable('GETCFG_TESTVAR', $v, 'Process')
            $null = & pwsh -NoProfile -File $script:helper -IsOff GETCFG_TESTVAR off 2>&1
            $LASTEXITCODE | Should -Be 1
        }
    }

    Context 'Formerly-synonymous values now exit 3 (not in off/on vocabulary)' {
        It "exits 3 for non-vocabulary value '<v>'" -TestCases @(
            @{ v = '0' }, @{ v = 'false' }, @{ v = 'no' }, @{ v = 'disabled' },
            @{ v = '1' }, @{ v = 'true' }, @{ v = 'yes' }, @{ v = 'enabled' }
        ) {
            param($v)
            [System.Environment]::SetEnvironmentVariable('GETCFG_TESTVAR', $v, 'Process')
            $null = & pwsh -NoProfile -File $script:helper -IsOff GETCFG_TESTVAR on 2>&1
            $LASTEXITCODE | Should -Be 3
        }
    }

    Context '#954 exit code matrix' {
        It 'unset key with no default exits 2' {
            $null = & pwsh -NoProfile -File $script:helper -IsOff GETCFG_TESTVAR 2>&1
            $LASTEXITCODE | Should -Be 2
        }

        It 'typo value exits 3 (unrecognized)' {
            [System.Environment]::SetEnvironmentVariable('GETCFG_TESTVAR', 'offf', 'Process')
            $null = & pwsh -NoProfile -File $script:helper -IsOff GETCFG_TESTVAR on 2>&1
            $LASTEXITCODE | Should -Be 3
        }

        It 'internal failure exits 4 (no load-env.js sibling)' {
            $isoDir = Join-Path $script:tmp 'iso'
            New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
            $copy = Join-Path $isoDir 'get-config-var.ps1'
            Copy-Item -Path $script:helper -Destination $copy -Force
            [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $null, 'Process')
            $null = & pwsh -NoProfile -File $copy -IsOff GETCFG_TESTVAR on 2>&1
            $LASTEXITCODE | Should -Be 4
        }
    }

    Context 'C8: value-mode preserves $LASTEXITCODE=0' {
        It 'value-mode (no -IsOff) leaves $LASTEXITCODE = 0' {
            $envDir = Join-Path $script:tmp 'c8'
            New-Item -ItemType Directory -Path $envDir -Force | Out-Null
            Set-Content -Path (Join-Path $envDir '.env') -Value 'CONFIRM_DETAIL=off' -NoNewline
            [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $envDir, 'Process')
            $out = (& pwsh -NoProfile -File $script:helper CONFIRM_DETAIL on 2>&1) -join ''
            $LASTEXITCODE | Should -Be 0
            $out | Should -Be 'off'
        }
    }
}
