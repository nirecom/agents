# Tests: install/win/session-sync-init.ps1
# Tags: install, git, pwsh-required, security, installer, scope:issue-specific
# Counterpart of tests/main-session-sync/security-remote.sh (CPR-ORTH); split out
# of main-session-sync-security.Tests.ps1 at the 300-line file-split threshold.

# TL3 gap: TL2 — the `.env` under test is one this suite plants in a copied
# layout and no remote is contacted. Not covered: the shipped repo's own .env, a
# credential helper or insteadOf rewriting the URL git finally uses, and a
# console host rendering the printed URL differently from the captured stream.
# Mitigation: checked at WORKFLOW_USER_VERIFIED preflight, category installer.

BeforeAll {
    . (Join-Path $PSScriptRoot "..\lib\session-sync-security-common.ps1")

    $script:Trusted = "https://example.invalid/trusted.git"
    $script:ExtUrl = 'ext::sh -c "touch pwned"'

    # Invoke-InitAt — Invoke-InitCaptured against a relocated copy of the
    # installer. The installer derives its .env path from its own location, so
    # pinning a config value means copying the script into a throwaway layout.
    function Invoke-InitAt {
        param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][hashtable]$Params)
        $global:LASTEXITCODE = 0
        try {
            $text = (& $Script @Params *>&1 | Out-String)
        } catch {
            return @{ Code = 1; Output = "$_" }
        }
        if ($LASTEXITCODE -ne 0) { return @{ Code = $LASTEXITCODE; Output = $text } }
        return @{ Code = 0; Output = $text }
    }

    # New-EnvLayout — <root>\install\win\session-sync-init.ps1 plus <root>\.env,
    # the two levels the installer walks up. Returns the copied script's path;
    # pass an empty $EnvValue to test the no-.env branch, or -EmptyValue to write
    # the key with no value at all, which is a third, distinct state.
    function New-EnvLayout {
        param([Parameter(Mandatory)][string]$Tag, [string]$EnvValue = "", [switch]$EmptyValue)
        $root = Join-Path $script:SuiteHome "cfg-$Tag-$(Get-Random)"
        $dir = Join-Path $root "install\win"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $copy = Join-Path $dir "session-sync-init.ps1"
        Copy-Item $script:InitScript $copy
        if ($EnvValue) {
            Set-Content -Path (Join-Path $root ".env") -Value "SESSION_SYNC_REMOTE_URL=$EnvValue"
        } elseif ($EmptyValue) {
            Set-Content -Path (Join-Path $root ".env") -Value "SESSION_SYNC_REMOTE_URL="
        }
        return $copy
    }

    function Get-Origin {
        param([Parameter(Mandatory)][string]$ClaudeDir)
        $url = git -C (Join-Path $ClaudeDir "projects") remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $url) { return "none" }
        return $url.Trim()
    }
}

AfterAll {
    Complete-SyncSecuritySuite
}

Describe "session-sync-init.ps1 remote URL resolution" {
    # Config-dependent branch (skills/_shared/test-design.md): the URL resolves
    # from -RemoteUrl > .env > the built-in default. A suite that never writes
    # .env silently exercises only whichever value the checkout happens to carry.

    It "uses an allowed remote URL supplied by .env" {
        $url = "https://example.invalid/from-env.git"
        $exe = New-EnvLayout "env-ok" $url
        $claudeDir = New-ClaudeDir "cfg-ok"
        $result = Invoke-InitAt $exe @{ ClaudeDir = $claudeDir }
        $result.Code | Should -Be 0
        Get-Origin $claudeDir | Should -Be $url
    }

    It "refuses a forbidden remote URL supplied by .env" {
        # .env is a file an installer copies around, so a forbidden value there
        # must die on the same allowlist a CLI value does — and, like the CLI
        # path, before the first filesystem write.
        $exe = New-EnvLayout "env-bad" $script:ExtUrl
        $claudeDir = New-ClaudeDir "cfg-bad"
        $result = Invoke-InitAt $exe @{ ClaudeDir = $claudeDir }
        $result.Code | Should -Not -Be 0 -Because "an ext:: URL is an RCE vector wherever it comes from"
        Test-Path (Join-Path $claudeDir "projects") | Should -BeFalse -Because "validation must land before the first write"
        Test-Path (Join-Path $claudeDir "pwned") | Should -BeFalse
    }

    It "lets -RemoteUrl outrank .env" {
        $exe = New-EnvLayout "env-override" "https://example.invalid/from-env.git"
        $claudeDir = New-ClaudeDir "cfg-override"
        $result = Invoke-InitAt $exe @{ ClaudeDir = $claudeDir; RemoteUrl = $script:Trusted }
        $result.Code | Should -Be 0
        Get-Origin $claudeDir | Should -Be $script:Trusted
    }

    It "falls back to the built-in default when no .env exists" {
        # Third branch of the same chain: the shipped default must satisfy the
        # installer's own allowlist, or a clean install refuses itself.
        $exe = New-EnvLayout "env-absent"
        $claudeDir = New-ClaudeDir "cfg-default"
        $result = Invoke-InitAt $exe @{ ClaudeDir = $claudeDir }
        $result.Code | Should -Be 0
        Get-Origin $claudeDir | Should -Be "git@github.com:nirecom/agent-sessions.git"
    }

    It "falls through to the built-in default when .env sets an empty value" {
        # The state between branches two and three: the key is present, its value
        # is empty. The resolver's own priority makes that a fall-through, not
        # "configured to nothing" and not an error — an implementation testing
        # key presence rather than value emptiness diverges exactly here.
        $exe = New-EnvLayout "env-empty" -EmptyValue
        $claudeDir = New-ClaudeDir "cfg-empty"
        $result = Invoke-InitAt $exe @{ ClaudeDir = $claudeDir }
        $result.Code | Should -Be 0 -Because "an empty value must not be an error"
        Get-Origin $claudeDir | Should -Be "git@github.com:nirecom/agent-sessions.git"
    }
}

Describe "session-sync-init.ps1 provenance from the resolved config" {
    # The provenance matrix in main-session-sync-security-migration.Tests.ps1
    # names the expectation on the command line; install.ps1 names neither flag.
    # On a real upgrade the value that decides whether the user's claude-dir repo
    # is migrated therefore comes out of the .env > built-in-default chain this
    # file already pins, so both directions of the comparison are exercised here,
    # where New-EnvLayout lives (CPR-SSOT: one copy of the layout helper).

    BeforeAll {
        # Declared in BeforeAll, not in the Describe body: the body runs at
        # discovery time, so a function declared there is gone by the time an It
        # executes.
        # Invoke-ProvenanceCase — plant an old root carrying $OldOrigin, run the
        # relocated installer with no remote/origin flag, return its exit code.
        # The pre-run snapshot and status are recorded for the refusing rows: an
        # uncommitted overwrite leaves HEAD alone, so only content and a clean
        # `status --porcelain` prove the protected repo untouched.
        function Invoke-ProvenanceCase {
            param([Parameter(Mandatory)][string]$Tag, [string]$EnvValue = "", [switch]$EmptyValue, [Parameter(Mandatory)][string]$OldOrigin)
            $exe = New-EnvLayout "prov-$Tag" $EnvValue -EmptyValue:$EmptyValue
            $script:ProvDir = New-OldRoot (Join-Path $script:SuiteHome "prov-cfg-$Tag-$(Get-Random)") $OldOrigin
            $script:ProvHead = Get-RepoHead $script:ProvDir
            $script:ProvSnapshot = Get-TrackedSnapshot $script:ProvDir
            $script:ProvStatus = Get-WorktreeStatus $script:ProvDir
            return (Invoke-InitAt $exe @{ ClaudeDir = $script:ProvDir }).Code
        }

        # Assert-ProvenanceUntouched — the full non-change proof both refusing
        # rows owe: clean before and after, byte-identical tracked content, both
        # seed files intact, and no staging artifact left behind.
        function Assert-ProvenanceUntouched {
            $script:ProvStatus | Should -BeNullOrEmpty -Because "the fixture must be clean before the run"
            Get-RepoHead $script:ProvDir | Should -Be $script:ProvHead
            Get-TrackedSnapshot $script:ProvDir | Should -Be $script:ProvSnapshot -Because "a rejected run must not rewrite content HEAD cannot see"
            Get-WorktreeStatus $script:ProvDir | Should -BeNullOrEmpty -Because "a rejected run must leave no modified, staged or untracked residue"
            (Get-Content (Join-Path $script:ProvDir ".gitignore") -Raw) | Should -Be "old-gitignore"
            (Get-Content (Join-Path $script:ProvDir ".gitattributes") -Raw) | Should -Be "old-gitattributes"
            Test-Path (Join-Path $script:ProvDir "old-session.jsonl") | Should -BeTrue
            Get-StagingResidue $script:ProvDir | Should -BeNullOrEmpty
        }
    }

    It "migrates when the .env URL matches the old origin" {
        $url = "https://example.invalid/from-env.git"
        $rc = Invoke-ProvenanceCase -Tag "env-match" -EnvValue $url -OldOrigin $url
        $rc | Should -Be 0 -Because "the config-resolved URL identifies the repo just as -ExpectedOrigin does"
        Get-RepoHead (Join-Path $script:ProvDir "projects") | Should -Be $script:ProvHead
        Get-GitResidue $script:ProvDir | Should -BeNullOrEmpty
    }

    It "refuses when the .env URL does not match the old origin" {
        $rc = Invoke-ProvenanceCase -Tag "env-mismatch" -EnvValue "https://example.invalid/from-env.git" -OldOrigin $script:OriginM
        $rc | Should -Not -Be 0 -Because "an unidentified repo under the claude dir may be the user's own work"
        Test-Path (Join-Path $script:ProvDir "projects") | Should -BeFalse -Because "the verdict precedes the first write"
        Assert-ProvenanceUntouched
    }

    It "migrates when the built-in default matches the old origin" {
        # No .env at all: the third branch of the chain is what a stock install
        # actually compares against.
        $rc = Invoke-ProvenanceCase -Tag "default-match" -OldOrigin "git@github.com:nirecom/agent-sessions.git"
        $rc | Should -Be 0
        Get-RepoHead (Join-Path $script:ProvDir "projects") | Should -Be $script:ProvHead
    }

    It "refuses when the built-in default does not match the old origin" {
        $rc = Invoke-ProvenanceCase -Tag "default-mismatch" -OldOrigin $script:OriginM
        $rc | Should -Not -Be 0
        Test-Path (Join-Path $script:ProvDir "projects") | Should -BeFalse
        Assert-ProvenanceUntouched
    }

    It "judges provenance against the default when .env sets an empty value" {
        # An empty value falls through to the built-in default, so the repo a
        # stock upgrade owns must still be recognized. Judged against an empty
        # expectation it would fail closed instead.
        $rc = Invoke-ProvenanceCase -Tag "empty-match" -EmptyValue -OldOrigin "git@github.com:nirecom/agent-sessions.git"
        $rc | Should -Be 0 -Because "the fall-through default is the expectation"
        Get-RepoHead (Join-Path $script:ProvDir "projects") | Should -Be $script:ProvHead
    }

    It "still refuses a foreign repo when .env sets an empty value" {
        $rc = Invoke-ProvenanceCase -Tag "empty-mismatch" -EmptyValue -OldOrigin $script:OriginM
        $rc | Should -Not -Be 0 -Because "the fall-through must not become a blanket allow"
        Assert-ProvenanceUntouched
    }
}

Describe "session-sync-init.ps1 denied URL over a configured repo" {
    # The table cases all start from an empty directory, where "nothing
    # happened" and "nothing existed" are indistinguishable. With a trusted
    # origin already in place a refusal has something to damage, and the branch
    # under test is `remote set-url`, not `remote add`.
    BeforeEach {
        $script:RemClaude = New-ClaudeDir "rem"
        (Invoke-Init @{ ClaudeDir = $script:RemClaude; RemoteUrl = $script:Trusted }) | Should -Be 0 -Because "the trusted setup run must succeed before the attack"
        Set-Content -Path (Join-Path $script:RemClaude "projects\keep.txt") -Value "payload" -NoNewline
        git -C (Join-Path $script:RemClaude "projects") add -A 2>&1 | Out-Null
        git -C (Join-Path $script:RemClaude "projects") commit -q -m "existing work" 2>&1 | Out-Null
        $script:RemHead = Get-RepoHead (Join-Path $script:RemClaude "projects")
    }

    It "keeps origin and the repository intact for <Tag>" -ForEach @(
        @{ Tag = "ext"; Url = 'ext::sh -c "touch pwned"' }
        @{ Tag = "option"; Url = "--upload-pack=touch pwned" }
    ) {
        $rc = Invoke-Init @{ ClaudeDir = $script:RemClaude; RemoteUrl = $Url }
        $rc | Should -Not -Be 0 -Because "a forbidden URL must be refused over a configured repo too"
        Get-Origin $script:RemClaude | Should -Be $script:Trusted -Because "the refusal must not rewrite origin"
        Get-RepoHead (Join-Path $script:RemClaude "projects") | Should -Be $script:RemHead
        Test-Path (Join-Path $script:RemClaude "projects\keep.txt") | Should -BeTrue
    }
}

Describe "session-sync-init.ps1 credential-bearing URL output" {
    # The allowlist deliberately permits userinfo, so https://user:token@host/… is
    # a configuration the installer accepts — and both print branches render the
    # whole URL. Installer output lands in CI logs and install transcripts, so the
    # secret must not be in it (test-design.md secret-leakage case, ASVS V8).
    BeforeAll {
        $script:Sentinel = "SENTINEL-NOT-A-REAL-TOKEN"
        $script:CredUrl = "https://ci-user:$($script:Sentinel)@example.invalid/repo.git"
        $script:CredUrl2 = "https://ci-user:$($script:Sentinel)@example.invalid/other.git"
        $script:CredClaude = New-ClaudeDir "cred"
    }

    It "configures the remote without printing the password" {
        $result = Invoke-InitCaptured @{ ClaudeDir = $script:CredClaude; RemoteUrl = $script:CredUrl }
        $result.Code | Should -Be 0 -Because "userinfo is an allowed URL shape"
        Get-Origin $script:CredClaude | Should -Be $script:CredUrl
        $result.Output | Should -Not -Match ([regex]::Escape($script:Sentinel)) -Because "the add branch must mask the credential"
    }

    It "updates the remote without printing the password" {
        $result = Invoke-InitCaptured @{ ClaudeDir = $script:CredClaude; RemoteUrl = $script:CredUrl2 }
        $result.Code | Should -Be 0
        Get-Origin $script:CredClaude | Should -Be $script:CredUrl2
        $result.Output | Should -Not -Match ([regex]::Escape($script:Sentinel)) -Because "the set-url branch must mask the credential too"
    }
}
