# Tests: install/win/session-sync-init.ps1
# Tags: install, git, pwsh-required, security, installer, scope:common
# Symmetric counterpart of tests/main-session-sync/security.sh (CPR-ORTH): the
# remote-URL allowlist and the two path boundaries; migration end state and
# transaction internals live in the -migration / -transaction siblings.

# TL3 gap (skills/_shared/test-design.md): TL2 — fixtures only, with
# $env:USERPROFILE relocated under $env:TEMP; a redirected OneDrive or roaming
# profile defeating Resolve-RealPath is out of reach. Mitigation: checked at
# WORKFLOW_USER_VERIFIED preflight, category installer.

# Pester binds -ForEach data at discovery time, so the fixtures are parsed here.
$UrlCases = @(
    Get-Content (Join-Path $PSScriptRoot "..\fixtures\session-sync-remote-url-table.txt") |
        Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
        ForEach-Object {
            $parts = $_ -split "`t"
            @{ Kind = $parts[0].Trim(); Url = $parts[1] }
        }
)

$PatternRows = @{}
Get-Content (Join-Path $PSScriptRoot "..\fixtures\session-sync-remote-url-patterns.txt") |
    Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
    ForEach-Object {
        $parts = $_ -split "`t"
        $PatternRows[$parts[0].Trim()] = $parts[1]
    }

# One case per table row, each carrying the canonical patterns, so the .NET
# engine renders a verdict on every row individually. The bash suite does the
# same over the same two files: identical pattern text is not evidence that the
# two engines agree — only a per-row verdict on both sides is.
$PatternCases = @(
    $UrlCases | ForEach-Object {
        @{ Kind = $_.Kind; Url = $_.Url; Scheme = $PatternRows['SCHEME']; Scp = $PatternRows['SCP'] }
    }
)

BeforeAll {
    . (Join-Path $PSScriptRoot "..\lib\session-sync-security-common.ps1")
}

AfterAll {
    Complete-SyncSecuritySuite
}

Describe "session-sync-init.ps1 canonical allowlist patterns" {
    It ".NET regex renders <Kind> for <Url>" -ForEach $PatternCases {
        $Scheme | Should -Not -BeNullOrEmpty -Because "the pattern fixture must supply SCHEME"
        $Scp | Should -Not -BeNullOrEmpty -Because "the pattern fixture must supply SCP"
        $verdict = if (($Url -match $Scheme) -or ($Url -match $Scp)) { "ALLOW" } else { "DENY" }
        $verdict | Should -Be $Kind -Because "the canonical patterns must classify $Url as $Kind under .NET regex too"
    }

    It "neither installer uses a non-capturing group" {
        # `(?:...)` is legal in .NET and rejected by POSIX ERE, so it is the one
        # construct that can make the two installers silently disagree. Checked
        # on both files, symmetric per CPR-ORTH with the bash suite.
        $linuxInit = Join-Path (Join-Path $script:DotfilesDir "install") "linux\session-sync-init.sh"
        foreach ($src in @($script:InitScript, $linuxInit)) {
            (Get-Content $src -Raw) | Should -Not -BeLike '*(?:*' -Because "$src must stay POSIX ERE compatible"
        }
    }
}

Describe "session-sync-init.ps1 remote-URL allowlist" {
    # Table-driven per skills/_shared/test-design/parser-regex-tests.md, over the
    # contrast table shared verbatim with tests/main-session-sync/security.sh.
    # Classifier both-direction (protection-fix-tests.md Pattern 4): an
    # over-broad refusal fails as loudly as an accepted attack URL.
    It "verdict <Kind> for <Url>" -ForEach $UrlCases {
        $claudeDir = New-ClaudeDir "url"
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; RemoteUrl = $Url }
        if ($Kind -eq "ALLOW") {
            $rc | Should -Be 0 -Because "a legitimate remote URL must be accepted: $Url"
            (git -C (Join-Path $claudeDir "projects") remote get-url origin) | Should -Be $Url
        } else {
            $rc | Should -Not -Be 0 -Because "a forbidden remote URL must be refused: $Url"
            # Validation lands before the first write, so projects\ must not
            # exist at all — not merely be repo-less.
            Test-Path (Join-Path $claudeDir "projects") | Should -BeFalse -Because "a refused URL must not create the projects dir"
        }
    }

    # -ForEach carries the count in, because $UrlCases is a discovery-time
    # variable and is out of scope by the time the It body runs.
    It "parsed the whole contrast table" -ForEach @(@{ CaseCount = $UrlCases.Count }) {
        $CaseCount | Should -BeGreaterOrEqual 16 -Because "the TAB separator must survive Get-Content"
    }
}

Describe "session-sync-init.ps1 -ClaudeDir profile boundary" {
    It "refuses a claude dir outside the user profile" {
        $outside = Join-Path $script:OutsideRoot "claude-$(Get-Random)"
        $rc = Invoke-Init @{ ClaudeDir = $outside; NoRemote = $true }
        $rc | Should -Not -Be 0
        Test-Path (Join-Path $outside "projects") | Should -BeFalse
    }

    It "accepts a claude dir inside the user profile" {
        $inside = Join-Path $script:SuiteHome "inside-$(Get-Random)"
        $rc = Invoke-Init @{ ClaudeDir = $inside; NoRemote = $true }
        $rc | Should -Be 0 -Because "the profile interior is the supported case"
    }

    It "accepts a claude dir that is exactly the user profile" {
        # The sanctioned edge of the containment rule: $ClaudeDir may equal the
        # profile, only $ProjectsDir may not equal $ClaudeDir. An off-by-one
        # `-gt` on the path depth, or a "strictly below" test written for the
        # inner boundary, would refuse the legitimate layout here. The bash
        # suite covers this exact row, so PowerShell must too (CPR-ORTH).
        $rc = Invoke-Init @{ ClaudeDir = $script:SuiteHome; NoRemote = $true }
        $rc | Should -Be 0 -Because "the profile root itself is inside the profile"
        Test-Path (Join-Path $script:SuiteHome "projects\.git") | Should -BeTrue
    }

    It "leaves an out-of-profile git root untouched when it refuses" {
        # The bare-directory case above proves the path is refused; this one
        # measures what the refusal is worth. A real ~/.claude outside the
        # profile carries exactly what the migration deletes, so the committed
        # repo, both seed files and the tracked working tree must all survive.
        $outside = New-OldRoot (Join-Path $script:OutsideRoot "with-git-$(Get-Random)") "https://example.invalid/outside.git"
        $head = Get-RepoHead $outside
        $rc = Invoke-Init @{ ClaudeDir = $outside; NoRemote = $true; ExpectedOrigin = "https://example.invalid/outside.git" }
        $rc | Should -Not -Be 0
        Get-RepoHead $outside | Should -Be $head -Because "a rejected run must not move or destroy the repo"
        (Get-Content (Join-Path $outside ".gitignore") -Raw) | Should -Be "old-gitignore"
        (Get-Content (Join-Path $outside ".gitattributes") -Raw) | Should -Be "old-gitattributes"
        Test-Path (Join-Path $outside "old-session.jsonl") | Should -BeTrue
        Test-Path (Join-Path $outside "projects") | Should -BeFalse
        Get-StagingResidue $outside | Should -BeNullOrEmpty
    }

    It "does not create projects when git is unavailable" {
        # Error-path symmetry with the bash suite's "No git warning" case: the
        # installer's first act is to require git, and the failure must be
        # announced rather than silently half-initializing the profile.
        $claudeDir = New-ClaudeDir "nogit"
        $emptyPath = Join-Path $script:SuiteHome "nopath-$(Get-Random)"
        New-Item -ItemType Directory -Path $emptyPath -Force | Out-Null
        $savedPath = $env:PATH
        try {
            $env:PATH = $emptyPath
            $result = Invoke-InitCaptured @{ ClaudeDir = $claudeDir; NoRemote = $true }
        } finally {
            $env:PATH = $savedPath
        }
        $result.Output | Should -Match '(?i)git' -Because "the missing prerequisite must be named"
        Test-Path (Join-Path $claudeDir "projects") | Should -BeFalse -Because "a run that cannot finish must not leave a half-built layout"
    }

    It "refuses a same-prefix sibling of the user profile" {
        # "<profile>-sibling" shares the profile as a string prefix but is not a
        # descendant; a separator-less StartsWith would wrongly admit it.
        $sibling = "$($script:SuiteHome)-sibling"
        try {
            $rc = Invoke-Init @{ ClaudeDir = (Join-Path $sibling ".claude"); NoRemote = $true }
            $rc | Should -Not -Be 0
            Test-Path (Join-Path $sibling ".claude\projects") | Should -BeFalse
        } finally {
            Remove-Item -Recurse -Force $sibling -ErrorAction SilentlyContinue
        }
    }

    It "refuses a normalized .. traversal out of the profile" {
        # Every escape below hides in a junction; this one hides in the literal
        # argument. "<profile>\inside\..\..\<outside>\x" starts with the profile
        # as a string and resolves outside it, so a StartsWith check on the raw
        # argument admits it and the run proceeds to delete a repo that is not in
        # the profile at all. Only Resolve-RealPath separates the two, so the
        # payoff is planted first and asserted intact afterwards.
        $outsideLeaf = Split-Path -Leaf $script:OutsideRoot
        $travName = "trav-$(Get-Random)"
        $target = Join-Path $script:OutsideRoot $travName
        $origin = "https://example.invalid/traverse.git"
        New-OldRoot $target $origin | Out-Null
        $head = Get-RepoHead $target
        # Content, not just HEAD: an uncommitted overwrite of the working tree
        # would leave HEAD untouched, so the bytes and a clean status carry it.
        $snapshot = Get-TrackedSnapshot $target
        Get-WorktreeStatus $target | Should -BeNullOrEmpty -Because "the fixture must be clean before the run"
        New-Item -ItemType Directory -Path (Join-Path $script:SuiteHome "inside") -Force | Out-Null
        # A matching -ExpectedOrigin removes provenance as a candidate reason for
        # the refusal: were containment naive, this run would migrate for real.
        $traversal = Join-Path $script:SuiteHome "inside\..\..\$outsideLeaf\$travName"
        $rc = Invoke-Init @{ ClaudeDir = $traversal; NoRemote = $true; ExpectedOrigin = $origin }
        $rc | Should -Not -Be 0 -Because "the argument resolves outside the profile"
        Get-RepoHead $target | Should -Be $head -Because "the repo at the resolved path must survive"
        Get-TrackedSnapshot $target | Should -Be $snapshot -Because "a rejected run must not rewrite content HEAD cannot see"
        Get-WorktreeStatus $target | Should -BeNullOrEmpty -Because "a rejected run must leave no modified, staged or untracked residue"
        (Get-Content (Join-Path $target ".gitignore") -Raw) | Should -Be "old-gitignore"
        (Get-Content (Join-Path $target ".gitattributes") -Raw) | Should -Be "old-gitattributes"
        Test-Path (Join-Path $target "old-session.jsonl") | Should -BeTrue
        Test-Path (Join-Path $target "projects") | Should -BeFalse
        Get-StagingResidue $target | Should -BeNullOrEmpty
    }

    It "accepts .. segments that normalize back inside the profile" {
        # The other direction (Pattern 4): the offence is the resolved location,
        # not the substring. A guard written against '..' itself fails here.
        $name = "trav-ok-$(Get-Random)"
        New-Item -ItemType Directory -Path (Join-Path $script:SuiteHome "inside") -Force | Out-Null
        $rc = Invoke-Init @{ ClaudeDir = (Join-Path $script:SuiteHome "inside\..\$name"); NoRemote = $true }
        $rc | Should -Be 0 -Because 'the path normalizes to a legitimate location inside the profile'
        Test-Path (Join-Path $script:SuiteHome "$name\projects\.git") | Should -BeTrue
    }

    It "refuses a junction whose target leaves the profile" {
        $target = Join-Path $script:OutsideRoot "junction-target-$(Get-Random)"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $link = Join-Path $script:SuiteHome "evil-junction-$(Get-Random)"
        try {
            New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because "this environment cannot create junctions"
            return
        }
        $rc = Invoke-Init @{ ClaudeDir = $link; NoRemote = $true }
        $rc | Should -Not -Be 0
        Test-Path (Join-Path $target "projects") | Should -BeFalse
    }

    It "refuses a junction in an intermediate path component" {
        # The escape hides mid-path, so a resolver that only expands the final
        # component would wave it through. Guard for full-path resolution.
        $target = Join-Path $script:OutsideRoot "mid-target-$(Get-Random)"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $link = Join-Path $script:SuiteHome "mid-junction-$(Get-Random)"
        try {
            New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because "this environment cannot create junctions"
            return
        }
        $rc = Invoke-Init @{ ClaudeDir = (Join-Path $link "nested\.claude"); NoRemote = $true }
        $rc | Should -Not -Be 0
        Test-Path (Join-Path $target "nested") | Should -BeFalse
    }
}

Describe "session-sync-init.ps1 projects-dir containment" {
    # The second boundary, measured against $ClaudeDir rather than the profile.
    # A junction at $ClaudeDir\projects redirects every write — New-Item, git
    # init, the migration's rename and delete of .git — onto its target, and the
    # profile check cannot see it, $ClaudeDir itself being legitimate.
    BeforeAll {
        # Defined in BeforeAll, not in the Describe body: the body runs at
        # discovery time, so a function declared there is gone by the time an It
        # executes.
        # New-ProjectsJunction — plant $ClaudeDir\projects as a junction onto a
        # fresh target holding one canary file. Returns $false when junctions are
        # unavailable, so the caller can mark the case Skipped, not vacuous.
        function New-ProjectsJunction {
            param([string]$ClaudeDir, [string]$Target)
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            Set-Content -Path (Join-Path $Target "canary.txt") -Value "untouched" -NoNewline
            try {
                New-Item -ItemType Junction -Path (Join-Path $ClaudeDir "projects") -Target $Target -ErrorAction Stop | Out-Null
            } catch {
                return $false
            }
            return $true
        }
    }

    BeforeEach {
        $script:ContClaude = New-OldRoot (Join-Path $script:SuiteHome "cont-$(Get-Random)") $script:OriginL
        $script:ContHead = Get-RepoHead $script:ContClaude
    }

    It "refuses a projects junction pointing outside the profile" {
        $target = Join-Path $script:OutsideRoot "cont-out-$(Get-Random)"
        if (-not (New-ProjectsJunction $script:ContClaude $target)) {
            Set-ItResult -Skipped -Because "this environment cannot create junctions"
            return
        }
        $rc = Invoke-Init @{ ClaudeDir = $script:ContClaude; NoRemote = $true; ExpectedOrigin = $script:OriginL }
        $rc | Should -Not -Be 0
        (Get-Content (Join-Path $target "canary.txt") -Raw) | Should -Be "untouched"
        @(Get-ChildItem $target -Force).Count | Should -Be 1 -Because "nothing may be written through the junction"
        Get-RepoHead $script:ContClaude | Should -Be $script:ContHead -Because "the pre-existing .git must survive a refusal"
    }

    It "refuses a projects junction inside the profile but outside the claude dir" {
        # The case a profile-only containment check passes: the target is a
        # legitimate part of the user's home and the migration would still
        # rename and delete inside it, so containment must be measured against
        # $ClaudeDir rather than the profile.
        $target = Join-Path $script:SuiteHome "cont-sibling-$(Get-Random)"
        if (-not (New-ProjectsJunction $script:ContClaude $target)) {
            Set-ItResult -Skipped -Because "this environment cannot create junctions"
            return
        }
        $rc = Invoke-Init @{ ClaudeDir = $script:ContClaude; NoRemote = $true; ExpectedOrigin = $script:OriginL }
        $rc | Should -Not -Be 0 -Because "inside the profile is not inside the claude dir"
        (Get-Content (Join-Path $target "canary.txt") -Raw) | Should -Be "untouched"
        @(Get-ChildItem $target -Force).Count | Should -Be 1
        Get-RepoHead $script:ContClaude | Should -Be $script:ContHead
    }

    It "refuses a self-referential projects junction" {
        # projects -> $ClaudeDir resolves back onto the parent, so Phase 3's
        # recursive delete would reach the whole claude dir. Equality is a
        # rejection here, not a boundary pass.
        try {
            New-Item -ItemType Junction -Path (Join-Path $script:ContClaude "projects") -Target $script:ContClaude -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because "this environment cannot create junctions"
            return
        }
        $rc = Invoke-Init @{ ClaudeDir = $script:ContClaude; NoRemote = $true; ExpectedOrigin = $script:OriginL }
        $rc | Should -Not -Be 0
        Get-RepoHead $script:ContClaude | Should -Be $script:ContHead -Because "the repo the link points at must survive"
        Test-Path (Join-Path $script:ContClaude "old-session.jsonl") | Should -BeTrue
    }

    It "still accepts a real projects directory" {
        # The other direction (Pattern 4): the guard must not refuse the ordinary
        # layout it exists to protect.
        $claudeDir = New-ClaudeDir "cont-ok"
        New-Item -ItemType Directory -Path (Join-Path $claudeDir "projects") -Force | Out-Null
        $rc = Invoke-Init @{ ClaudeDir = $claudeDir; NoRemote = $true }
        $rc | Should -Be 0
        Test-Path (Join-Path $claudeDir "projects\.git") | Should -BeTrue
    }
}
