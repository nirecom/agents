# Tests: install/win/session-sync-init.ps1
# Tags: install, git, pwsh-required, security, installer, scope:issue-specific
# Symmetric counterpart of tests/main-session-sync/security-provenance.sh and
# security-migration.sh (CPR-ORTH): who may migrate, and what the tree looks
# like afterwards. Shared fixtures: tests/lib/session-sync-security-common.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot "..\lib\session-sync-security-common.ps1")
}

AfterAll {
    Complete-SyncSecuritySuite
}

Describe "session-sync-init.ps1 migration provenance" {
    # detail.md A1: a pre-existing $ClaudeDir\.git may be migrated only when an
    # expected origin exists AND the old origin matches it. Expected origin is
    # -ExpectedOrigin > the validated -RemoteUrl > absent, and absent is
    # fail-closed: an unidentified repo under the claude dir may be the user's
    # own unrelated work, which migration would destroy.

    BeforeAll {
        # Declared in BeforeAll, not in the Describe body: the body runs at
        # discovery time, so a function declared there is gone by the time an It
        # executes.
        function New-ProvenanceFixture {
            param([Parameter(Mandatory)][string]$Tag, [string]$Origin = "")
            $script:PvDir = New-OldRoot (Join-Path $script:SuiteHome "$Tag-$(Get-Random)") $Origin
            $script:PvHead = Get-RepoHead $script:PvDir
            $script:PvSnapshot = Get-TrackedSnapshot $script:PvDir
            $script:PvStatus = Get-WorktreeStatus $script:PvDir
            return $script:PvDir
        }

        # Assert-PvUntouched — the full non-change proof every refusing row owes.
        # HEAD alone cannot see an uncommitted overwrite of the working tree, so
        # the tracked bytes, a clean status, both seed files and the absence of
        # any staging artifact are what carry "untouched".
        function Assert-PvUntouched {
            Test-Path (Join-Path $script:PvDir "projects") | Should -BeFalse -Because "the verdict precedes the first write"
            $script:PvStatus | Should -BeNullOrEmpty -Because "the fixture must be clean before the run"
            Get-RepoHead $script:PvDir | Should -Be $script:PvHead
            Get-TrackedSnapshot $script:PvDir | Should -Be $script:PvSnapshot -Because "a rejected run must not rewrite content HEAD cannot see"
            Get-WorktreeStatus $script:PvDir | Should -BeNullOrEmpty -Because "a rejected run must leave no modified, staged or untracked residue"
            (Get-Content (Join-Path $script:PvDir ".gitignore") -Raw) | Should -Be "old-gitignore"
            (Get-Content (Join-Path $script:PvDir ".gitattributes") -Raw) | Should -Be "old-gitattributes"
            (Get-Content (Join-Path $script:PvDir "old-session.jsonl") -Raw) | Should -Be "old-session"
            Get-StagingResidue $script:PvDir | Should -BeNullOrEmpty -Because "no staging name may survive anywhere under the claude dir"
        }
    }

    It "refuses when no expected origin is available" {
        $claudeDir = New-ProvenanceFixture "pv1" $script:OriginL
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true }
        $rc | Should -Not -Be 0
        Assert-PvUntouched
    }

    It "refuses when the old origin cannot be read" {
        $claudeDir = New-ProvenanceFixture "pv2"
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL }
        $rc | Should -Not -Be 0
        Assert-PvUntouched
    }

    It "refuses when -ExpectedOrigin does not match the old origin" {
        $claudeDir = New-ProvenanceFixture "pv3" $script:OriginL
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginM }
        $rc | Should -Not -Be 0
        Assert-PvUntouched
    }

    It "migrates when -ExpectedOrigin matches the old origin" {
        # The only accepting row, and the other direction of the classifier
        # (protection-fix-tests.md Pattern 4).
        $claudeDir = New-OldRoot (Join-Path $script:SuiteHome "pv4-$(Get-Random)") $script:OriginL
        $head = Get-RepoHead $claudeDir
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL }
        $rc | Should -Be 0
        Get-RepoHead (Join-Path $claudeDir "projects") | Should -Be $head -Because "the destination repo must be the migrated one"
        Get-GitResidue $claudeDir | Should -BeNullOrEmpty -Because "no git metadata may stay behind under any name"
    }

    It "adopts the resolved remote URL as the expected origin" {
        # Precedence rule 2: remote mode supplies the expectation implicitly.
        $claudeDir = New-OldRoot (Join-Path $script:SuiteHome "pv5-$(Get-Random)") "git@example.com:repo.git"
        $head = Get-RepoHead $claudeDir
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; RemoteUrl = "git@example.com:repo.git" }
        $rc | Should -Be 0
        Get-RepoHead (Join-Path $claudeDir "projects") | Should -Be $head
    }

    It "lets -ExpectedOrigin outrank the resolved remote URL" {
        $claudeDir = New-OldRoot (Join-Path $script:SuiteHome "pv6-$(Get-Random)") $script:OriginM
        $head = Get-RepoHead $claudeDir
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; RemoteUrl = "git@example.com:repo.git"; ExpectedOrigin = $script:OriginM }
        $rc | Should -Be 0 -Because "the explicit expectation is the one that counts"
        Get-RepoHead (Join-Path $claudeDir "projects") | Should -Be $head
    }

    It "refuses a repo that matches only the remote URL" {
        # The inverse of the row above. Without it, an implementation that OR-ed
        # the two candidate expectations would pass unnoticed.
        $claudeDir = New-ProvenanceFixture "pv7" "git@example.com:repo.git"
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; RemoteUrl = "git@example.com:repo.git"; ExpectedOrigin = $script:OriginM }
        $rc | Should -Not -Be 0
        Assert-PvUntouched
    }

    It "leaves a fresh install alone" {
        # No old git root means no provenance evaluation at all; the fail-closed
        # rule must not leak onto first-time installs.
        $claudeDir = New-ClaudeDir "pv-fresh"
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true }
        $rc | Should -Be 0
        Test-Path (Join-Path $claudeDir "projects\.git") | Should -BeTrue
    }
}

Describe "session-sync-init.ps1 migration end state" {
    # detail.md D: the terminal states are "everything moved under its bare final
    # name in projects\" or "the claude dir exactly as it was". A .bak state
    # exists at neither end — the pre-#1773 tests asserted one and were wrong.

    It "moves the repo under bare final names" {
        $claudeDir = New-OldRoot (Join-Path $script:SuiteHome "end1-$(Get-Random)") $script:OriginL
        $head = Get-RepoHead $claudeDir
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL }
        $rc | Should -Be 0
        $projects = Join-Path $claudeDir "projects"
        Get-RepoHead $projects | Should -Be $head
        Test-Path (Join-Path $projects ".gitignore") | Should -BeTrue
        Test-Path (Join-Path $projects ".gitattributes") | Should -BeTrue
        # Restore-MissingTracked runs against the OLD root as work-tree and is
        # scoped to the `projects` pathspec, so a root-level tracked file stays
        # exactly where it is. A copy appearing under projects\ is the
        # re-scattering bug an unscoped or wrongly-rooted restore produces.
        Test-Path (Join-Path $claudeDir "old-session.jsonl") | Should -BeTrue -Because "a root-level tracked file must not be destroyed"
        Test-Path (Join-Path $projects "old-session.jsonl") | Should -BeFalse -Because "only files under projects\ belong at the new root"
        Get-GitResidue $claudeDir | Should -BeNullOrEmpty
        Get-StagingResidue $projects | Should -BeNullOrEmpty
    }

    It "restores files under projects\ without re-scattering the old root" {
        # The legacy layout the migration actually targets: projects\<enc>\*.jsonl
        # session data plus a couple of root-level files.
        $claudeDir = Join-Path $script:SuiteHome "end1b-$(Get-Random)"
        $projects = Join-Path $claudeDir "projects"
        New-Item -ItemType Directory -Path (Join-Path $projects "enc-proj") -Force | Out-Null
        git init $claudeDir 2>&1 | Out-Null
        git -C $claudeDir config core.hooksPath /dev/null 2>&1 | Out-Null
        git -C $claudeDir remote add origin $script:OriginL 2>&1 | Out-Null
        Set-Content -Path (Join-Path $claudeDir ".gitignore") -Value "old-gitignore" -NoNewline
        Set-Content -Path (Join-Path $claudeDir "root-level.jsonl") -Value "root-level" -NoNewline
        Set-Content -Path (Join-Path $projects "enc-proj\session.jsonl") -Value "session-payload" -NoNewline
        git -C $claudeDir add -A 2>&1 | Out-Null
        git -C $claudeDir commit -q -m "legacy layout" 2>&1 | Out-Null

        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL }

        $rc | Should -Be 0
        (Get-Content (Join-Path $projects "enc-proj\session.jsonl") -Raw) | Should -Be "session-payload"
        Test-Path (Join-Path $projects "projects") | Should -BeFalse -Because "the restore must not recreate projects\ one level too deep"
        Test-Path (Join-Path $projects "root-level.jsonl") | Should -BeFalse -Because "a root-level tracked file must not be re-scattered"
        Test-Path (Join-Path $claudeDir "root-level.jsonl") | Should -BeTrue
    }

    It "normalizes the seed files after moving them" {
        # The installer rewrites .gitattributes/.gitignore after migrating, so
        # asserting the old content would contradict the normalization block the
        # design leaves unchanged; the canonical content is what must be there.
        $claudeDir = New-OldRoot (Join-Path $script:SuiteHome "end2-$(Get-Random)") $script:OriginL
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL }
        $rc | Should -Be 0
        (Get-Content (Join-Path $claudeDir "projects\.gitattributes") -Raw) | Should -Match 'merge=union'
    }

    BeforeAll {
        # New-CollidingDestination — a destination repo holding all three names,
        # with the given origin (none when omitted). Shared by the two rows below
        # so the only difference between them is the fact under test (CPR-SSOT).
        function New-CollidingDestination {
            param([Parameter(Mandatory)][string]$ClaudeDir, [string]$Origin = "")
            $projects = Join-Path $ClaudeDir "projects"
            New-Item -ItemType Directory -Path $projects -Force | Out-Null
            git init $projects 2>&1 | Out-Null
            git -C $projects config core.hooksPath /dev/null 2>&1 | Out-Null
            git -C $projects config user.email "session-sync-test@example.com" 2>&1 | Out-Null
            git -C $projects config user.name "Session Sync Test" 2>&1 | Out-Null
            if ($Origin) { git -C $projects remote add origin $Origin 2>&1 | Out-Null }
            Set-Content -Path (Join-Path $projects "incumbent.txt") -Value "incumbent" -NoNewline
            Set-Content -Path (Join-Path $projects ".gitignore") -Value "incumbent-ignore" -NoNewline
            Set-Content -Path (Join-Path $projects ".gitattributes") -Value "incumbent-attrs" -NoNewline
            git -C $projects add -A 2>&1 | Out-Null
            git -C $projects commit -q -m "incumbent repo" 2>&1 | Out-Null
            return $projects
        }
    }

    It "refuses a destination repo that has no origin to identify it" {
        # The destination loses its own .git to this migration, so a matching
        # origin is the only accepted proof. An origin-less repo is not "nothing
        # contradicting us": it is the user's own unpublished work.
        $claudeDir = New-OldRoot (Join-Path $script:SuiteHome "end3-$(Get-Random)") $script:OriginL
        $incomingHead = Get-RepoHead $claudeDir
        $projects = New-CollidingDestination $claudeDir
        $incumbentHead = Get-RepoHead $projects
        $incumbentSnapshot = Get-TrackedSnapshot $projects

        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL }

        $rc | Should -Not -Be 0 -Because "an unidentified destination repo must not be consumed"
        Get-RepoHead $projects | Should -Be $incumbentHead -Because "the incumbent repo must survive a refused run"
        Get-TrackedSnapshot $projects | Should -Be $incumbentSnapshot
        Get-RepoHead $claudeDir | Should -Be $incomingHead -Because "the old repo must be left as it was"
        Get-StagingResidue $projects | Should -BeNullOrEmpty
        Get-StagingResidue $claudeDir | Should -BeNullOrEmpty
    }

    It "promotes over a destination that already holds all three names" {
        # The other direction: once the destination's origin identifies it as the
        # same session-sync repo, Phase 1a stages the incumbents aside, Phase 2
        # promotes the incoming copies, Phase 3 removes the staged incumbents.
        $claudeDir = New-OldRoot (Join-Path $script:SuiteHome "end3b-$(Get-Random)") $script:OriginL
        $incomingHead = Get-RepoHead $claudeDir
        $projects = New-CollidingDestination $claudeDir $script:OriginL
        $incumbentHead = Get-RepoHead $projects

        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL }

        $rc | Should -Be 0
        Get-RepoHead $projects | Should -Not -Be $incumbentHead -Because "the incumbent repo must be replaced, not kept"
        Get-RepoHead $projects | Should -Be $incomingHead
        Get-StagingResidue $projects | Should -BeNullOrEmpty -Because "Phase 3 deletes the staged incumbents"
        Get-GitResidue $claudeDir | Should -BeNullOrEmpty
    }

    It "is idempotent on a second run" {
        # rules/test/installer.md: re-running must neither fail nor resurrect the
        # old layout.
        $claudeDir = New-OldRoot (Join-Path $script:SuiteHome "end4-$(Get-Random)") $script:OriginL
        $head = Get-RepoHead $claudeDir
        Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL } | Should -Be 0
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true; ExpectedOrigin = $script:OriginL }
        $rc | Should -Be 0
        Get-RepoHead (Join-Path $claudeDir "projects") | Should -Be $head
        Test-Path (Join-Path $claudeDir ".git") | Should -BeFalse
    }
}
