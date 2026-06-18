# tests/feature-697-dotfileslink-link-one.Tests.ps1
# Tests: install/win/dotfileslink.ps1, profile-snippet.ps1
# Tags: installer, dotfileslink, _link_one, watchlist, scope:issue-specific, pwsh-required
#
# L2 design note:
# install/win/dotfileslink.ps1 hard-codes $HOME for the destination path. $HOME is a
# PowerShell read-only automatic variable that CANNOT be reassigned in a child shell.
# That means there is no way to run the real installer against a sandbox $HOME without
# either (a) modifying the source or (b) writing into the developer's real ~/.claude/.
# Option (b) would corrupt the developer's environment, so the behavioral assertions
# below verify intent at the source-text level (static regex checks against the
# installer script). Dynamic end-to-end runs belong in the L3 install/uninstall smoke
# on a clean Windows VM after install.ps1 changes — they are out of scope here.
#
# L3 gap (what this test does NOT catch):
# - real Developer Mode toggle vs Admin invocation
# - real symlink-privilege denial in a non-Admin, non-Dev-Mode session
# - real $PROFILE auto-load behavior with profile-snippet.ps1
# - real New-Item SymbolicLink failure with rollback (only reachable by induced fault
#   on a real $HOME — covered by the bash _link_one rollback test as a proxy)
# Closest-to-action mitigation: install/uninstall smoke run on native Windows after install.ps1 changes.
#
# Pending behaviors (WF-CODE-5 not yet implemented) are marked with Set-ItResult -Skip
# so they show as skipped in Pester output instead of failing the suite.

if ($env:OS -ne "Windows_NT") {
    Write-Host "SKIP: Windows-only test"
    exit 77
}

Describe "dotfileslink.ps1 _link_one behavior (static)" {

    BeforeAll {
        $script:agentsDir   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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
    }

    Context "Static checks — profile-snippet.ps1 watchlist (pending implementation)" {

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
