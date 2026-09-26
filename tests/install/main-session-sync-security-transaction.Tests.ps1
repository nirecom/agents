# Tests: install/win/session-sync-init.ps1
# Tags: install, git, pwsh-required, security, installer, scope:issue-specific
# Symmetric counterpart of tests/main-session-sync/security-transaction.sh.
# The staging names embed the installer's own $PID, which no outside observer
# can predict, so these cases lift the two transaction functions out of the
# installer with the PowerShell AST and run them in this process: staging paths
# become addressable and a failure can be injected at an exact rename.

BeforeAll {
    . (Join-Path $PSScriptRoot "..\lib\session-sync-security-common.ps1")
    . (Join-Path $PSScriptRoot "..\lib\session-sync-transaction-common.ps1")
}

AfterAll {
    Complete-SyncSecuritySuite
}

# TL3 gap (skills/_shared/test-design.md): TL2 — the two functions are lifted out
# of the shipped script and driven here, so the installer's own wiring is assumed
# rather than run. Not covered: that the installer calls the migration on the real
# pre-migration layout and honors its result; that the live process's $PID yields
# the staging names Phase 0 scans for; and the real filesystem failures behind the
# injected ones — an NTFS/SMB sharing violation on an open `.git`, a virus scanner
# holding a handle, a case-insensitive volume treating `.GIT` as occupied, and a
# crash between Phase 1b and Phase 2 leaving staging names for the next run.
# Mitigation: checked at WORKFLOW_USER_VERIFIED preflight, category installer.

Describe "session-sync-init.ps1 Move-NoClobber" {
    # detail.md D: success is the post-condition "From gone AND To present",
    # never the absence of an exception. PowerShell has two rename verbs and the
    # transaction uses both — Rename-Item within a directory (Phase 1a, Phase 2)
    # and Move-Item across directories (Phase 1b) — so each case below is run
    # against both paths (CPR-ORTH).

    It "renames onto a free destination in the same directory" {
        Assert-TxReady
        $d = New-PairDir "same-ok"
        Set-Content -Path (Join-Path $d "from") -Value "payload" -NoNewline
        Invoke-TxRename (Join-Path $d "from") (Join-Path $d "to") | Should -BeTrue
        Test-Path (Join-Path $d "from") | Should -BeFalse
        (Get-Content (Join-Path $d "to") -Raw) | Should -Be "payload"
    }

    It "renames onto a free destination across directories" {
        Assert-TxReady
        $d = New-PairDir "cross-ok"
        New-Item -ItemType Directory -Path (Join-Path $d "sub") -Force | Out-Null
        Set-Content -Path (Join-Path $d "from") -Value "payload" -NoNewline
        Invoke-TxRename (Join-Path $d "from") (Join-Path $d "sub\to") | Should -BeTrue
        Test-Path (Join-Path $d "from") | Should -BeFalse
        (Get-Content (Join-Path $d "sub\to") -Raw) | Should -Be "payload"
    }

    It "refuses an occupied destination in the same directory" {
        # The caller may only add a name to its rollback list once the rename is
        # confirmed, so a refusal must leave both sides exactly as they were.
        Assert-TxReady
        $d = New-PairDir "same-busy"
        Set-Content -Path (Join-Path $d "from") -Value "payload" -NoNewline
        Set-Content -Path (Join-Path $d "to") -Value "incumbent" -NoNewline
        Invoke-TxRename (Join-Path $d "from") (Join-Path $d "to") | Should -BeFalse
        (Get-Content (Join-Path $d "from") -Raw) | Should -Be "payload" -Because "the source must not be consumed"
        (Get-Content (Join-Path $d "to") -Raw) | Should -Be "incumbent" -Because "the incumbent must not be clobbered"
    }

    It "refuses an occupied destination across directories" {
        Assert-TxReady
        $d = New-PairDir "cross-busy"
        New-Item -ItemType Directory -Path (Join-Path $d "sub") -Force | Out-Null
        Set-Content -Path (Join-Path $d "from") -Value "payload" -NoNewline
        Set-Content -Path (Join-Path $d "sub\to") -Value "incumbent" -NoNewline
        Invoke-TxRename (Join-Path $d "from") (Join-Path $d "sub\to") | Should -BeFalse
        (Get-Content (Join-Path $d "from") -Raw) | Should -Be "payload"
        (Get-Content (Join-Path $d "sub\to") -Raw) | Should -Be "incumbent"
    }

    It "reports failure when the rename silently does nothing" {
        # The .NET counterpart of GNU `mv -n` exiting 0 on a skip: -ErrorAction
        # SilentlyContinue, a provider that declines, or a same-name no-op all
        # return without throwing. The destination here is deliberately FREE, so
        # the pre-existence check cannot be what returns false — only the
        # post-condition can. Both verbs are shadowed because the implementation
        # is free to pick either for a given pair.
        Assert-TxReady
        $d = New-PairDir "noop"
        Set-Content -Path (Join-Path $d "from") -Value "payload" -NoNewline
        function global:Rename-Item { param([Parameter(ValueFromRemainingArguments)]$Rest) }
        function global:Move-Item { param([Parameter(ValueFromRemainingArguments)]$Rest) }
        try {
            $result = Invoke-TxRename (Join-Path $d "from") (Join-Path $d "to")
        } finally {
            Remove-Item function:global:Rename-Item -ErrorAction SilentlyContinue
            Remove-Item function:global:Move-Item -ErrorAction SilentlyContinue
        }
        $result | Should -BeFalse -Because "an exception-free no-op is not a success"
        (Get-Content (Join-Path $d "from") -Raw) | Should -Be "payload"
    }
}

Describe "session-sync-init.ps1 migration transaction" {
    It "aborts on a stale staging path before anything moves" {
        # A leftover staging name means a crashed run, a recycled PID, or a
        # concurrent installer. Fail-closed: abort, change nothing, and leave the
        # stale file in place — deleting it destroys the user's evidence.
        Assert-TxReady
        $fx = New-TxFixture "stale"
        $stale = Join-Path $fx.Dst ".gitignore.old.$PID"
        Set-Content -Path $stale -Value "stale" -NoNewline
        $srcBefore = Get-TxState $fx.Src
        $dstBefore = Get-TxState $fx.Dst

        $ok = [bool](& $script:MigrateFn $fx.Src $fx.Dst)

        $ok | Should -BeFalse -Because "a stale staging path must abort Phase 0"
        Get-TxState $fx.Src | Should -Be $srcBefore
        Get-TxState $fx.Dst | Should -Be $dstBefore
        Test-Path $stale | Should -BeTrue -Because "the stale path is reported, not tidied away"
    }

    It "restores both trees when a Phase 1a rename fails" {
        # The phase the other two cases cannot reach: Phase 1a stages DST's own
        # incumbents, so its rollback must undo moves made inside the destination
        # before Phase 1b has touched SRC at all.
        Assert-TxReady
        Invoke-RollbackCase -Tag "phase1a" -FailAt 2
    }

    It "restores both trees when a Phase 1b rename fails" {
        Assert-TxReady
        Invoke-RollbackCase -Tag "phase1b" -FailAt 5
    }

    It "restores both trees when a Phase 2 rename fails" {
        Assert-TxReady
        Invoke-RollbackCase -Tag "phase2" -FailAt 8
    }

    It "restores both trees when Phase 1a raises a terminating error" {
        # Windows produces its failures as exceptions, not return values: a
        # sharing violation on an open `.git` throws, and under the installer's
        # "Stop" preference it unwinds the whole call. The rollback must run
        # anyway, which only a `finally`/`trap` structure achieves.
        Assert-TxReady
        Invoke-VerbFaultCase -Tag "throw1a" -FailAt 1
    }

    It "restores both trees when Phase 1b raises a terminating error" {
        Assert-TxReady
        Invoke-VerbFaultCase -Tag "throw1b" -FailAt 5
    }

    It "keeps the success verdict when Phase 3 cleanup fails" {
        # detail.md D: deleting the staged `.old.$PID` incumbents is best-effort —
        # the data is migrated by then, so an undeletable leftover is litter, not
        # a failed migration. Reporting failure here is the worse bug: the caller
        # would roll back or re-run over a tree that is already correct. The stub
        # refuses only `.old.` paths, so nothing else in the run is affected.
        Assert-TxReady
        $fx = New-TxFixture "phase3"
        function global:Remove-Item {
            foreach ($a in $args) {
                if ("$a" -like "*.old.*") { throw "injected cleanup failure" }
            }
            Microsoft.PowerShell.Management\Remove-Item @args
        }
        $ok = $false
        try {
            try { $ok = [bool](& $script:MigrateFn $fx.Src $fx.Dst) } catch { $ok = $false }
        } finally {
            Microsoft.PowerShell.Management\Remove-Item function:global:Remove-Item -ErrorAction SilentlyContinue
        }
        $ok | Should -BeTrue -Because "a best-effort cleanup failure must not change the verdict"
        Get-TxState $fx.Dst | Should -Be ".git\marker=src-git;.gitignore=src-ignore;.gitattributes=src-attrs;"
        @(Get-StagingResidue $fx.Dst | Where-Object { $_ -notmatch '\.old\.' }) | Should -BeNullOrEmpty -Because "only the undeletable incumbents may remain"
        @(Get-StagingResidue $fx.Dst) | Should -Not -BeNullOrEmpty -Because "the stub must actually have blocked a delete"
    }

    It "leaves only bare final names on the success path" {
        # The complement of the rollback cases (Pattern 4): with no injection the
        # three names end up in DST carrying SRC's content, SRC keeps none of
        # them, and the staged incumbents are gone.
        Assert-TxReady
        $fx = New-TxFixture "success"
        $ok = [bool](& $script:MigrateFn $fx.Src $fx.Dst)
        $ok | Should -BeTrue
        Get-TxState $fx.Dst | Should -Be ".git\marker=src-git;.gitignore=src-ignore;.gitattributes=src-attrs;"
        Get-GitResidue $fx.Src | Should -BeNullOrEmpty -Because "SRC keeps none of the three names"
        Get-StagingResidue $fx.Dst | Should -BeNullOrEmpty
        Get-StagingResidue $fx.Src | Should -BeNullOrEmpty
    }
}
