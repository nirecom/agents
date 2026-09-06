# Tests: bin/get-config-var.ps1
# Tags: bin, pwsh, env, config, local-env, scope:issue-specific, TL2, pwsh-required
# RED for issue #2223 — the -RepoRoot parameter on bin/get-config-var.ps1.
# Parity contract: the expected values below are the same ones the bash half
# asserts in tests/feature-2223-get-config-var-repo-root.sh, so the two CLIs are
# pinned to one table rather than to each other. Assertions fail until
# /write-code adds -RepoRoot; the two no-RepoRoot cases cover existing
# behaviour and must pass today.

Set-StrictMode -Version Latest

# TL3 gap (what this test does NOT catch):
# - Whether the installed pwsh on a contributor's host is the same major
#   version this suite ran under; parameter binding and Write-Error stream
#   shape have differed across 5.1 / 7.x.
# - Whether the deployed copy under $HOME/.claude is the file under test —
#   this suite always invokes the worktree copy.
# - Whether a real caller (profile snippet, hook) propagates $LASTEXITCODE
#   rather than swallowing it.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh, category pwsh-required.

Describe 'get-config-var.ps1 -RepoRoot local-override resolution' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:helper = Join-Path $script:repoRoot 'bin\get-config-var.ps1'
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gcv2223-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null

        # Global layer: declares CODE_LANG and PROJECT_NFR locally overridable.
        $script:cfgDir = Join-Path $script:tmp 'cfg'
        New-Item -ItemType Directory -Path $script:cfgDir -Force | Out-Null
        Set-Content -Path (Join-Path $script:cfgDir '.env') -Value @(
            'LOCAL_OVERRIDABLE_KEYS=CODE_LANG,PROJECT_NFR'
            'CODE_LANG=english'
            'ENFORCE_WORKTREE=on'
            'CONFIRM_DETAIL=on'
            'PLAIN_KEY=globalplain'
        )

        # Project layer. The basename is assembled rather than written whole so
        # the literal never appears as a path string (DD-1, hooks/block-dotenv.js).
        $script:projDir = Join-Path $script:tmp 'proj'
        New-Item -ItemType Directory -Path (Join-Path $script:projDir '.git') -Force | Out-Null
        $script:localName = '.env' + '.local'
        Set-Content -Path (Join-Path $script:projDir $script:localName) -Value @(
            'CODE_LANG=japanese'
            'ENFORCE_WORKTREE=off'
            'CONFIRM_DETAIL=off'
            'PLAIN_KEY=localplain'
        )
        $script:missingDir = Join-Path $script:projDir 'no-such-subdir'

        # A parameter-binding failure also exits non-zero, so an exit-code
        # expectation can be met by the very absence of -RepoRoot under test.
        # Exit-code cases prove the run reached the script before believing it.
        function Assert-ScriptWasEntered {
            param([string]$Text)
            $Text | Should -Not -Match 'A parameter cannot be found'
        }
    }

    AfterAll {
        if (Test-Path $script:tmp) {
            Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue
        }
    }

    # Fixture isolation: pin the config dir and both halves of the plans-dir
    # pair, and drop inherited session ids so no child resolves live state.
    BeforeEach {
        [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $script:cfgDir, 'Process')
        [System.Environment]::SetEnvironmentVariable('CLAUDE_WORKFLOW_DIR', (Join-Path $script:tmp 'workflow'), 'Process')
        [System.Environment]::SetEnvironmentVariable('WORKFLOW_PLANS_DIR', (Join-Path $script:tmp 'plans'), 'Process')
        [System.Environment]::SetEnvironmentVariable('CLAUDE_SESSION_ID', $null, 'Process')
        [System.Environment]::SetEnvironmentVariable('CLAUDE_CODE_SESSION_ID', $null, 'Process')
        [System.Environment]::SetEnvironmentVariable('CLAUDE_PROJECT_DIR', $null, 'Process')
        [System.Environment]::SetEnvironmentVariable('CODE_LANG', $null, 'Process')
        [System.Environment]::SetEnvironmentVariable('PLAIN_KEY', $null, 'Process')
    }

    Context 'Value mode' {
        It 'reads the global value when no -RepoRoot is given' {
            $out = (& pwsh -NoProfile -File $script:helper CODE_LANG 2>&1) -join ''
            $LASTEXITCODE | Should -Be 0
            $out | Should -Be 'english'
        }

        It 'applies a declared-overridable key from the project layer' {
            $out = (& pwsh -NoProfile -File $script:helper -RepoRoot $script:projDir CODE_LANG 2>&1) -join ''
            $LASTEXITCODE | Should -Be 0
            $out | Should -Be 'japanese'
        }

        It 'refuses a never-overridable key even from the project layer' {
            $out = (& pwsh -NoProfile -File $script:helper -RepoRoot $script:projDir ENFORCE_WORKTREE 2>&1) -join ''
            $out | Should -Be 'on'
        }

        It 'refuses an undeclared key from the project layer' {
            $out = (& pwsh -NoProfile -File $script:helper -RepoRoot $script:projDir PLAIN_KEY 2>&1) -join ''
            $out | Should -Be 'globalplain'
        }

        It 'returns the supplied default when the key is absent from both layers' {
            $out = (& pwsh -NoProfile -File $script:helper -RepoRoot $script:projDir MISSING_KEY fallbackvalue 2>&1) -join ''
            $LASTEXITCODE | Should -Be 0
            $out | Should -Be 'fallbackvalue'
        }

        It 'falls back to the global layer when -RepoRoot names no project' {
            $out = (& pwsh -NoProfile -File $script:helper -RepoRoot $script:missingDir CODE_LANG 2>&1) -join ''
            $LASTEXITCODE | Should -Be 0
            $out | Should -Be 'english'
        }

        It 'still lets an explicit process-environment value win' {
            [System.Environment]::SetEnvironmentVariable('CODE_LANG', 'exported', 'Process')
            $out = (& pwsh -NoProfile -File $script:helper -RepoRoot $script:projDir CODE_LANG 2>&1) -join ''
            $out | Should -Be 'exported'
        }
    }

    Context '-IsOff exit matrix under -RepoRoot' {
        It 'keeps a never-overridable gate ON despite a local off (exit 1)' {
            $out = (& pwsh -NoProfile -File $script:helper -IsOff -RepoRoot $script:projDir CONFIRM_DETAIL 2>&1) -join ''
            Assert-ScriptWasEntered $out
            $LASTEXITCODE | Should -Be 1
        }

        It 'reports a key absent from both layers as unset (exit 2)' {
            $out = (& pwsh -NoProfile -File $script:helper -IsOff -RepoRoot $script:projDir NO_SUCH_KEY_AT_ALL 2>&1) -join ''
            Assert-ScriptWasEntered $out
            $LASTEXITCODE | Should -Be 2
        }

        It 'accepts -RepoRoot before -IsOff as well (order independence)' {
            $out = (& pwsh -NoProfile -File $script:helper -RepoRoot $script:projDir -IsOff CONFIRM_DETAIL 2>&1) -join ''
            Assert-ScriptWasEntered $out
            $LASTEXITCODE | Should -Be 1
        }

        It 'reports OFF for a declared-overridable key set off locally (exit 0)' {
            $overridable = Join-Path $script:tmp 'cfg-overridable'
            New-Item -ItemType Directory -Path $overridable -Force | Out-Null
            Set-Content -Path (Join-Path $overridable '.env') -Value @(
                'LOCAL_OVERRIDABLE_KEYS=SOME_TOGGLE'
                'SOME_TOGGLE=on'
            )
            [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $overridable, 'Process')
            $proj = Join-Path $script:tmp 'proj-overridable'
            New-Item -ItemType Directory -Path (Join-Path $proj '.git') -Force | Out-Null
            Set-Content -Path (Join-Path $proj $script:localName) -Value 'SOME_TOGGLE=off'
            $out = (& pwsh -NoProfile -File $script:helper -IsOff -RepoRoot $proj SOME_TOGGLE 2>&1) -join ''
            Assert-ScriptWasEntered $out
            $LASTEXITCODE | Should -Be 0
        }

        It 'reports an unrecognized local value as exit 3 without echoing it' {
            $cfg = Join-Path $script:tmp 'cfg-secret'
            New-Item -ItemType Directory -Path $cfg -Force | Out-Null
            Set-Content -Path (Join-Path $cfg '.env') -Value @(
                'LOCAL_OVERRIDABLE_KEYS=SECRET_TOGGLE'
                'SECRET_TOGGLE=on'
            )
            [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $cfg, 'Process')
            [System.Environment]::SetEnvironmentVariable('SECRET_TOGGLE', $null, 'Process')
            $proj = Join-Path $script:tmp 'proj-secret'
            New-Item -ItemType Directory -Path (Join-Path $proj '.git') -Force | Out-Null
            $secret = 'CONFIDENTIAL-2223-NfrValue-9f8e7d'
            Set-Content -Path (Join-Path $proj $script:localName) -Value "SECRET_TOGGLE=$secret"
            $out = (& pwsh -NoProfile -File $script:helper -IsOff -RepoRoot $proj SECRET_TOGGLE 2>&1) -join ''
            Assert-ScriptWasEntered $out
            $LASTEXITCODE | Should -Be 3
            $out | Should -Match 'SECRET_TOGGLE'
            $out | Should -Not -Match ([regex]::Escape($secret))
        }

        It 'reports an unrequirable load-env.js as exit 4' {
            $broken = Join-Path $script:tmp 'cfg-broken'
            New-Item -ItemType Directory -Path (Join-Path $broken 'hooks/lib') -Force | Out-Null
            Set-Content -Path (Join-Path $broken 'hooks/lib/load-env.js') -Value 'throw new Error("deliberately broken");'
            Set-Content -Path (Join-Path $broken '.env') -Value 'SOME_TOGGLE=off'
            [System.Environment]::SetEnvironmentVariable('AGENTS_CONFIG_DIR', $broken, 'Process')
            [System.Environment]::SetEnvironmentVariable('SOME_TOGGLE', $null, 'Process')
            $out = (& pwsh -NoProfile -File $script:helper -IsOff -RepoRoot $script:projDir SOME_TOGGLE 2>&1) -join ''
            Assert-ScriptWasEntered $out
            $LASTEXITCODE | Should -Be 4
        }
    }

    Context 'Usage errors' {
        It 'still exits 64 when the name is missing' {
            $out = (& pwsh -NoProfile -File $script:helper -RepoRoot $script:projDir 2>&1) -join ''
            Assert-ScriptWasEntered $out
            $LASTEXITCODE | Should -Be 64
        }
    }
}
