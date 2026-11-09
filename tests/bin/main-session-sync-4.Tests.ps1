# Tests: bin/session-sync.ps1, install/win/session-sync-init.ps1
# Tags: bin, install, git, pwsh-required, scope:common
# Test: session-sync-init.ps1 and session-sync.ps1
# Uses temp directories to avoid touching real ~/.claude
# Git root is at ~/.claude/projects/ (not ~/.claude/)
# Split from main-session-sync.Tests.ps1 by runtime so each file stays under the launcher's 180 s timeout:
# the output-and-notifications Describe. The suite BeforeAll/AfterAll is duplicated from that file.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
    $DotfilesDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $InitScript = Join-Path (Join-Path $DotfilesDir "install") "win\session-sync-init.ps1"
    $SyncScript = Join-Path $DotfilesDir "bin\session-sync.ps1"

    # Deterministic git + workflow environment (#1214): the developer machine
    # sets core.hooksPath globally, may lack a git identity in CI, and may
    # default to `master` — all three broke fixture commits. Replacing the
    # global/system config with a minimal file removes them at once
    # (class-level fix); repo-local config still applies, so assertions about
    # what session-sync-init.ps1 writes keep testing the real thing.
    # WORKFLOW_PLANS_DIR is pinned for the same reason as the bash suite
    # (#1564) — see rules/test/fixture-isolation.md "Dual-pin the plans dir".
    $script:SavedEnv = @{
        GIT_CONFIG_NOSYSTEM = $env:GIT_CONFIG_NOSYSTEM
        GIT_CONFIG_GLOBAL   = $env:GIT_CONFIG_GLOBAL
        WORKFLOW_PLANS_DIR  = $env:WORKFLOW_PLANS_DIR
        USERPROFILE         = $env:USERPROFILE
    }
    # Suite-wide profile relocation (#1773): session-sync-init.ps1 fail-closed
    # refuses a -ClaudeDir that does not resolve inside $env:USERPROFILE, and
    # every fixture here lives under $env:TEMP. AfterAll restores it.
    $env:USERPROFILE = $env:TEMP
    $script:SuiteTmp = Join-Path $env:TEMP "session-sync-suite-$(Get-Random)"
    New-Item -ItemType Directory -Path $script:SuiteTmp -Force | Out-Null
    $script:SuiteGitConfig = Join-Path $script:SuiteTmp "gitconfig"
    Set-Content -Path $script:SuiteGitConfig -Value @(
        '[user]'
        "`tname = Session Sync Test"
        "`temail = session-sync-test@example.com"
        '[init]'
        "`tdefaultBranch = main"
        '[commit]'
        "`tgpgSign = false"
        '[advice] detachedHead = false'
        '[maintenance] auto = false'
        '[gc] auto = 0'
    )
    $env:GIT_CONFIG_NOSYSTEM = "1"
    $env:GIT_CONFIG_GLOBAL = $script:SuiteGitConfig
    $script:SuitePlansDir = Join-Path $script:SuiteTmp "workflow-plans"
    New-Item -ItemType Directory -Path $script:SuitePlansDir -Force | Out-Null
    $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) {
        $value = $script:SavedEnv[$name]
        if ($null -eq $value) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$name" -Value $value }
    }
    Remove-Item -Recurse -Force $script:SuiteTmp -ErrorAction SilentlyContinue
}

Describe "session-sync.ps1 output and notifications" -Tag 'target:bin/session-sync.ps1' {
    BeforeEach {
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        $script:RemoteDir = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        git init --bare $script:RemoteDir 2>&1 | Out-Null
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        # Local-path remotes are no longer accepted by the installer
        # allowlist (#1773); the fixture attaches its own origin.
        git -C (Join-Path $script:TestDir "projects") remote add origin $script:RemoteDir 2>&1 | Out-Null
        $projDir = Join-Path $script:TestDir "projects"
        git -C $projDir add -A 2>&1 | Out-Null
        git -C $projDir commit -m "initial" 2>&1 | Out-Null
        git -C $projDir push -u origin main 2>&1 | Out-Null
        # Functions outrank applications in command lookup, so this records Show-SessionToast's
        # powershell.exe call instead of raising a real toast.
        $global:ToastCalls = [System.Collections.Generic.List[string]]::new()
        function global:powershell.exe { $global:ToastCalls.Add(($args -join ' ')) | Out-Null }
    }

    AfterEach {
        Remove-Item -LiteralPath 'Function:\powershell.exe' -ErrorAction SilentlyContinue
        Remove-Variable -Name ToastCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:RemoteDir -ErrorAction SilentlyContinue
    }

    It "quiet push that succeeds shows exactly one 'push complete' toast" {
        $projDir = Join-Path $script:TestDir "projects\toast-ok"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "data.jsonl") -Value "test"
        & $SyncScript -Action push -ClaudeDir $script:TestDir -Quiet *>&1 | Out-Null
        $global:ToastCalls.Count | Should -Be 1 -Because "a quiet push raises one completion toast"
        $global:ToastCalls[0] | Should -Match 'push complete'
        $global:ToastCalls[0] | Should -Match "Tag = 'session-sync'" -Because "the tag lets the next push replace this toast"
    }

    It "quiet push that fails shows one 'push failed' toast and does not throw" {
        $projDir = Join-Path $script:TestDir "projects\toast-fail"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "data.jsonl") -Value "test"
        $missing = Join-Path $env:TEMP "session-sync-missing-$(Get-Random)"
        git -C (Join-Path $script:TestDir "projects") remote set-url origin $missing 2>&1 | Out-Null
        { & $SyncScript -Action push -ClaudeDir $script:TestDir -Quiet *>&1 | Out-Null } | Should -Not -Throw
        $global:ToastCalls.Count | Should -Be 1 -Because "a failed quiet push still raises exactly one toast"
        $global:ToastCalls[0] | Should -Match 'push failed \(exit code [1-9]\d*\)'
    }

    It "non-quiet push shows no toast" {
        $projDir = Join-Path $script:TestDir "projects\toast-loud"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "data.jsonl") -Value "test"
        & $SyncScript -Action push -ClaudeDir $script:TestDir *>&1 | Out-Null
        $global:ToastCalls.Count | Should -Be 0 -Because "toasts belong to -Quiet only"
    }

    It "push does not show create/delete mode messages" {
        $projDir = Join-Path $script:TestDir "projects\output-test"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "data.jsonl") -Value "test"
        $output = & $SyncScript -Action push -ClaudeDir $script:TestDir *>&1 | Out-String
        $output | Should -Not -Match "create mode" -Because "git commit -q should suppress file mode output"
        $output | Should -Not -Match "delete mode" -Because "git commit -q should suppress file mode output"
    }

    It "script contains Show-SessionToast function" {
        $content = Get-Content $SyncScript -Raw
        $content | Should -Match 'function Show-SessionToast' -Because "toast notification helper should be defined"
    }

    It "push flow does not emit a pushing toast" {
        # Only a single completion toast should fire per push — the legacy "pushing..." start toast was removed.
        $content = Get-Content $SyncScript -Raw
        $content | Should -Not -Match "Show-SessionToast\s+['""]pushing" -Because "start-of-push toast was removed to avoid a second banner"
    }

    It "quiet push does not write to stdout" {
        $projDir = Join-Path $script:TestDir "projects\quiet-test"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "data.jsonl") -Value "test"
        $output = & $SyncScript -Action push -ClaudeDir $script:TestDir -Quiet *>&1 | Out-String
        $output | Should -Not -Match "Pushed session data" -Because "quiet mode should use toast, not stdout"
    }
}
