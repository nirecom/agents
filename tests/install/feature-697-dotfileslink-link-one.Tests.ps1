# Tests: install/win/dotfileslink.ps1, profile-snippet.ps1
# Tags: installer, dotfileslink, _link_one, watchlist, scope:issue-specific, pwsh-required, bugfix-987, session-sync, fetch-deadline, process-tree, subprocess, config-dependent
# L2: the installer hard-codes read-only $HOME, so a sandboxed run is impossible
# without writing the real ~/.claude/; assertions are static regex checks instead.
# L3 gap: real Developer Mode vs Admin, real symlink-privilege denial, real $PROFILE
# auto-load, and real SymbolicLink failure + rollback (bash _link_one test is the
# proxy). Mitigation: install/uninstall smoke on native Windows after install.ps1 changes.

if ($env:OS -ne "Windows_NT") {
    Write-Host "SKIP: Windows-only test"
    exit 77
}

Describe "dotfileslink.ps1 _link_one behavior (static)" -Tag 'target:install/win/dotfileslink.ps1' {

    BeforeAll {
        $script:agentsDir   = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $script:scriptPath  = Join-Path $script:agentsDir "install\win\dotfileslink.ps1"
        $script:profilePath = Join-Path $script:agentsDir "profile-snippet.ps1"
        $script:scriptText  = Get-Content -LiteralPath $script:scriptPath -Raw
        $script:profileText = if (Test-Path -LiteralPath $script:profilePath) {
            Get-Content -LiteralPath $script:profilePath -Raw
        } else { "" }
    }

    Context "Normal cases — symlink table covers all four sibling paths" {

        It "declares a CLAUDE.md entry in the `$links table" {
            $script:scriptText | Should -Match 'Source\s*=\s*"CLAUDE\.md"\s*;\s*Dest\s*=\s*"\$ClaudeDir\\CLAUDE\.md"'
        }

        It "declares a skills directory entry in the `$links table" {
            $script:scriptText | Should -Match 'Source\s*=\s*"skills"\s*;\s*Dest\s*=\s*"\$ClaudeDir\\skills"\s*;\s*IsDir\s*=\s*\$true'
        }

        It "declares a rules directory entry in the `$links table" {
            $script:scriptText | Should -Match 'Source\s*=\s*"rules"\s*;\s*Dest\s*=\s*"\$ClaudeDir\\rules"\s*;\s*IsDir\s*=\s*\$true'
        }

        It "declares an agents directory entry in the `$links table" {
            $script:scriptText | Should -Match 'Source\s*=\s*"agents"\s*;\s*Dest\s*=\s*"\$ClaudeDir\\agents"\s*;\s*IsDir\s*=\s*\$true'
        }
    }

    Context "Normal cases — link loop semantics" {

        It "calls New-Item -ItemType SymbolicLink for each entry" {
            $script:scriptText | Should -Match 'New-Item\s+-ItemType\s+SymbolicLink\s+-Path\s+\$dest\s+-Target\s+\$source'
        }

        It "removes an existing ReparsePoint with the wrong target before relinking" {
            # "Relinking: $dest" / Remove-Item branch must be present.
            $script:scriptText | Should -Match 'Relinking:'
            $script:scriptText | Should -Match 'Remove-Item\s+\$dest\s+-Force'
        }

        It "backs up a regular (non-ReparsePoint) file to <name>.bak before linking" {
            $script:scriptText | Should -Match '\$backup\s*=\s*"\$dest\.bak"'
            $script:scriptText | Should -Match '\$tmpBackup\s*=\s*"\$dest\.bak\.tmp\.\$PID"'
            $script:scriptText | Should -Match 'Backing up:'
            $script:scriptText | Should -Match 'Rename-Item\s+\$dest\s+\$tmpBackup'
        }

        It "old .bak is preserved until New-Item succeeds, then promoted" {
            # Promotion: Rename-Item $tmpBackup $backup must appear after New-Item ... SymbolicLink
            $script:scriptText | Should -Match 'Rename-Item\s+\$tmpBackup\s+\$backup'
            # Verify ordering: New-Item SymbolicLink appears before the promotion rename
            $newItemIdx    = $script:scriptText.IndexOf("New-Item -ItemType SymbolicLink")
            $promotionIdx  = $script:scriptText.IndexOf("Rename-Item `$tmpBackup `$backup")
            $newItemIdx    | Should -BeGreaterThan -1
            $promotionIdx  | Should -BeGreaterThan -1
            $promotionIdx  | Should -BeGreaterThan $newItemIdx
        }

        It "promotes the new backup transactionally — old .bak survives a failed final rename" {
            # HIGH-2 fix: stage old .bak to .bak.old.$PID before renaming $tmpBackup to $backup.
            # If the final rename fails, restore old .bak from .old.$PID side path.
            $script:scriptText | Should -Match '\$oldBackup\s*=\s*"\$backup\.old\.\$PID"'
            $script:scriptText | Should -Match 'Rename-Item\s+\$backup\s+\$oldBackup'
            $script:scriptText | Should -Match 'Rename-Item\s+\$oldBackup\s+\$backup'
            $script:scriptText | Should -Match 'Backup promotion failed:'
        }

        It "uses -ErrorAction Stop on New-Item SymbolicLink so try/catch fires (HIGH-1)" {
            $script:scriptText | Should -Match 'New-Item\s+-ItemType\s+SymbolicLink\s+-Path\s+\$dest\s+-Target\s+\$source\s+-ErrorAction\s+Stop'
        }
    }

    Context "Idempotency cases" {

        It "short-circuits with 'Already linked' when the ReparsePoint target already matches" {
            $script:scriptText | Should -Match 'Already linked:'
        }
    }

    Context "Error cases" {

        It "restores original file when New-Item SymbolicLink throws" {
            # catch block must contain: Rename-Item $tmpBackup $dest (rollback) and the warning message
            $script:scriptText | Should -Match 'catch'
            $script:scriptText | Should -Match 'Rename-Item\s+\$tmpBackup\s+\$dest'
            $script:scriptText | Should -Match 'Write-Warning\s+"Failed to create symlink:'
        }

        It "continues to the next link when one link fails (does not throw)" {
            # catch block must increment $linkFailed and use continue; post-loop gate must exit 1
            $script:scriptText | Should -Match '\$linkFailed\+\+'
            $script:scriptText | Should -Match '\bcontinue\b'
            $script:scriptText | Should -Match 'if\s*\(\s*\$linkFailed\s*-gt\s*0\s*\)'
            $script:scriptText | Should -Match '\bexit\s+1\b'
        }

        It "edge: warns and skips when source path does not exist" {
            # Per-link guard: missing source must emit "Source not found" warning and continue.
            $script:scriptText | Should -Match 'Source not found'
        }

        It "edge: rollback path uses 'restore-symlink' label for old-target restore" {
            # When relinking a ReparsePoint and New-Item fails, rollback restores old symlink.
            $script:scriptText | Should -Match 'restore-symlink'
        }

        It "security: aborts with exit 1 when symlink privilege is unavailable (`$canSymlink false guard)" {
            # Early guard: if neither Developer Mode nor Administrator, exit 1 before any work.
            $script:scriptText | Should -Match 'if\s*\(\s*-not\s+\$canSymlink\s*\)'
            $script:scriptText | Should -Match 'canSymlink'
            $script:scriptText | Should -Match '\bexit\s+1\b'
        }

        It "has DOTFILESLINK_LINKS_ONLY early-exit test affordance" {
            $script:scriptText | Should -Match 'DOTFILESLINK_LINKS_ONLY'
            $script:scriptText | Should -Match 'exit\s+0'
        }
    }

    Context "Cleanup and registry" {

        It "removes obsolete commands symlink when present" {
            $script:scriptText | Should -Match 'Removing obsolete symlink'
        }

        It "removes stale settings.json symlink before assembling" {
            $script:scriptText | Should -Match 'Removed stale symlink'
        }

        It "registers review-code-codex launcher via Write-Launcher" {
            $script:scriptText | Should -Match 'Write-Launcher.*review-code-codex'
        }

        It "registers review-env-example launcher via Write-Launcher" {
            $script:scriptText | Should -Match 'Write-Launcher.*review-env-example'
        }

        It "gap4: assemble-settings.js invocation has an exit-code guard (LASTEXITCODE or throw)" {
            $script:scriptText | Should -Match 'assemble-settings'
            $script:scriptText | Should -Match '(?:\$LASTEXITCODE|\bthrow\b)'
        }
    }

    Context "Static checks — profile-snippet.ps1 watchlist" {

        It "profile-snippet.ps1 watchlist includes all four sibling paths" {
            if (-not $script:profileText) {
                Set-ItResult -Inconclusive -Because "profile-snippet.ps1 not found at $script:profilePath"
                return
            }
            $watchlistLine = ($script:profileText -split "`r?`n" |
                Where-Object { $_ -match '\$_agentSymlinks\s*=' } |
                Select-Object -First 1)
            if (-not $watchlistLine) {
                Set-ItResult -Inconclusive -Because "watchlist line (`$_agentSymlinks = ...) not found in profile-snippet.ps1"
                return
            }
            $missing = @()
            foreach ($needle in @("CLAUDE.md", "skills", "rules", "agents")) {
                if ($watchlistLine -notmatch [regex]::Escape($needle)) { $missing += $needle }
            }
            if ($missing.Count -gt 0) {
                Set-ItResult -Skip -Because "watchlist missing: $($missing -join ', ') (WF-CODE-5 will extend profile-snippet.ps1)"
                return
            }
            $missing.Count | Should -Be 0
        }
    }
}

# #1770 / #2658: the ps1 startup is `session-sync-engine startup --deadline-ms <n>`, n being
# SESSION_SYNC_STARTUP_DEADLINE_MS normalized by the snippet; on timeout the whole process
# tree is killed, not only git.exe (CPR-ORTH with
# tests/install/fix-1225-profile-snippet-guards/fetch-kill-deadline.sh, which reads the same
# tests/fixtures/session-sync-startup-deadline-table.txt). Cases pin the variable; the .env case writes a mirror .env instead.
# TL3 gap: a real SSH / credential-helper hang and a PS 5.1 host are not exercised; see
# bin/check-verification-gate.sh category pwsh-required.
BeforeDiscovery {
    $canRunStartup = [bool]($IsWindows -and (Get-Command pwsh -ErrorAction SilentlyContinue) -and
        (Get-Command git -ErrorAction SilentlyContinue) -and (Get-Command node -ErrorAction SilentlyContinue))
    $deadlineRows = @(Get-Content (Join-Path $PSScriptRoot '..\fixtures\session-sync-startup-deadline-table.txt') |
        Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
            $f = $_ -split '\|', 4
            @{ Label = $f[0]; Mode = $f[1]; Value = $f[2]; Expected = $f[3] }
        })
}

Describe 'profile-snippet.ps1 startup deadline (configurable, kills the fetch tree)' -Tag 'target:profile-snippet.ps1' -Skip:(-not $canRunStartup) {
    BeforeAll {
        $script:AgentsDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:HangSecs = 12
        # Fixed allowance over the pinned deadline for profile, get-config-var and node
        # start-up plus the kill; the pass line is "deadline + margin", never a constant.
        $script:MarginMs = 2000
        $script:EarlyMs = 200
        $script:Roots = [System.Collections.Generic.List[string]]::new()

        function New-StartupSandbox {
            param([switch]$Hang, [switch]$StubEngine)
            $root = Join-Path $env:TEMP "f2658-startup-$(Get-Random)"; $script:Roots.Add($root)
            $mirror = Join-Path $root 'agents'; $sbHome = Join-Path $root 'home'
            foreach ($d in @((Join-Path $mirror 'bin\lib'), (Join-Path $mirror 'hooks'), (Join-Path $mirror 'install\win'), (Join-Path $sbHome '.claude'))) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
            Copy-Item (Join-Path $script:AgentsDir 'profile-snippet.ps1') (Join-Path $mirror 'profile-snippet.ps1')
            Copy-Item (Join-Path $script:AgentsDir 'bin\get-config-var.ps1') (Join-Path $mirror 'bin\get-config-var.ps1')
            Copy-Item (Join-Path $script:AgentsDir 'hooks\lib') (Join-Path $mirror 'hooks\lib') -Recurse -Force
            Copy-Item (Join-Path $script:AgentsDir 'hooks\workflow-state') (Join-Path $mirror 'hooks\workflow-state') -Recurse -Force
            $engine = Join-Path $mirror 'bin\session-sync-engine'
            if ($StubEngine) {
                # Records its argv only, so a case reads exactly what the snippet passed.
                Set-Content -Path $engine -Value ('const fs = require("fs"), path = require("path");' +
                    ' fs.writeFileSync(path.join(__dirname, "..", "..", "engine-argv.out"), process.argv.slice(2).join("\n") + "\n");')
            } elseif (Test-Path (Join-Path $script:AgentsDir 'bin\session-sync-engine')) {
                Copy-Item (Join-Path $script:AgentsDir 'bin\session-sync-engine') $engine
            }
            $lib = Join-Path $script:AgentsDir 'bin\lib\session-sync'
            if (Test-Path $lib) { Copy-Item $lib (Join-Path $mirror 'bin\lib\session-sync') -Recurse -Force }
            Set-Content -Path (Join-Path $mirror 'bin\session-sync.ps1') -Value '# no-op stub'
            Set-Content -Path (Join-Path $mirror 'install\win\dotfileslink.ps1') -Value '# no-op stub'
            $gc = Join-Path $root 'gitconfig'
            Set-Content -Path $gc -Value @('[user]', '  name = F2658 Test', '  email = f2658@example.com',
                '[init]', '  defaultBranch = main', '[commit]', '  gpgSign = false', '[core]', '  hooksPath = NUL')
            $sb = @{ Root = $root; Mirror = $mirror; Home = $sbHome; GitConfig = $gc
                     Projects = (Join-Path $sbHome '.claude\projects'); M = ($root -replace '\\', '/') }
            $prev = @{ N = $env:GIT_CONFIG_NOSYSTEM; G = $env:GIT_CONFIG_GLOBAL }
            $env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_CONFIG_GLOBAL = $gc
            try {
                $remote = Join-Path $root 'remote.git'; $seed = Join-Path $root 'seed'
                git init -q --bare $remote *> $null
                git clone -q $remote $seed *> $null
                Set-Content -Path (Join-Path $seed 'a.jsonl') -Value '{"uuid":"a"}'
                git -C $seed add -A *> $null; git -C $seed commit -qm base *> $null; git -C $seed push -q -u origin main *> $null
                git clone -q $remote $sb.Projects *> $null
                if ($Hang) {
                    # upload-pack records GIT_TERMINAL_PROMPT, starts a grandchild, then hangs;
                    # a completion marker appears only for a process nobody killed.
                    $m = $sb.M
                    [System.IO.File]::WriteAllText((Join-Path $root 'hang.sh'), (@(
                        '#!/bin/sh'
                        "printf '%s' `"`${GIT_TERMINAL_PROMPT-UNSET}`" > '$m/gtp.out'"
                        "( sleep $script:HangSecs; printf done > '$m/grandchild-completed.out' ) &"
                        "sleep $script:HangSecs"
                        "printf done > '$m/hang-completed.out'") -join "`n") + "`n")
                    git -C $sb.Projects config remote.origin.uploadpack "sh '$m/hang.sh'" *> $null
                }
            } finally {
                if ($null -eq $prev.N) { Remove-Item Env:GIT_CONFIG_NOSYSTEM -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_NOSYSTEM = $prev.N }
                if ($null -eq $prev.G) { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_GLOBAL = $prev.G }
            }
            $sb
        }

        # $HOME is ReadOnly+AllScope, so the driver overrides it globally before dot-sourcing,
        # as a real profile load does; the Stopwatch times only the source. -Mode pins
        # SESSION_SYNC_STARTUP_DEADLINE_MS: 'unset' removes it, 'set' assigns -Value.
        function Invoke-TimedProfile {
            param($Sandbox, [string]$Mode, [string]$Value = '')
            $pin = if ($Mode -eq 'unset') { 'Remove-Item Env:SESSION_SYNC_STARTUP_DEADLINE_MS -ErrorAction SilentlyContinue' }
                   else { "`$env:SESSION_SYNC_STARTUP_DEADLINE_MS = '$($Value -replace "'", "''")'" }
            $driver = Join-Path $Sandbox.Root 'driver.ps1'
            Set-Content -Path $driver -Value @(
                '$ErrorActionPreference = "Continue"'
                'Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue'
                '$env:SESSION_SYNC = "on"'
                $pin
                "Set-Variable -Name HOME -Value '$($Sandbox.Home)' -Scope Global -Force"
                "`$env:GIT_CONFIG_NOSYSTEM = '1'; `$env:GIT_CONFIG_GLOBAL = '$($Sandbox.GitConfig)'"
                '$sw = [System.Diagnostics.Stopwatch]::StartNew()'
                ". '$($Sandbox.Mirror)\profile-snippet.ps1'"
                '$sw.Stop(); Write-Output "ELAPSED_MS=$($sw.ElapsedMilliseconds)"')
            $out = Join-Path $Sandbox.Root 'child.out'; $err = Join-Path $Sandbox.Root 'child.err'
            $p = Start-Process pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', "`"$driver`"" -NoNewWindow -PassThru `
                -RedirectStandardOutput $out -RedirectStandardError $err
            if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'child profile load exceeded 60s' }
            $text = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue)
            $ms = if ($text -match 'ELAPSED_MS=(\d+)') { [int]$Matches[1] } else { -1 }
            @{ Code = $p.ExitCode; Ms = $ms; Out = $text + [string](Get-Content $err -Raw -ErrorAction SilentlyContinue) }
        }
    }

    AfterAll {
        foreach ($r in $script:Roots) { Remove-Item -Recurse -Force $r -ErrorAction SilentlyContinue }
    }

    It 'returns inside the configured deadline plus margin and leaves no survivor of the fetch tree' {
        # Far from the 3000 default (a hard-coded deadline fails the lower bound), under the hang.
        $pinned = 6000
        $sb = New-StartupSandbox -Hang
        $start = Get-Date
        $r = Invoke-TimedProfile -Sandbox $sb -Mode set -Value "$pinned"
        $r.Code | Should -Be 0 -Because "the profile load must not fail (output: $($r.Out))"
        $r.Ms | Should -BeGreaterOrEqual ($pinned - $script:EarlyMs) -Because "the hung fetch must hold the load until the deadline (output: $($r.Out))"
        $r.Ms | Should -BeLessThan ($pinned + $script:MarginMs) -Because "SESSION_SYNC_STARTUP_DEADLINE_MS=$pinned bounds the profile load"
        Test-Path (Join-Path $sb.Root 'gtp.out') | Should -BeTrue -Because 'the fetch must reach upload-pack, or the deadline is never exercised'
        (Get-Content (Join-Path $sb.Root 'gtp.out') -Raw) | Should -Be '0'
        # Wait out the hang window, so a survivor has had time to write its marker.
        $left = $script:HangSecs + 3 - ((Get-Date) - $start).TotalSeconds
        if ($left -gt 0) { Start-Sleep -Milliseconds ([int]($left * 1000)) }
        Test-Path (Join-Path $sb.Root 'hang-completed.out') | Should -BeFalse -Because 'upload-pack (the child of git) must be killed with git'
        Test-Path (Join-Path $sb.Root 'grandchild-completed.out') | Should -BeFalse -Because 'the whole process tree must be killed, grandchildren included'
    }

    It 'passes <Label> (<Mode> "<Value>") to the engine as --deadline-ms <Expected>' -ForEach $deadlineRows {
        $sb = New-StartupSandbox -StubEngine
        $r = Invoke-TimedProfile -Sandbox $sb -Mode $Mode -Value $Value
        $r.Code | Should -Be 0 -Because "the profile load must not fail (output: $($r.Out))"
        $argvFile = Join-Path $sb.Root 'engine-argv.out'
        Test-Path $argvFile | Should -BeTrue -Because "the snippet must start session-sync-engine (output: $($r.Out))"
        $argv = @(Get-Content $argvFile)
        $argv[0] | Should -Be 'startup'
        @($argv | Where-Object { $_ -eq '--deadline-ms' }).Count | Should -Be 1
        $argv[[array]::IndexOf($argv, '--deadline-ms') + 1] | Should -Be $Expected
    }

    It 'reads SESSION_SYNC_STARTUP_DEADLINE_MS from the mirror .env when the process variable is unset' {
        $want = '7500'
        $sb = New-StartupSandbox -StubEngine
        Set-Content -Path (Join-Path $sb.Mirror '.env') -Value "SESSION_SYNC_STARTUP_DEADLINE_MS=$want"
        $r = Invoke-TimedProfile -Sandbox $sb -Mode unset
        $r.Code | Should -Be 0 -Because "the profile load must not fail (output: $($r.Out))"
        $argvFile = Join-Path $sb.Root 'engine-argv.out'
        Test-Path $argvFile | Should -BeTrue -Because "the snippet must start session-sync-engine (output: $($r.Out))"
        $argv = @(Get-Content $argvFile)
        $argv[[array]::IndexOf($argv, '--deadline-ms') + 1] | Should -Be $want -Because 'the .env value must reach the engine'
    }
}
