# Shared setup for the session-sync-init.ps1 security suites (#1773).
# Dot-source from a Pester BeforeAll: it runs in the caller's scope, so the
# $script: variables and functions below land in the container that sourced it.
# Single source of truth (CPR-SSOT) for three .Tests.ps1 files whose fixtures and
# helpers must stay identical: main-session-sync-security[-migration|-transaction].

# $PSScriptRoot resolves to this file's own directory (tests/lib) even while the
# file is dot-sourced, so the repo root is two levels up.
$script:TestsDir = Split-Path -Parent $PSScriptRoot
$script:DotfilesDir = Split-Path -Parent $script:TestsDir
$script:InitScript = Join-Path (Join-Path $script:DotfilesDir "install") "win\session-sync-init.ps1"
$script:FixturesDir = Join-Path $script:TestsDir "fixtures"

$script:SavedEnv = @{
    GIT_CONFIG_NOSYSTEM = $env:GIT_CONFIG_NOSYSTEM
    GIT_CONFIG_GLOBAL   = $env:GIT_CONFIG_GLOBAL
    USERPROFILE         = $env:USERPROFILE
    PATH                = $env:PATH
}

# Stricter than a literal `$env:USERPROFILE = $env:TEMP`: a dedicated
# subdirectory keeps "inside the profile" and "outside it" both expressible
# under $env:TEMP, which the boundary cases need.
$script:SuiteHome = Join-Path $env:TEMP "sync-sec-home-$(Get-Random)"
New-Item -ItemType Directory -Path $script:SuiteHome -Force | Out-Null
$script:OutsideRoot = Join-Path $env:TEMP "sync-sec-outside-$(Get-Random)"
New-Item -ItemType Directory -Path $script:OutsideRoot -Force | Out-Null

# Minimal git environment: the developer's global core.hooksPath would otherwise
# abort every fixture commit.
$script:SuiteGitConfig = Join-Path $script:SuiteHome "gitconfig"
Set-Content -Path $script:SuiteGitConfig -Value @(
    '[user]'
    "`tname = Session Sync Test"
    "`temail = session-sync-test@example.com"
    '[init]'
    "`tdefaultBranch = main"
    '[commit]'
    "`tgpgSign = false"
)
$env:GIT_CONFIG_NOSYSTEM = "1"
$env:GIT_CONFIG_GLOBAL = $script:SuiteGitConfig
$env:USERPROFILE = $script:SuiteHome

$script:OriginL = "https://example.invalid/provenance-l.git"
$script:OriginM = "https://example.invalid/provenance-m.git"

# Invoke-Init — run the installer and reduce every failure mode (thrown
# terminating error or non-zero exit) to a single integer exit code. Takes a
# hashtable, not remaining arguments: array splatting binds positionally and
# would silently feed the literal "-ClaudeDir" in as the directory.
function Invoke-Init {
    param([Parameter(Mandatory)][hashtable]$Params)
    $global:LASTEXITCODE = 0
    try {
        & $script:InitScript @Params *>&1 | Out-String | Out-Null
    } catch {
        return 1
    }
    if ($LASTEXITCODE -ne 0) { return $LASTEXITCODE }
    return 0
}

# Invoke-InitCaptured — Invoke-Init plus the text the installer wrote. Returns
# @{ Code; Output }. Output-facing contracts need the text itself: a secret that
# must never be printed, and a diagnostic that must be.
function Invoke-InitCaptured {
    param([Parameter(Mandatory)][hashtable]$Params)
    $global:LASTEXITCODE = 0
    try {
        $text = (& $script:InitScript @Params *>&1 | Out-String)
    } catch {
        return @{ Code = 1; Output = "$_" }
    }
    if ($LASTEXITCODE -ne 0) { return @{ Code = $LASTEXITCODE; Output = $text } }
    return @{ Code = 0; Output = $text }
}

# New-OldRoot — build a pre-migration layout: a git root directly in the claude
# dir, one real commit, and the two seed files the migration moves. The commit
# is what lets a later assertion tell "the old repo moved" from "a fresh repo was
# initialized at the destination".
function New-OldRoot {
    param([Parameter(Mandatory)][string]$ClaudeDir, [string]$Origin = "")
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
    git init $ClaudeDir 2>&1 | Out-Null
    git -C $ClaudeDir config core.hooksPath /dev/null 2>&1 | Out-Null
    git -C $ClaudeDir config user.email "session-sync-test@example.com" 2>&1 | Out-Null
    git -C $ClaudeDir config user.name "Session Sync Test" 2>&1 | Out-Null
    if ($Origin) { git -C $ClaudeDir remote add origin $Origin 2>&1 | Out-Null }
    Set-Content -Path (Join-Path $ClaudeDir ".gitignore") -Value "old-gitignore" -NoNewline
    Set-Content -Path (Join-Path $ClaudeDir ".gitattributes") -Value "old-gitattributes" -NoNewline
    Set-Content -Path (Join-Path $ClaudeDir "old-session.jsonl") -Value "old-session" -NoNewline
    git -C $ClaudeDir add -A 2>&1 | Out-Null
    git -C $ClaudeDir commit -q -m "pre-migration history" 2>&1 | Out-Null
    return $ClaudeDir
}

function New-ClaudeDir {
    param([string]$Tag)
    $d = Join-Path $script:SuiteHome "$Tag-$(Get-Random)"
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

# Get-RepoHead — the commit SHA, or "none" when the path is not a repo with a
# commit. `rev-parse --verify` is deliberate: plain `rev-parse HEAD` prints the
# literal "HEAD" on an empty repo and would compare as a real value.
function Get-RepoHead {
    param([Parameter(Mandatory)][string]$Repo)
    if (-not (Test-Path $Repo)) { return "none" }
    $sha = git -C $Repo rev-parse --verify HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $sha) { return "none" }
    return $sha.Trim()
}

# Get-TrackedSnapshot — HEAD plus the literal content of every tracked file, as
# one comparable blob. A rejected run that overwrites the working tree without
# committing leaves HEAD exactly where it was, so only the content proves the
# protected repo is unchanged.
function Get-TrackedSnapshot {
    param([Parameter(Mandatory)][string]$Repo)
    if (-not (Test-Path (Join-Path $Repo ".git"))) { return "NO-REPO" }
    $lines = @("head=$(Get-RepoHead $Repo)")
    foreach ($name in (@(git -C $Repo ls-files 2>$null) | Sort-Object)) {
        $full = Join-Path $Repo $name
        $content = if (Test-Path $full) { Get-Content $full -Raw -ErrorAction SilentlyContinue } else { "MISSING" }
        $lines += "file=$name content=[$content]"
    }
    return ($lines -join "`n")
}

# Get-WorktreeStatus — `git status --porcelain` joined into one string. Empty
# means no modified, staged or untracked residue; "NO-REPO" when the repo is gone.
function Get-WorktreeStatus {
    param([Parameter(Mandatory)][string]$Repo)
    if (-not (Test-Path (Join-Path $Repo ".git"))) { return "NO-REPO" }
    return ((@(git -C $Repo status --porcelain 2>$null) | Sort-Object) -join ';')
}

# Get-GitResidue — names under $Dir that are `.git`, `.gitignore`,
# `.gitattributes`, or any suffixed variant of them (`.git.bak`, `.git.old.123`).
# A successful migration must leave none of these in $CLAUDE_DIR.
function Get-GitResidue {
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path $Dir)) { return @() }
    return @(Get-ChildItem $Dir -Force |
        Where-Object { $_.Name -match '^\.git(ignore|attributes)?($|\.)' } |
        ForEach-Object { $_.Name })
}

# Get-StagingResidue — leftover transaction staging names ANYWHERE under $Dir.
# The migration can stage a name one level down (inside projects\, or beside a
# nested repo), so a top-level-only scan would report such a tree as clean.
function Get-StagingResidue {
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path $Dir)) { return @() }
    return @(Get-ChildItem $Dir -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(old|migrate-tmp|bak)(\.|$)' } |
        ForEach-Object { $_.FullName.Substring($Dir.Length).TrimStart('\', '/') })
}

# Complete-SyncSecuritySuite — AfterAll counterpart: restore the environment and
# delete both fixture roots.
function Complete-SyncSecuritySuite {
    foreach ($name in @($script:SavedEnv.Keys)) {
        $value = $script:SavedEnv[$name]
        if ($null -eq $value) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$name" -Value $value }
    }
    Remove-Item -Recurse -Force $script:SuiteHome -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $script:OutsideRoot -ErrorAction SilentlyContinue
}
