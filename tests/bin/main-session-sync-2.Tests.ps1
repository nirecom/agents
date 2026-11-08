# Tests: bin/session-sync.ps1, install/win/session-sync-init.ps1
# Tags: bin, install, git, pwsh-required, scope:common
# Test: session-sync-init.ps1 and session-sync.ps1
# Uses temp directories to avoid touching real ~/.claude
# Git root is at ~/.claude/projects/ (not ~/.claude/)
# Split from main-session-sync.Tests.ps1 so each file stays under the launcher's 180 s timeout
# (main-session-sync-3.Tests.ps1 holds the reset and retry-loop Describes; the output-and-notifications
# Describe moved to main-session-sync.Tests.ps1 by runtime).

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
        '[commit] gpgSign = false'
        '[advice] detachedHead = false'
        '[maintenance] auto = false'
        '[gc] auto = 0'
    )
    $env:GIT_CONFIG_NOSYSTEM = "1"
    $env:GIT_CONFIG_GLOBAL = $script:SuiteGitConfig
    $script:SuitePlansDir = Join-Path $script:SuiteTmp "workflow-plans"
    New-Item -ItemType Directory -Path $script:SuitePlansDir -Force | Out-Null
    $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir

    # Make a freshly created/cloned *fixture* repo safe to commit in regardless
    # of machine config. Redundant with the global-config isolation above by
    # design: if that isolation is ever narrowed, the fixtures still hold.
    function Initialize-FixtureRepo {
        param([Parameter(Mandatory)][string]$RepoDir)
        git -C $RepoDir config user.email "session-sync-test@example.com" 2>&1 | Out-Null
        git -C $RepoDir config user.name "Session Sync Test" 2>&1 | Out-Null
        git -C $RepoDir config core.hooksPath NUL 2>&1 | Out-Null
        git -C $RepoDir config commit.gpgSign false 2>&1 | Out-Null
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) {
        $value = $script:SavedEnv[$name]
        if ($null -eq $value) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$name" -Value $value }
    }
    Remove-Item -Recurse -Force $script:SuiteTmp -ErrorAction SilentlyContinue
}

Describe "session-sync.ps1 plans sync" -Tag 'target:bin/session-sync.ps1' {
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
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:RemoteDir -ErrorAction SilentlyContinue
    }

    # The plans *source* is WORKFLOW_PLANS_DIR (resolved via
    # hooks/lib/workflow-plans-dir.js), never <ClaudeDir>\plans. Seeding a
    # directory under $script:TestDir without also pointing the variable at it
    # asserted against a path bin/session-sync.ps1 does not read, while the
    # script silently synced the developer's real ~/.workflow-plans.
    It "push copies plans to projects/plans/" {
        $plansDir = Join-Path $script:TestDir "plans"
        New-Item -ItemType Directory -Path $plansDir -Force | Out-Null
        Set-Content -Path (Join-Path $plansDir "abc-intent.md") -Value "intent content"
        try {
            $env:WORKFLOW_PLANS_DIR = $plansDir
            & $SyncScript -Action push -ClaudeDir $script:TestDir
        } finally {
            $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
        }
        $syncedPlan = Join-Path $script:TestDir "projects\plans\abc-intent.md"
        Test-Path $syncedPlan | Should -BeTrue -Because "plans/abc-intent.md should be copied into projects/plans/"
    }

    # Regression coverage for the #1757 pull fix.
    It "pull merges plans into ~/.workflow-plans/" {
        # Seed remote with plans/remote-plan.md
        $seedDir = Join-Path $env:TEMP "session-sync-plans-seed-$(Get-Random)"
        git clone $script:RemoteDir $seedDir 2>&1 | Out-Null
        Initialize-FixtureRepo $seedDir
        $seedPlansDir = Join-Path $seedDir "plans"
        New-Item -ItemType Directory -Path $seedPlansDir -Force | Out-Null
        Set-Content -Path (Join-Path $seedPlansDir "remote-plan.md") -Value "remote content"
        git -C $seedDir add . 2>&1 | Out-Null
        git -C $seedDir commit -m "seed plans" 2>&1 | Out-Null
        git -C $seedDir push 2>&1 | Out-Null
        Remove-Item -Recurse -Force $seedDir -ErrorAction SilentlyContinue
        # Local has its own plan
        $localPlansDir = Join-Path $script:TestDir "plans"
        New-Item -ItemType Directory -Path $localPlansDir -Force | Out-Null
        Set-Content -Path (Join-Path $localPlansDir "local-plan.md") -Value "local content"
        try {
            $env:WORKFLOW_PLANS_DIR = $localPlansDir
            & $SyncScript -Action pull -ClaudeDir $script:TestDir
        } finally {
            $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
        }
        Test-Path (Join-Path $localPlansDir "remote-plan.md") | Should -BeTrue -Because "remote plan should be merged"
        Test-Path (Join-Path $localPlansDir "local-plan.md") | Should -BeTrue -Because "local plan should be preserved"
    }

    # Regression coverage for the #1757 pull fix.
    It "pull when local plans dir absent creates local plans" {
        # Seed remote with plans/remote-only.md
        $seedDir = Join-Path $env:TEMP "session-sync-plans-seed2-$(Get-Random)"
        git clone $script:RemoteDir $seedDir 2>&1 | Out-Null
        Initialize-FixtureRepo $seedDir
        $seedPlansDir = Join-Path $seedDir "plans"
        New-Item -ItemType Directory -Path $seedPlansDir -Force | Out-Null
        Set-Content -Path (Join-Path $seedPlansDir "remote-only.md") -Value "remote only"
        git -C $seedDir add . 2>&1 | Out-Null
        git -C $seedDir commit -m "seed plans" 2>&1 | Out-Null
        git -C $seedDir push 2>&1 | Out-Null
        Remove-Item -Recurse -Force $seedDir -ErrorAction SilentlyContinue
        # Ensure local plans dir does NOT exist
        $localPlansDir = Join-Path $script:TestDir "plans"
        Remove-Item -Recurse -Force $localPlansDir -ErrorAction SilentlyContinue
        try {
            $env:WORKFLOW_PLANS_DIR = $localPlansDir
            & $SyncScript -Action pull -ClaudeDir $script:TestDir
        } finally {
            $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
        }
        Test-Path (Join-Path $localPlansDir "remote-only.md") | Should -BeTrue -Because "pull should create local plans/ from remote"
    }

    It "push when plans dir absent succeeds without error" {
        # Ensure no plans dir locally: point the resolver at a path that does
        # not exist, so the "absent" branch is the one actually exercised.
        $localPlansDir = Join-Path $script:TestDir "plans"
        Remove-Item -Recurse -Force $localPlansDir -ErrorAction SilentlyContinue
        # Add a session jsonl so push has something to commit
        $projDir = Join-Path $script:TestDir "projects\noplans-proj"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "session.jsonl") -Value "data"
        try {
            $env:WORKFLOW_PLANS_DIR = $localPlansDir
            { & $SyncScript -Action push -ClaudeDir $script:TestDir } | Should -Not -Throw
        } finally {
            $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
        }
    }

    # WORKFLOW_PLANS_DIR is set explicitly so the plans source is a deterministic,
    # test-controlled directory rather than the real ~/.workflow-plans (which the
    # helper resolves to by default and which contains hundreds of live files).
    It "push excludes supervisor-state.json from projects/plans" {
        $plansDir = Join-Path $script:TestDir "plans"
        New-Item -ItemType Directory -Path $plansDir -Force | Out-Null
        Set-Content -Path (Join-Path $plansDir "abc-intent.md") -Value "intent content"
        Set-Content -Path (Join-Path $plansDir "abc-supervisor-state.json") -Value '{"state":"internal"}'
        try {
            $env:WORKFLOW_PLANS_DIR = $plansDir
            & $SyncScript -Action push -ClaudeDir $script:TestDir
        } finally {
            $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
        }
        $destDir = Join-Path $script:TestDir "projects\plans"
        Test-Path (Join-Path $destDir "abc-intent.md") | Should -BeTrue -Because ".md plan files must still sync"
        Test-Path (Join-Path $destDir "abc-supervisor-state.json") | Should -BeFalse -Because "supervisor-state.json is machine-local and must not be synced"
    }

    It "push excludes wi-checkpoint.json from projects/plans" {
        $plansDir = Join-Path $script:TestDir "plans"
        New-Item -ItemType Directory -Path $plansDir -Force | Out-Null
        Set-Content -Path (Join-Path $plansDir "abc-intent.md") -Value "intent content"
        Set-Content -Path (Join-Path $plansDir "abc-wi-checkpoint.json") -Value '{"step":"WF-CODE-3"}'
        try {
            $env:WORKFLOW_PLANS_DIR = $plansDir
            & $SyncScript -Action push -ClaudeDir $script:TestDir
        } finally {
            $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
        }
        $destDir = Join-Path $script:TestDir "projects\plans"
        Test-Path (Join-Path $destDir "abc-intent.md") | Should -BeTrue -Because ".md plan files must still sync"
        Test-Path (Join-Path $destDir "abc-wi-checkpoint.json") | Should -BeFalse -Because "wi-checkpoint.json is machine-local and must not be synced"
    }

    It "push still includes .md plan files when json files also present" {
        $plansDir = Join-Path $script:TestDir "plans"
        New-Item -ItemType Directory -Path $plansDir -Force | Out-Null
        Set-Content -Path (Join-Path $plansDir "abc-intent.md") -Value "intent content"
        Set-Content -Path (Join-Path $plansDir "abc-outline.md") -Value "outline content"
        Set-Content -Path (Join-Path $plansDir "abc-supervisor-state.json") -Value '{"state":"internal"}'
        try {
            $env:WORKFLOW_PLANS_DIR = $plansDir
            & $SyncScript -Action push -ClaudeDir $script:TestDir
        } finally {
            $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
        }
        $destDir = Join-Path $script:TestDir "projects\plans"
        Test-Path (Join-Path $destDir "abc-intent.md") | Should -BeTrue -Because "the .md filter must not drop legitimate plan files"
        Test-Path (Join-Path $destDir "abc-outline.md") | Should -BeTrue -Because "all .md plan files must sync"
    }
}

# ---------------------------------------------------------------------------
# Contract: the SESSION_SYNC toggle gates ONLY the six *automatic* call sites
# (profile-snippet startup fetch / codes() auto-push / install auto-init, each
# in .sh and .ps1). The manual CLI stays ungated — typing it expresses intent.
# These must pass before and after the gate lands; red means the gate leaked.
# Mirrors tests/main-session-sync/session-sync-independence.sh.
# ---------------------------------------------------------------------------
Describe "session-sync.ps1 SESSION_SYNC independence" -Tag 'target:bin/session-sync.ps1' {
    BeforeEach {
        $script:SavedSessionSync = $env:SESSION_SYNC
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
    }

    AfterEach {
        if ($null -eq $script:SavedSessionSync) { Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue }
        else { $env:SESSION_SYNC = $script:SavedSessionSync }
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:RemoteDir -ErrorAction SilentlyContinue
    }

    # Table-driven over the whole value domain: the shipped default (unset),
    # both recognized values, and an unrecognized one. All must behave alike.
    It "manual push still pushes with SESSION_SYNC=<value>" -ForEach @(
        @{ value = 'off' }, @{ value = 'on' }, @{ value = 'maybe' }, @{ value = $null }
    ) {
        if ($null -eq $value) { Remove-Item Env:SESSION_SYNC -ErrorAction SilentlyContinue }
        else { $env:SESSION_SYNC = $value }
        $projDir = Join-Path $script:TestDir "projects\ssi-proj"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "ssi.jsonl") -Value "data"
        $output = & $SyncScript -Action push -ClaudeDir $script:TestDir *>&1 | Out-String
        $output | Should -Match "Pushed session data" -Because "the manual CLI must never consult SESSION_SYNC"
    }

    It "manual pull still pulls with SESSION_SYNC=off" {
        $env:SESSION_SYNC = 'off'
        $output = & $SyncScript -Action pull -ClaudeDir $script:TestDir *>&1 | Out-String
        $output | Should -Match "Pulled session data" -Because "SESSION_SYNC=off must not suppress a manual pull"
    }

    It "manual status still reports with SESSION_SYNC=off" {
        $env:SESSION_SYNC = 'off'
        $output = & $SyncScript -Action status -ClaudeDir $script:TestDir *>&1 | Out-String
        $output | Should -Not -BeNullOrEmpty -Because "SESSION_SYNC=off must not suppress manual status output"
    }

    It "manual reset still resets with SESSION_SYNC=off" {
        $env:SESSION_SYNC = 'off'
        $output = & $SyncScript -Action reset -ClaudeDir $script:TestDir *>&1 | Out-String
        $output | Should -Match "Reset to remote state" -Because "SESSION_SYNC=off must not suppress a manual reset"
    }

    It "bin/session-sync.ps1 does not reference SESSION_SYNC" {
        $content = Get-Content $SyncScript -Raw
        $content | Should -Not -Match 'SESSION_SYNC' -Because "the manual path must stay ungated"
    }
}
