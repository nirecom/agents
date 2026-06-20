# Tests: bin/confirm-off.ps1
# Tags: pwsh-required, bin, env, config, scope:common
# Pester L1 tests for bin/confirm-off.ps1 — pwsh counterpart of bin/confirm-off.
# Pre-implementation: all assertions will fail until /write-code lands
# bin/confirm-off.ps1.

Describe 'confirm-off.ps1 OFF/ON/ERROR matrix' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:helper = Join-Path $script:repoRoot 'bin\confirm-off.ps1'
        $script:gcvHelper = Join-Path $script:repoRoot 'bin\get-config-var.ps1'
        $script:loadEnv = Join-Path $script:repoRoot 'hooks\lib\load-env.js'
        # Build per-suite fixture mirroring real layout.
        $script:fix = Join-Path ([System.IO.Path]::GetTempPath()) ("co-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $script:fix 'bin') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:fix 'hooks\lib') -Force | Out-Null
        if (Test-Path $script:gcvHelper) { Copy-Item -Path $script:gcvHelper -Destination (Join-Path $script:fix 'bin\get-config-var.ps1') -Force }
        if (Test-Path $script:helper)    { Copy-Item -Path $script:helper    -Destination (Join-Path $script:fix 'bin\confirm-off.ps1')    -Force }
        if (Test-Path $script:loadEnv)   { Copy-Item -Path $script:loadEnv   -Destination (Join-Path $script:fix 'hooks\lib\load-env.js')  -Force }
        $script:fixHelper = Join-Path $script:fix 'bin\confirm-off.ps1'
    }

    AfterAll {
        if (Test-Path $script:fix) {
            Remove-Item -Recurse -Force $script:fix -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        [System.Environment]::SetEnvironmentVariable('CONFIRM_X', $null, 'Process')
        [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $script:fix, 'Process')
        # Reset .env
        Set-Content -Path (Join-Path $script:fix '.env') -Value '' -NoNewline
    }

    Context 'T01 — .env CONFIRM_X=off' {
        It 'prints OFF and exits 0' {
            Set-Content -Path (Join-Path $script:fix '.env') -Value 'CONFIRM_X=off' -NoNewline
            $out = (& pwsh -NoProfile -File $script:fixHelper CONFIRM_X on 2>&1) -join ''
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match 'OFF'
        }
    }

    Context 'T01b — process.env CONFIRM_X="" (empty) does not shadow .env=off' {
        It 'prints OFF and exits 0' {
            Set-Content -Path (Join-Path $script:fix '.env') -Value 'CONFIRM_X=off' -NoNewline
            [System.Environment]::SetEnvironmentVariable('CONFIRM_X', '', 'Process')
            try {
                $out = (& pwsh -NoProfile -File $script:fixHelper CONFIRM_X on 2>&1) -join ''
                $LASTEXITCODE | Should -Be 0
                $out | Should -Match 'OFF'
            } finally {
                [System.Environment]::SetEnvironmentVariable('CONFIRM_X', $null, 'Process')
            }
        }
    }

    Context 'T02 — .env CONFIRM_X=on' {
        It 'prints ON and exits 1' {
            Set-Content -Path (Join-Path $script:fix '.env') -Value 'CONFIRM_X=on' -NoNewline
            $out = (& pwsh -NoProfile -File $script:fixHelper CONFIRM_X on 2>&1) -join ''
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'ON'
        }
    }

    Context 'T03 — no key, default arg on' {
        It 'prints ON and exits 1' {
            $out = (& pwsh -NoProfile -File $script:fixHelper CONFIRM_X on 2>&1) -join ''
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'ON'
        }
    }

    Context 'T04 — no key, no default arg (fail-safe ON)' {
        It 'prints ON and exits 1' {
            $out = (& pwsh -NoProfile -File $script:fixHelper CONFIRM_X 2>&1) -join ''
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'ON'
        }
    }

    Context 'T05 — .env CONFIRM_X=unknown (unrecognized → fail-safe ON)' {
        It 'prints ON and exits 1' {
            Set-Content -Path (Join-Path $script:fix '.env') -Value 'CONFIRM_X=unknown' -NoNewline
            $out = (& pwsh -NoProfile -File $script:fixHelper CONFIRM_X on 2>&1) -join ''
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'ON'
        }
    }

    Context 'T06 — AGENTS_CONFIG_DIR unset entirely (ERROR + exit 2)' {
        It 'prints ERROR and exits 2' {
            # Isolate confirm-off.ps1 in a dir without hooks/lib sibling so
            # SCRIPT_DIR fallback also fails.
            $iso = Join-Path ([System.IO.Path]::GetTempPath()) ("co-iso-" + [guid]::NewGuid().ToString('N').Substring(0,8))
            New-Item -ItemType Directory -Path (Join-Path $iso 'bin') -Force | Out-Null
            if (Test-Path $script:gcvHelper) { Copy-Item -Path $script:gcvHelper -Destination (Join-Path $iso 'bin\get-config-var.ps1') -Force }
            if (Test-Path $script:helper)    { Copy-Item -Path $script:helper    -Destination (Join-Path $iso 'bin\confirm-off.ps1')    -Force }
            $isoHelper = Join-Path $iso 'bin\confirm-off.ps1'
            [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $null, 'Process')
            try {
                $out = (& pwsh -NoProfile -File $isoHelper CONFIRM_X on 2>&1) -join ''
                $LASTEXITCODE | Should -Be 2
                $out | Should -Match 'ERROR'
            } finally {
                Remove-Item -Recurse -Force $iso -ErrorAction SilentlyContinue
                [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $script:fix, 'Process')
            }
        }
    }

    Context 'T6b — AGENTS_CONFIG_DIR valid but hooks/lib/load-env.js absent (no script-dir fallback either)' {
        It 'prints ERROR and exits 2' {
            $iso = Join-Path ([System.IO.Path]::GetTempPath()) ("co-iso3-" + [guid]::NewGuid().ToString('N').Substring(0,8))
            New-Item -ItemType Directory -Path (Join-Path $iso 'bin') -Force | Out-Null
            # hooks\lib intentionally absent — both lookup paths (AGENTS_CONFIG_DIR and script-dir) fail.
            if (Test-Path $script:helper) { Copy-Item -Path $script:helper -Destination (Join-Path $iso 'bin\confirm-off.ps1') -Force }
            $isoHelper = Join-Path $iso 'bin\confirm-off.ps1'
            [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $iso, 'Process')
            try {
                $out = (& pwsh -NoProfile -File $isoHelper CONFIRM_X on 2>&1) -join ''
                $LASTEXITCODE | Should -Be 2
                $out | Should -Match 'ERROR'
            } finally {
                Remove-Item -Recurse -Force $iso -ErrorAction SilentlyContinue
                [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $script:fix, 'Process')
            }
        }
    }

    Context 'T07 — AGENTS_CONFIG_DIR set to nonexistent path' {
        It 'prints ERROR and exits 2' {
            $iso = Join-Path ([System.IO.Path]::GetTempPath()) ("co-iso2-" + [guid]::NewGuid().ToString('N').Substring(0,8))
            New-Item -ItemType Directory -Path (Join-Path $iso 'bin') -Force | Out-Null
            if (Test-Path $script:gcvHelper) { Copy-Item -Path $script:gcvHelper -Destination (Join-Path $iso 'bin\get-config-var.ps1') -Force }
            if (Test-Path $script:helper)    { Copy-Item -Path $script:helper    -Destination (Join-Path $iso 'bin\confirm-off.ps1')    -Force }
            $isoHelper = Join-Path $iso 'bin\confirm-off.ps1'
            [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', 'C:\nonexistent\path\co-test', 'Process')
            try {
                $out = (& pwsh -NoProfile -File $isoHelper CONFIRM_X on 2>&1) -join ''
                $LASTEXITCODE | Should -Be 2
                $out | Should -Match 'ERROR'
            } finally {
                Remove-Item -Recurse -Force $iso -ErrorAction SilentlyContinue
                [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $script:fix, 'Process')
            }
        }
    }

    Context 'T08 — no args (usage error)' {
        It 'exits 64 and emits usage to stderr' {
            $out = (& pwsh -NoProfile -File $script:fixHelper 2>&1) -join ''
            $LASTEXITCODE | Should -Be 64
            $out | Should -Not -BeNullOrEmpty
        }
    }

    Context 'T09 — process.env wins over .env' {
        It 'shell env CONFIRM_X=off + .env=on → OFF, exit 0' {
            Set-Content -Path (Join-Path $script:fix '.env') -Value 'CONFIRM_X=on' -NoNewline
            [System.Environment]::SetEnvironmentVariable('CONFIRM_X', 'off', 'Process')
            try {
                $out = (& pwsh -NoProfile -File $script:fixHelper CONFIRM_X on 2>&1) -join ''
                $LASTEXITCODE | Should -Be 0
                $out | Should -Match 'OFF'
            } finally {
                [System.Environment]::SetEnvironmentVariable('CONFIRM_X', $null, 'Process')
            }
        }
    }

    Context 'T10-T13 — vocabulary narrowing: legacy synonyms now treated as ON' {
        It "exits 1 (ON) for narrowed legacy value '<v>'" -TestCases @(
            @{ v = '0' }, @{ v = 'false' }, @{ v = 'no' }, @{ v = 'disabled' }
        ) {
            param($v)
            Set-Content -Path (Join-Path $script:fix '.env') -Value "CONFIRM_X=$v" -NoNewline
            $out = (& pwsh -NoProfile -File $script:fixHelper CONFIRM_X on 2>&1) -join ''
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'ON'
        }
    }
}
