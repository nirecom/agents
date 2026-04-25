# Test: session-sync-init.ps1 and session-sync.ps1
# Uses temp directories to avoid touching real ~/.claude
# Git root is at ~/.claude/projects/ (not ~/.claude/)

BeforeAll {
    $DotfilesDir = Split-Path -Parent $PSScriptRoot
    $InitScript = Join-Path (Join-Path $DotfilesDir "install") "win\session-sync-init.ps1"
    $SyncScript = Join-Path $DotfilesDir "bin\session-sync.ps1"
}

Describe "session-sync-init.ps1" {
    BeforeEach {
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        # Create fake projects/ structure
        $projDir = Join-Path $script:TestDir "projects\C--LLM-ai-specs"
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
        # Create initial commit so push/pull tests work
        $projDir = Join-Path $script:TestDir "projects"
        git -C $projDir add .gitattributes 2>&1 | Out-Null
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
        git -C $seedDir checkout -b main 2>&1 | Out-Null
        Set-Content -Path (Join-Path $seedDir "seed-session.jsonl") -Value '{"seed":"data"}'
        printf "* text eol=lf`n" | Set-Content -Path (Join-Path $seedDir ".gitattributes") -NoNewline
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
}

Describe "session-sync.ps1 retry loop" {
    BeforeEach {
        $script:TestDir = Join-Path $env:TEMP "session-sync-test-$(Get-Random)"
        $script:RemoteDir = Join-Path $env:TEMP "session-sync-remote-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
        git init --bare $script:RemoteDir 2>&1 | Out-Null
        & $InitScript -ClaudeDir $script:TestDir -RemoteUrl $script:RemoteDir
        $projDir = Join-Path $script:TestDir "projects"
        git -C $projDir add .gitattributes 2>&1 | Out-Null
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
        git -C $projDir add .gitattributes 2>&1 | Out-Null
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
