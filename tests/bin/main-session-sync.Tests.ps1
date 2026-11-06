# Tests: bin/session-sync.ps1, install/win/session-sync-init.ps1
# Tags: bin, install, git, pwsh-required, scope:common
# Test: session-sync-init.ps1 and session-sync.ps1
# Uses temp directories to avoid touching real ~/.claude
# Git root is at ~/.claude/projects/ (not ~/.claude/)
# Split with main-session-sync-2.Tests.ps1 so each file stays under the launcher's 180 s timeout.

BeforeAll {
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
        '[advice]'
        "`tdetachedHead = false"
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

Describe "session-sync-init.ps1" {
    BeforeEach {
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        $projDir = Join-Path $script:TestDir "projects\C--ws-my-specs-repo"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "session.jsonl") -Value "test"
        # Create files outside projects/ that should NOT be in git
        Set-Content -Path (Join-Path $script:TestDir "settings.json") -Value "{}"
        $statsigDir = Join-Path $script:TestDir "statsig"
        New-Item -ItemType Directory -Path $statsigDir -Force | Out-Null
        Set-Content -Path (Join-Path $statsigDir "data.json") -Value "{}"
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
    }

    It "initializes git repo inside projects/ not claude root" {
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        $projGit = Join-Path $script:TestDir "projects\.git"
        Test-Path $projGit | Should -BeTrue -Because "git root should be in projects/"
        $rootGit = Join-Path $script:TestDir ".git"
        Test-Path $rootGit | Should -BeFalse -Because "git root should NOT be in claude dir"
    }

    It "creates .gitattributes with eol=lf in projects/" {
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        $path = Join-Path $script:TestDir "projects\.gitattributes"
        Test-Path $path | Should -BeTrue
        $content = Get-Content $path -Raw
        $content | Should -Match '\* text eol=lf'
    }

    It "is idempotent - running twice keeps repo intact" {
        $projDir = Join-Path $script:TestDir "projects"
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        Test-Path (Join-Path $projDir ".git") | Should -BeTrue -Because "repo should survive re-run"
        Test-Path (Join-Path $projDir ".gitattributes") | Should -BeTrue -Because ".gitattributes should survive re-run"
    }

    It "files outside projects/ are not tracked" {
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        $projDir = Join-Path $script:TestDir "projects"
        $tracked = git -C $projDir ls-files
        $tracked | Should -Not -Match 'settings\.json' -Because "settings.json is outside git root"
        $tracked | Should -Not -Match 'statsig' -Because "statsig/ is outside git root"
    }

    It "sets remote when -NoRemote is not specified" {
        # String-comparison-only case: nothing fetches here, so an
        # allowlist-compliant literal replaces the bare local path (#1773).
        $remoteUrl = "https://example.invalid/remote-set.git"
        & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $remoteUrl
        $projDir = Join-Path $script:TestDir "projects"
        $remote = git -C $projDir remote get-url origin
        $remote | Should -Be $remoteUrl
    }

    It "does not create commits (sync separated from init)" {
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        $projDir = Join-Path $script:TestDir "projects"
        git -C $projDir rev-list --count HEAD 2>&1 | Out-Null
        # Should fail or return 0 (no commits)
        $LASTEXITCODE | Should -Not -Be 0 -Because "init should not create any commits"
    }

    # The old "migrates old git root" case is gone: it created the old repo
    # without an origin, which the provenance check now refuses by design.
    # Migration is covered by tests/install/main-session-sync-security.Tests.ps1.
}

Describe "session-sync.ps1" {
    BeforeEach {
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        $script:RemoteDir = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        git init --bare $script:RemoteDir 2>&1 | Out-Null
        # Initialize via init script (plumbing only, no commits)
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        # Local-path remotes are no longer accepted by the installer
        # allowlist (#1773); the fixture attaches its own origin.
        git -C (Join-Path $script:TestDir "projects") remote add origin $script:RemoteDir 2>&1 | Out-Null
        # Create initial commit so push/pull tests work.
        # `add -A`, not `add .gitattributes`: session-sync-init.ps1 also writes
        # .gitignore, and leaving it untracked makes the "no changes" cases see
        # a dirty tree and commit anyway.
        $projDir = Join-Path $script:TestDir "projects"
        git -C $projDir add -A 2>&1 | Out-Null
        git -C $projDir commit -m "initial" 2>&1 | Out-Null
        git -C $projDir push -u origin main 2>&1 | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:RemoteDir -ErrorAction SilentlyContinue
    }

    It "push commits with machine name in message" {
        $projDir = Join-Path $script:TestDir "projects\test-proj"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "session.jsonl") -Value "data"
        & $SyncScript -Action push -ClaudeDir $script:TestDir
        $gitDir = Join-Path $script:TestDir "projects"
        $log = git -C $gitDir log --oneline -1
        $log | Should -Match $env:COMPUTERNAME -Because "commit message should include machine name"
    }

    It "push with no changes doesn't create empty commit" {
        $gitDir = Join-Path $script:TestDir "projects"
        $commitsBefore = git -C $gitDir rev-list --count HEAD
        & $SyncScript -Action push -ClaudeDir $script:TestDir
        $commitsAfter = git -C $gitDir rev-list --count HEAD
        $commitsAfter | Should -Be $commitsBefore
    }

    # #2658: a remote-only pull fast-forwards main to the remote tip (no rebase, no new commit).
    It "remote-only pull fast-forwards main without a new commit" {
        $s = Join-Path $env:TEMP "session-sync-ff-seed-$(Get-Random)"; git clone $script:RemoteDir $s 2>&1 | Out-Null; Initialize-FixtureRepo $s
        Set-Content -Path (Join-Path $s "ff-remote.jsonl") -Value '{"remote":"ff"}'; git -C $s add -A 2>&1 | Out-Null
        git -C $s commit -m "remote-only change" 2>&1 | Out-Null; git -C $s push 2>&1 | Out-Null; $tip = (git -C $s rev-parse HEAD).Trim()
        Remove-Item -Recurse -Force $s -ErrorAction SilentlyContinue; & $SyncScript -Action pull -ClaudeDir $script:TestDir
        (git -C (Join-Path $script:TestDir "projects") rev-parse main).Trim() | Should -Be $tip -Because "main must equal the remote tip"
    }
    # Regression coverage for the #1757 pull fix: pull must apply remote work at all.
    It "pull applies commits that landed on the remote" {
        $seedDir = Join-Path $env:TEMP "session-sync-pull-seed-$(Get-Random)"
        git clone $script:RemoteDir $seedDir 2>&1 | Out-Null
        Initialize-FixtureRepo $seedDir
        Set-Content -Path (Join-Path $seedDir "remote-session.jsonl") -Value '{"remote":"data"}'
        git -C $seedDir add -A 2>&1 | Out-Null
        git -C $seedDir commit -m "seed from other machine" 2>&1 | Out-Null
        git -C $seedDir push 2>&1 | Out-Null
        Remove-Item -Recurse -Force $seedDir -ErrorAction SilentlyContinue

        & $SyncScript -Action pull -ClaudeDir $script:TestDir

        Test-Path (Join-Path $script:TestDir "projects\remote-session.jsonl") |
            Should -BeTrue -Because "pull must bring remote commits into the working tree"
    }

    # Regression guard for #1757 (C5): a non-zero `git pull` must abort before
    # the history/plans merge instead of merging stale local data silently.
    It "a failed pull throws and never reaches the merges" {
        $historyFile = Join-Path $script:TestDir "history.jsonl"
        Set-Content -Path $historyFile -Value '{"local":"before"}' -NoNewline
        $plansDir = Join-Path $script:TestDir "plans"
        New-Item -ItemType Directory -Path $plansDir -Force | Out-Null
        Set-Content -Path (Join-Path $plansDir "local-plan.md") -Value "local content"
        $missing = Join-Path $env:TEMP "session-sync-missing-$(Get-Random)"
        git -C (Join-Path $script:TestDir "projects") remote set-url origin $missing 2>&1 | Out-Null
        try {
            $env:WORKFLOW_PLANS_DIR = $plansDir
            { & $SyncScript -Action pull -ClaudeDir $script:TestDir } | Should -Throw
        } finally {
            $env:WORKFLOW_PLANS_DIR = $script:SuitePlansDir
        }
        (Get-Content $historyFile -Raw) | Should -Be '{"local":"before"}' -Because "a failed pull must not merge history"
        (Get-ChildItem $plansDir -File).Count | Should -Be 1 -Because "a failed pull must not merge plans"
    }

    It "status runs without error" {
        $output = & $SyncScript -Action status -ClaudeDir $script:TestDir 2>&1
        $LASTEXITCODE | Should -BeIn @(0, $null)
    }

    It "push checks for Claude Code process" {
        $content = Get-Content $SyncScript -Raw
        $content | Should -Match 'claude' -Because "push should check for running Claude Code process"
    }

    It "commit message includes timestamp" {
        $projDir = Join-Path $script:TestDir "projects\test-proj2"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "data.jsonl") -Value "test"
        $before = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        & $SyncScript -Action push -ClaudeDir $script:TestDir
        $after = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        $gitDir = Join-Path $script:TestDir "projects"
        $log = git -C $gitDir log --format=%s -1
        $log | Should -Match 'sync: \S+ \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' -Because "commit message should be 'sync: <host> <ISO timestamp>'"
        $log | Should -Match "sync: \S+ ($before|$after)T" -Because "engine writes a UTC ISO date (timezone-independent, tolerating a UTC midnight crossing)"
    }

    It "push copies history.jsonl into sync area" {
        # Create a history.jsonl in claude dir
        Set-Content -Path (Join-Path $script:TestDir "history.jsonl") -Value '{"display":"test","project":"C:\\git\\dotfiles","sessionId":"abc"}'
        $projDir = Join-Path $script:TestDir "projects\test-push-history"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "data.jsonl") -Value "trigger"
        & $SyncScript -Action push -ClaudeDir $script:TestDir
        $syncHistory = Join-Path $script:TestDir "projects\.history.jsonl"
        Test-Path $syncHistory | Should -BeTrue -Because "history.jsonl should be copied into sync area"
        Get-Content $syncHistory | Should -Match "abc" -Because "content should match source"
    }
}

Describe "session-sync.ps1 reset" {
    BeforeEach {
        # Create seeded remote
        $script:RemoteDir = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        $seedDir = Join-Path $env:TEMP "session-sync-seed-$(Get-Random)"
        git init --bare $script:RemoteDir 2>&1 | Out-Null
        git init $seedDir 2>&1 | Out-Null
        Initialize-FixtureRepo $seedDir
        git -C $seedDir checkout -b main 2>&1 | Out-Null
        Set-Content -Path (Join-Path $seedDir "seed-session.jsonl") -Value '{"seed":"data"}'
        # Written with Set-Content rather than `printf`: printf is not a
        # PowerShell cmdlet, so the old form silently depended on Git for
        # Windows' usr/bin being on PATH.
        Set-Content -Path (Join-Path $seedDir ".gitattributes") -Value "* text eol=lf" -NoNewline
        git -C $seedDir add . 2>&1 | Out-Null
        git -C $seedDir commit -m "seed from other machine" 2>&1 | Out-Null
        git -C $seedDir remote add origin $script:RemoteDir 2>&1 | Out-Null
        git -C $seedDir push -u origin main 2>&1 | Out-Null
        Remove-Item -Recurse -Force $seedDir -ErrorAction SilentlyContinue
        # Init fresh machine (plumbing only)
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        # Local-path remotes are no longer accepted by the installer
        # allowlist (#1773); the fixture attaches its own origin.
        git -C (Join-Path $script:TestDir "projects") remote add origin $script:RemoteDir 2>&1 | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:RemoteDir -ErrorAction SilentlyContinue
    }

    It "reset fetches remote files into working tree" {
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        $projDir = Join-Path $script:TestDir "projects"
        Test-Path (Join-Path $projDir "seed-session.jsonl") | Should -BeTrue -Because "remote file should be in working tree"
    }

    It "push works after reset (bidirectional)" {
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        $projDir = Join-Path $script:TestDir "projects\local-proj"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        Set-Content -Path (Join-Path $projDir "local.jsonl") -Value "data"
        & $SyncScript -Action push -ClaudeDir $script:TestDir
        $gitDir = Join-Path $script:TestDir "projects"
        $log = git -C $gitDir log --oneline -1
        $log | Should -Match "sync:" -Because "push should create sync commit after reset"
    }

    It "reset is idempotent" {
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        $projDir = Join-Path $script:TestDir "projects"
        Test-Path (Join-Path $projDir "seed-session.jsonl") | Should -BeTrue -Because "file should persist after double reset"
    }

    It "reset merges remote history.jsonl with local" {
        # Seed remote with .history.jsonl
        $seedDir2 = Join-Path $env:TEMP "session-sync-seed2-$(Get-Random)"
        git clone $script:RemoteDir $seedDir2 2>&1 | Out-Null
        Initialize-FixtureRepo $seedDir2
        Set-Content -Path (Join-Path $seedDir2 ".history.jsonl") -Value '{"display":"remote","project":"C:\\git\\dotfiles","sessionId":"r1","timestamp":1000}'
        git -C $seedDir2 add . 2>&1 | Out-Null
        git -C $seedDir2 commit -m "add history" 2>&1 | Out-Null
        git -C $seedDir2 push 2>&1 | Out-Null
        Remove-Item -Recurse -Force $seedDir2 -ErrorAction SilentlyContinue
        # Create local history
        Set-Content -Path (Join-Path $script:TestDir "history.jsonl") -Value '{"display":"local","project":"C:\\git\\dotfiles","sessionId":"l1","timestamp":2000}'
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        $history = Get-Content (Join-Path $script:TestDir "history.jsonl")
        ($history | Where-Object { $_ -match "r1" }).Count | Should -Be 1 -Because "remote entry should be merged"
        ($history | Where-Object { $_ -match "l1" }).Count | Should -Be 1 -Because "local entry should be preserved"
    }

    It "reset keeps diverged local commits and does not push them (#2658)" {
        & $SyncScript -Action reset -ClaudeDir $script:TestDir; $projDir = Join-Path $script:TestDir "projects"
        Set-Content -Path (Join-Path $projDir "diverged.jsonl") -Value "local only"
        git -C $projDir add . 2>&1 | Out-Null; git -C $projDir commit -m "diverged local commit" 2>&1 | Out-Null
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        Test-Path (Join-Path $projDir "diverged.jsonl") | Should -BeTrue -Because "reset must keep local data"
        git -C $script:RemoteDir cat-file -e main:diverged.jsonl 2>&1 | Out-Null; $LASTEXITCODE | Should -Not -Be 0 -Because "reset must never push"
    }

    It "reset sets mtime from last timestamp line when tail is metadata-only" {
        # Add a multi-line JSONL with metadata-only tail to the remote
        $extraSeedDir = Join-Path $env:TEMP "session-sync-extraseed-$(Get-Random)"
        git clone $script:RemoteDir $extraSeedDir 2>&1 | Out-Null
        Initialize-FixtureRepo $extraSeedDir
        $lines = @(
            '{"timestamp":"2024-01-01T10:00:00.000Z","type":"user","text":"hello"}',
            '{"timestamp":"2024-01-01T12:30:00.000Z","type":"assistant","text":"world"}',
            '{"ai-title":"test session","mode":"auto"}'
        )
        Set-Content -Path (Join-Path $extraSeedDir "has-metadata-tail.jsonl") -Value $lines
        git -C $extraSeedDir add . 2>&1 | Out-Null
        git -C $extraSeedDir commit -m "add has-metadata-tail session" 2>&1 | Out-Null
        git -C $extraSeedDir push 2>&1 | Out-Null
        Remove-Item -Recurse -Force $extraSeedDir -ErrorAction SilentlyContinue
        # Run reset — should restore mtime from T2, not T1 and not metadata-only line
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        $projDir = Join-Path $script:TestDir "projects"
        $f = Get-Item (Join-Path $projDir "has-metadata-tail.jsonl")
        $expectedTs = [datetime]::Parse("2024-01-01T12:30:00.000Z").ToLocalTime()
        # Allow 2-second tolerance for filesystem rounding
        $diff = [math]::Abs(($f.LastWriteTime - $expectedTs).TotalSeconds)
        $diff | Should -BeLessThan 2 -Because "mtime should match last timestamp line T2, not T1 or metadata line"
    }
}

Describe "session-sync.ps1 retry loop" {
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

    It "push delegates to session-sync-engine and carries no rebase (#2658)" {
        $code = (Get-Content $SyncScript) | Where-Object { $_ -notmatch '^\s*#' }; ($code -join "`n") | Should -Match 'session-sync-engine'
        ($code | Where-Object { $_ -match 'git.*(rebase|reset --hard)' }).Count | Should -Be 0 -Because "integration and retry live in the engine" }

    It "push recovers from pre-diverged state with unstaged changes" {
        $projDir = Join-Path $script:TestDir "projects"
        # Other machine pushes to remote (creates diverged state)
        $otherDir = Join-Path $env:TEMP "session-sync-other-$(Get-Random)"
        git clone $script:RemoteDir $otherDir 2>&1 | Out-Null
        Initialize-FixtureRepo $otherDir
        Set-Content -Path (Join-Path $otherDir "other-session.jsonl") -Value '{"other":"machine"}'
        git -C $otherDir add . 2>&1 | Out-Null
        git -C $otherDir commit -m "sync: other 2026-01-01 00:00" 2>&1 | Out-Null
        git -C $otherDir push 2>&1 | Out-Null
        Remove-Item -Recurse -Force $otherDir -ErrorAction SilentlyContinue
        # Local also commits (now diverged from remote)
        Set-Content -Path (Join-Path $projDir "local-committed.jsonl") -Value '{"local":"committed"}'
        git -C $projDir add . 2>&1 | Out-Null
        git -C $projDir commit -m "sync: local 2026-01-01 00:01" 2>&1 | Out-Null
        # Add untracked file (simulates Claude writing new session data)
        Set-Content -Path (Join-Path $projDir "local-unstaged.jsonl") -Value '{"local":"unstaged"}'
        # Push should recover via retry loop
        & $SyncScript -Action push -ClaudeDir $script:TestDir
        $log = git -C $projDir log --oneline -1
        $log | Should -Match "sync:" -Because "push should create sync commit after recovery"
        # All files should be on remote
        $checkDir = Join-Path $env:TEMP "session-sync-check-$(Get-Random)"
        git clone $script:RemoteDir $checkDir 2>&1 | Out-Null
        Test-Path (Join-Path $checkDir "other-session.jsonl") | Should -BeTrue -Because "other machine's file should be on remote"
        Test-Path (Join-Path $checkDir "local-committed.jsonl") | Should -BeTrue -Because "local committed file should be on remote"
        Test-Path (Join-Path $checkDir "local-unstaged.jsonl") | Should -BeTrue -Because "unstaged file should be committed and pushed"
        Remove-Item -Recurse -Force $checkDir -ErrorAction SilentlyContinue
    }
}
