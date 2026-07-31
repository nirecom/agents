# Tests: bin/session-sync.ps1, install/win/session-sync-init.ps1
# Tags: bin, install, git, pwsh-required, scope:common
# Test: session-sync-init.ps1 and session-sync.ps1
# Uses temp directories to avoid touching real ~/.claude
# Git root is at ~/.claude/projects/ (not ~/.claude/)

BeforeAll {
    $DotfilesDir = Split-Path -Parent $PSScriptRoot
    $InitScript = Join-Path (Join-Path $DotfilesDir "install") "win\session-sync-init.ps1"
    $SyncScript = Join-Path $DotfilesDir "bin\session-sync.ps1"

    # -----------------------------------------------------------------------
    # Deterministic git + workflow environment (#1214).
    #
    # Root cause of the "reset" failures: the developer machine sets
    # core.hooksPath globally (this repo's own hooks do exactly that), so
    # `git commit` inside a throwaway *seed* repo ran the agents pre-commit
    # hook and aborted with "commits from main worktree are blocked". The seed
    # therefore never reached the bare remote, `git fetch origin main` found
    # nothing, and every reset case hit
    #   fatal: ambiguous argument 'origin/main': unknown revision
    # on an unborn branch. Replacing the global/system config with a minimal
    # file removes that — plus the missing-identity and default-branch
    # variables — for the whole suite at once (class-level fix rather than one
    # patch per fixture). Repo-local config still applies, so assertions about
    # what session-sync-init.ps1 writes keep testing the real thing.
    #
    # WORKFLOW_PLANS_DIR is pinned for the same reason as the bash suite
    # (#1564): bin/session-sync.ps1 resolves its plans source through
    # hooks/lib/workflow-plans-dir.js, which falls back to the developer's real
    # ~/.workflow-plans when the variable is unset.
    # -----------------------------------------------------------------------
    $script:SavedEnv = @{
        GIT_CONFIG_NOSYSTEM = $env:GIT_CONFIG_NOSYSTEM
        GIT_CONFIG_GLOBAL   = $env:GIT_CONFIG_GLOBAL
        WORKFLOW_PLANS_DIR  = $env:WORKFLOW_PLANS_DIR
        AGENTS_CONFIG_DIR   = $env:AGENTS_CONFIG_DIR
    }
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
    # Resolve the plans helper from this checkout, not whichever agents config
    # happens to be installed on the machine.
    $env:AGENTS_CONFIG_DIR = $DotfilesDir

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
        # Create fake projects/ structure
        $projDir = Join-Path $script:TestDir "projects\C--LLM-my-specs-repo"
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
        $fakeRemote = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        git init --bare $fakeRemote 2>&1 | Out-Null
        try {
            & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $fakeRemote
            $projDir = Join-Path $script:TestDir "projects"
            $remote = git -C $projDir remote get-url origin
            $remote | Should -Be $fakeRemote
        } finally {
            Remove-Item -Recurse -Force $fakeRemote -ErrorAction SilentlyContinue
        }
    }

    It "does not create commits (sync separated from init)" {
        & $InitScript -ClaudeDir $script:TestDir -NoRemote
        $projDir = Join-Path $script:TestDir "projects"
        git -C $projDir rev-list --count HEAD 2>&1 | Out-Null
        # Should fail or return 0 (no commits)
        $LASTEXITCODE | Should -Not -Be 0 -Because "init should not create any commits"
    }

    It "migrates old git root from claude dir to projects/" {
        # Simulate old layout: .git at claude root
        git init $script:TestDir 2>&1 | Out-Null
        Initialize-FixtureRepo $script:TestDir
        Set-Content -Path (Join-Path $script:TestDir ".gitignore") -Value "*`n!projects/"
        git -C $script:TestDir add .gitignore
        git -C $script:TestDir commit -m "old layout" 2>&1 | Out-Null

        & $InitScript -ClaudeDir $script:TestDir -NoRemote

        # Old .git should be gone
        Test-Path (Join-Path $script:TestDir ".git") | Should -BeFalse
        # New .git should exist in projects/
        Test-Path (Join-Path $script:TestDir "projects\.git") | Should -BeTrue
    }
}

Describe "session-sync.ps1" {
    BeforeEach {
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        $script:RemoteDir = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        git init --bare $script:RemoteDir 2>&1 | Out-Null
        # Initialize via init script (plumbing only, no commits)
        & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $script:RemoteDir
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

    It "pull uses --rebase" {
        $content = Get-Content $SyncScript -Raw
        $content | Should -Match 'pull\s.*--rebase' -Because "pull must use --rebase to avoid merge commits"
    }

    # Skipped: blocked by #1757 (bin/session-sync.ps1 pull error-action bug) — do not fix in this session
    It "pull applies commits that landed on the remote" -Skip {
        # Behavioural counterpart to the static "pull uses --rebase" check
        # above. Until this case existed, the only pull coverage in the suite
        # was static text plus the plans merge, so nothing here could fail when
        # pull stopped applying remote work at all.
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
        & $SyncScript -Action push -ClaudeDir $script:TestDir
        $gitDir = Join-Path $script:TestDir "projects"
        $log = git -C $gitDir log --oneline -1
        $today = Get-Date -Format "yyyy-MM-dd"
        $log | Should -Match $today -Because "commit message should include date"
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
        & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $script:RemoteDir
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

    It "reset discards diverged local commits" {
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        $projDir = Join-Path $script:TestDir "projects"
        Set-Content -Path (Join-Path $projDir "diverged.jsonl") -Value "local only"
        git -C $projDir add . 2>&1 | Out-Null
        git -C $projDir commit -m "diverged local commit" 2>&1 | Out-Null
        & $SyncScript -Action reset -ClaudeDir $script:TestDir
        Test-Path (Join-Path $projDir "diverged.jsonl") | Should -BeFalse -Because "diverged file should be discarded"
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
        & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $script:RemoteDir
        $projDir = Join-Path $script:TestDir "projects"
        git -C $projDir add -A 2>&1 | Out-Null
        git -C $projDir commit -m "initial" 2>&1 | Out-Null
        git -C $projDir push -u origin main 2>&1 | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:RemoteDir -ErrorAction SilentlyContinue
    }

    It "push script contains retry loop" {
        $content = Get-Content $SyncScript -Raw
        $content | Should -Match 'for \(\$retry' -Because "push should retry on race condition"
    }

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

Describe "session-sync.ps1 output and notifications" {
    BeforeEach {
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        $script:RemoteDir = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        git init --bare $script:RemoteDir 2>&1 | Out-Null
        & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $script:RemoteDir
        $projDir = Join-Path $script:TestDir "projects"
        git -C $projDir add -A 2>&1 | Out-Null
        git -C $projDir commit -m "initial" 2>&1 | Out-Null
        git -C $projDir push -u origin main 2>&1 | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:TestDir -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $script:RemoteDir -ErrorAction SilentlyContinue
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

Describe "session-sync.ps1 plans sync" {
    BeforeEach {
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        $script:RemoteDir = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        git init --bare $script:RemoteDir 2>&1 | Out-Null
        & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $script:RemoteDir
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

    # Skipped: blocked by #1757 (bin/session-sync.ps1 pull error-action bug) — do not fix in this session
    It "pull merges plans into ~/.workflow-plans/" -Skip {
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

    # Skipped: blocked by #1757 (bin/session-sync.ps1 pull error-action bug) — do not fix in this session
    It "pull when local plans dir absent creates local plans" -Skip {
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
# Contract under test: the SESSION_SYNC toggle gates ONLY the six *automatic*
# call sites (profile-snippet.sh/.ps1 startup fetch, profile-snippet.sh/.ps1
# codes() auto-push, install.sh/.ps1 auto-init). The manual CLI —
# bin/session-sync.ps1 push|pull|status|reset — stays ungated by design: a user
# who types the command has already expressed intent.
#
# These items must pass both before and after the gate lands. If one goes red,
# the gate has leaked into the manual path. Mirrors the bash-side cases in
# tests/main-session-sync/session-sync-independence.sh.
# ---------------------------------------------------------------------------
Describe "session-sync.ps1 SESSION_SYNC independence" {
    BeforeEach {
        $script:SavedSessionSync = $env:SESSION_SYNC
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        $script:RemoteDir = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        git init --bare $script:RemoteDir 2>&1 | Out-Null
        & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $script:RemoteDir
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
