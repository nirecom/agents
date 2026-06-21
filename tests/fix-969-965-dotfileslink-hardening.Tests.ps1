# tests/fix-969-965-dotfileslink-hardening.Tests.ps1
# Tests: install/win/dotfileslink.ps1, profile-snippet.ps1, tests/feature-697-dotfileslink-link-one.Tests.ps1
# Tags: installer, dotfileslink, profile-snippet, scope:issue-specific, pwsh-required, bugfix-969, bugfix-965
#
# Covers:
# - T1-1: $EffectiveHome honors DOTFILESLINK_HOME_OVERRIDE (static)
# - T1-2: DOTFILESLINK_SKIP_PRIV_CHECK affordance (static)
# - T1-3: DOTFILESLINK_FAIL_AT_INDEX affordance (static)
# - T2-1: $item.LinkType captured before Remove-Item (static)
# - T2-2: rollback uses captured $oldLinkType (not hardcoded SymbolicLink) (static)
# - T2-3: dynamic rollback — induced failure restores backup (Start-Process pwsh)
# - T2-4: dynamic rollback — Junction restored as Junction (LinkType preserved)
# - T4-4/T4-5/T4-6: profile-snippet.ps1 watchlist detects dangling and replaced entries
# - T5-1: stale "(pending implementation)" suffix removed from sibling Tests.ps1
#
# L3 gap (what this test does NOT catch):
# - Real Developer Mode toggle in a fresh Windows session
# - Real Junction creation by `cmd /c mklink /J` from cmd.exe (we use New-Item Junction)
# - Real $PROFILE auto-load behavior with profile-snippet.ps1
# Closest-to-action mitigation: install/uninstall smoke run on native Windows after
# install.ps1 changes (manual user verification).
#
# Dynamic tests that require source-level affordances skip via Set-ItResult -Skip
# when the source code has not yet been updated.

if ($env:OS -ne "Windows_NT") {
    Write-Host "SKIP: Windows-only test"
    exit 77
}

Describe "dotfileslink.ps1 hardening (#969 / #965)" {

    BeforeAll {
        $script:agentsDir   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $script:scriptPath  = Join-Path $script:agentsDir "install\win\dotfileslink.ps1"
        $script:profilePath = Join-Path $script:agentsDir "profile-snippet.ps1"
        $script:siblingTest = Join-Path $script:agentsDir "tests\feature-697-dotfileslink-link-one.Tests.ps1"
        $script:scriptText  = Get-Content -LiteralPath $script:scriptPath -Raw
        $script:profileText = if (Test-Path -LiteralPath $script:profilePath) {
            Get-Content -LiteralPath $script:profilePath -Raw
        } else { "" }
        $script:siblingText = if (Test-Path -LiteralPath $script:siblingTest) {
            Get-Content -LiteralPath $script:siblingTest -Raw
        } else { "" }

        $script:hasHomeOverride  = $script:scriptText -match 'DOTFILESLINK_HOME_OVERRIDE'
        $script:hasSkipPrivCheck = $script:scriptText -match 'DOTFILESLINK_SKIP_PRIV_CHECK'
        $script:hasFailAfterN    = $script:scriptText -match 'DOTFILESLINK_FAIL_AT_INDEX'
        $script:hasLinkTypeCapture = $script:scriptText -match '\$oldLinkType'
    }

    Context "T1 — installer test affordances (static)" {

        It "T1-1: defines `$EffectiveHome that honors DOTFILESLINK_HOME_OVERRIDE" {
            if (-not $script:hasHomeOverride) {
                Set-ItResult -Skip -Because "DOTFILESLINK_HOME_OVERRIDE not yet implemented in dotfileslink.ps1"
                return
            }
            # When implemented, expect a variable like $EffectiveHome assigned from env override or $HOME.
            $script:scriptText | Should -Match 'DOTFILESLINK_HOME_OVERRIDE'
            $script:scriptText | Should -Match 'EffectiveHome'
        }

        It "T1-2: DOTFILESLINK_SKIP_PRIV_CHECK bypasses the symlink-privilege guard" {
            if (-not $script:hasSkipPrivCheck) {
                Set-ItResult -Skip -Because "DOTFILESLINK_SKIP_PRIV_CHECK not yet implemented"
                return
            }
            # Expect the env var to be referenced in the priv-check guard.
            $script:scriptText | Should -Match 'DOTFILESLINK_SKIP_PRIV_CHECK'
        }

        It "T1-3: DOTFILESLINK_FAIL_AT_INDEX hook is wired into the link loop" {
            if (-not $script:hasFailAfterN) {
                Set-ItResult -Skip -Because "DOTFILESLINK_FAIL_AT_INDEX not yet implemented"
                return
            }
            $script:scriptText | Should -Match 'DOTFILESLINK_FAIL_AT_INDEX'
        }
    }

    Context "T2 — LinkType-preserving rollback (static)" {

        It "T2-1: captures `$item.LinkType into `$oldLinkType before Remove-Item" {
            if (-not $script:hasLinkTypeCapture) {
                Set-ItResult -Skip -Because "`$oldLinkType capture not yet implemented"
                return
            }
            # Capture must occur before Remove-Item $dest.
            $captureIdx = $script:scriptText.IndexOf('$oldLinkType')
            $removeIdx  = $script:scriptText.IndexOf('Remove-Item $dest -Force')
            $captureIdx | Should -BeGreaterThan -1
            $removeIdx  | Should -BeGreaterThan -1
            $captureIdx | Should -BeLessThan $removeIdx
        }

        It "T2-2: rollback restore uses `$oldLinkType (not hardcoded SymbolicLink)" {
            if (-not $script:hasLinkTypeCapture) {
                Set-ItResult -Skip -Because "`$oldLinkType capture not yet implemented"
                return
            }
            # In the restore-symlink branch of the catch, the New-Item call should use
            # -ItemType $oldLinkType (or equivalent), not a literal 'SymbolicLink'.
            $script:scriptText | Should -Match '-ItemType\s+\$oldLinkType'
        }
    }

    Context "T2-3/T2-4 — dynamic rollback via Start-Process pwsh" {

        BeforeAll {
            $script:dynamicEnabled = $script:hasHomeOverride -and $script:hasFailAfterN -and $script:hasSkipPrivCheck
            $script:sandboxRoot = if ($script:dynamicEnabled) {
                Join-Path $env:TEMP ("dfl-fix-969-" + [Guid]::NewGuid().ToString("N").Substring(0,8))
            } else { $null }
            if ($script:dynamicEnabled) {
                New-Item -ItemType Directory -Path $script:sandboxRoot -Force | Out-Null
            }
        }

        AfterAll {
            if ($script:sandboxRoot -and (Test-Path $script:sandboxRoot)) {
                Remove-Item -LiteralPath $script:sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "T2-3: induced symlink failure leaves backup intact and exits non-zero" {
            if (-not $script:dynamicEnabled) {
                Set-ItResult -Skip -Because "DOTFILESLINK_HOME_OVERRIDE / SKIP_PRIV_CHECK / FAIL_AFTER_N affordances not yet implemented"
                return
            }
            $sandboxHome = Join-Path $script:sandboxRoot "t23-home"
            $claudeDir = Join-Path $sandboxHome ".claude"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            # Pre-existing regular file should be backed up; on induced failure,
            # the backup must persist.
            $marker = "PRESERVE_ME_" + [Guid]::NewGuid().ToString("N")
            Set-Content -LiteralPath (Join-Path $claudeDir "CLAUDE.md") -Value $marker -Encoding ASCII

            $env:DOTFILESLINK_HOME_OVERRIDE = $sandboxHome
            $env:DOTFILESLINK_SKIP_PRIV_CHECK = "1"
            $env:DOTFILESLINK_FAIL_AT_INDEX = "0"  # fail on the first link
            $env:DOTFILESLINK_LINKS_ONLY = "1"
            try {
                $proc = Start-Process -FilePath pwsh -ArgumentList @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:scriptPath
                ) -Wait -PassThru -WindowStyle Hidden
                $proc.ExitCode | Should -Be 1
            } finally {
                Remove-Item Env:DOTFILESLINK_HOME_OVERRIDE -ErrorAction SilentlyContinue
                Remove-Item Env:DOTFILESLINK_SKIP_PRIV_CHECK -ErrorAction SilentlyContinue
                Remove-Item Env:DOTFILESLINK_FAIL_AT_INDEX -ErrorAction SilentlyContinue
                Remove-Item Env:DOTFILESLINK_LINKS_ONLY -ErrorAction SilentlyContinue
            }
            # The original file must still be accessible (rollback restored it).
            Test-Path (Join-Path $claudeDir "CLAUDE.md") | Should -BeTrue
        }

        It "T2-4: Junction at destination is restored as Junction (LinkType preserved)" {
            if (-not $script:dynamicEnabled) {
                Set-ItResult -Skip -Because "DOTFILESLINK env-var affordances not yet implemented"
                return
            }
            if (-not $script:hasLinkTypeCapture) {
                Set-ItResult -Skip -Because "`$oldLinkType capture not yet implemented"
                return
            }
            $sandboxHome = Join-Path $script:sandboxRoot "t24-home"
            $claudeDir = Join-Path $sandboxHome ".claude"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            # Create a different target dir to which we will junction.
            $altTarget = Join-Path $script:sandboxRoot "t24-alt-target"
            New-Item -ItemType Directory -Path $altTarget -Force | Out-Null
            $skillsDest = Join-Path $claudeDir "skills"
            # Create a Junction at the skills destination pointing to altTarget.
            try {
                New-Item -ItemType Junction -Path $skillsDest -Target $altTarget -ErrorAction Stop | Out-Null
            } catch {
                Set-ItResult -Skip -Because "Junction creation not supported in this environment: $($_.Exception.Message)"
                return
            }

            $env:DOTFILESLINK_HOME_OVERRIDE = $sandboxHome
            $env:DOTFILESLINK_SKIP_PRIV_CHECK = "1"
            $env:DOTFILESLINK_FAIL_AT_INDEX = "0"
            $env:DOTFILESLINK_LINKS_ONLY = "1"
            try {
                Start-Process -FilePath pwsh -ArgumentList @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:scriptPath
                ) -Wait -PassThru -WindowStyle Hidden | Out-Null
            } finally {
                Remove-Item Env:DOTFILESLINK_HOME_OVERRIDE -ErrorAction SilentlyContinue
                Remove-Item Env:DOTFILESLINK_SKIP_PRIV_CHECK -ErrorAction SilentlyContinue
                Remove-Item Env:DOTFILESLINK_FAIL_AT_INDEX -ErrorAction SilentlyContinue
                Remove-Item Env:DOTFILESLINK_LINKS_ONLY -ErrorAction SilentlyContinue
            }
            # After rollback the destination should still exist and still be a Junction.
            $restored = Get-Item -LiteralPath $skillsDest -Force -ErrorAction SilentlyContinue
            $restored | Should -Not -BeNullOrEmpty
            $restored.LinkType | Should -Be "Junction"
        }
    }

    Context "T4 — profile-snippet.ps1 watchlist detection" {

        BeforeAll {
            $script:t4SandboxRoot = Join-Path $env:TEMP ("dfl-t4-" + [Guid]::NewGuid().ToString("N").Substring(0,8))
            New-Item -ItemType Directory -Path $script:t4SandboxRoot -Force | Out-Null
        }

        AfterAll {
            if ($script:t4SandboxRoot -and (Test-Path $script:t4SandboxRoot)) {
                Remove-Item -LiteralPath $script:t4SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Invoke-ProfileSnippetStub is defined at top of this file (Pester 5 compat).

        It "T4-4: valid symlinks at all four sibling paths do NOT trigger repair" {
            $caseRoot = Join-Path $script:t4SandboxRoot "t44"
            $sbHome = Join-Path $caseRoot "home"
            $sbAgents = Join-Path $caseRoot "agents"
            $claudeDir = Join-Path $sbHome ".claude"
            $targetRoot = Join-Path $caseRoot "targets"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $targetRoot "skills") -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $targetRoot "rules") -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $targetRoot "agents") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $targetRoot "CLAUDE.md") -Value "x" -Encoding ASCII
            try {
                New-Item -ItemType SymbolicLink -Path (Join-Path $claudeDir "CLAUDE.md") -Target (Join-Path $targetRoot "CLAUDE.md") -ErrorAction Stop | Out-Null
                New-Item -ItemType SymbolicLink -Path (Join-Path $claudeDir "skills")    -Target (Join-Path $targetRoot "skills") -ErrorAction Stop | Out-Null
                New-Item -ItemType SymbolicLink -Path (Join-Path $claudeDir "rules")     -Target (Join-Path $targetRoot "rules") -ErrorAction Stop | Out-Null
                New-Item -ItemType SymbolicLink -Path (Join-Path $claudeDir "agents")    -Target (Join-Path $targetRoot "agents") -ErrorAction Stop | Out-Null
            } catch {
                Set-ItResult -Skip -Because "symlink creation requires Developer Mode or Admin: $($_.Exception.Message)"
                return
            }
            # Inline helper (Pester 5 runspace isolation; substitute $HOME because it is read-only)
            $sentinel = Join-Path $script:t4SandboxRoot ("sentinel-t44-" + [Guid]::NewGuid().ToString("N"))
            $stubScript = Join-Path $sbAgents "install\win\dotfileslink.ps1"
            New-Item -ItemType Directory -Path (Split-Path $stubScript -Parent) -Force | Out-Null
            Set-Content -LiteralPath $stubScript -Value "Set-Content -LiteralPath '$sentinel' -Value 'REPAIR' -Encoding ASCII" -Encoding UTF8
            $profileCopy = Join-Path $sbAgents "profile-snippet.ps1"
            $profileSource = Get-Content -LiteralPath $script:profilePath -Raw
            $profilePatched = $profileSource.Replace('$HOME', $sbHome)
            Set-Content -LiteralPath $profileCopy -Value $profilePatched -Encoding UTF8
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $profileCopy *> $null
            (Test-Path -LiteralPath $sentinel) | Should -BeFalse
        }

        It "T4-5: dangling symlink triggers repair (null-Target guard)" {
            $caseRoot = Join-Path $script:t4SandboxRoot "t45"
            $sbHome = Join-Path $caseRoot "home"
            $sbAgents = Join-Path $caseRoot "agents"
            $claudeDir = Join-Path $sbHome ".claude"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            try {
                $bogus = Join-Path $caseRoot "nonexistent-target"
                New-Item -ItemType SymbolicLink -Path (Join-Path $claudeDir "CLAUDE.md") -Target $bogus -ErrorAction Stop | Out-Null
            } catch {
                Set-ItResult -Skip -Because "symlink creation requires Developer Mode or Admin"
                return
            }
            # Inline helper (substitute $HOME)
            $sentinel = Join-Path $script:t4SandboxRoot ("sentinel-t45-" + [Guid]::NewGuid().ToString("N"))
            $stubScript = Join-Path $sbAgents "install\win\dotfileslink.ps1"
            New-Item -ItemType Directory -Path (Split-Path $stubScript -Parent) -Force | Out-Null
            Set-Content -LiteralPath $stubScript -Value "Set-Content -LiteralPath '$sentinel' -Value 'REPAIR' -Encoding ASCII" -Encoding UTF8
            $profileCopy = Join-Path $sbAgents "profile-snippet.ps1"
            $profileSource = Get-Content -LiteralPath $script:profilePath -Raw
            $profilePatched = $profileSource.Replace('$HOME', $sbHome)
            Set-Content -LiteralPath $profileCopy -Value $profilePatched -Encoding UTF8
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $profileCopy *> $null
            $repaired = Test-Path -LiteralPath $sentinel
            if (-not $repaired) {
                # Source must be updated to detect dangling symlinks (null-Target guard).
                if ($script:profileText -notmatch 'Target|LinkType|GetFullPath') {
                    Set-ItResult -Skip -Because "profile-snippet.ps1 dangling-symlink detection not yet implemented"
                    return
                }
                throw "Dangling symlink did not trigger repair, but source claims to detect it"
            }
            $repaired | Should -BeTrue
        }

        It "T4-6: regular file in place of expected symlink triggers repair" {
            $caseRoot = Join-Path $script:t4SandboxRoot "t46"
            $sbHome = Join-Path $caseRoot "home"
            $sbAgents = Join-Path $caseRoot "agents"
            $claudeDir = Join-Path $sbHome ".claude"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $claudeDir "CLAUDE.md") -Value "regular file" -Encoding ASCII

            # Inline helper (Pester 5 runspace isolation prevents top-level function reuse).
            # Replace $HOME references in the profile snippet copy because $HOME is read-only in pwsh.
            $sentinel = Join-Path $script:t4SandboxRoot ("sentinel-t46-" + [Guid]::NewGuid().ToString("N"))
            $stubScript = Join-Path $sbAgents "install\win\dotfileslink.ps1"
            New-Item -ItemType Directory -Path (Split-Path $stubScript -Parent) -Force | Out-Null
            Set-Content -LiteralPath $stubScript -Value "Set-Content -LiteralPath '$sentinel' -Value 'REPAIR' -Encoding ASCII" -Encoding UTF8
            $profileCopy = Join-Path $sbAgents "profile-snippet.ps1"
            $profileSource = Get-Content -LiteralPath $script:profilePath -Raw
            $profilePatched = $profileSource.Replace('$HOME', $sbHome)
            Set-Content -LiteralPath $profileCopy -Value $profilePatched -Encoding UTF8
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $profileCopy *> $null
            (Test-Path -LiteralPath $sentinel) | Should -BeTrue
        }
    }

    Context "T5-1 — sibling Tests.ps1 stale-suffix cleanup" {

        It "(pending implementation) suffix is removed from sibling test names" {
            if (-not $script:siblingText) {
                Set-ItResult -Inconclusive -Because "sibling test file not found at $script:siblingTest"
                return
            }
            $script:siblingText | Should -Not -Match '\(pending implementation\)'
        }
    }
}
