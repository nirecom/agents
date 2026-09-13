# session-sync-init.ps1 - Initialize ~/.claude/projects as a git repo for session sync
# Usage: Called by install.ps1, or manually: .\session-sync-init.ps1
# Security contract (#1773) — URL allowlist, two-stage containment, fail-closed
# migration provenance, transactional migration — and the PowerShell/bash
# symmetry it must keep: docs/architecture/claude-code/session-sync.md.

param(
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE ".claude"),
    [string]$RemoteUrl = "",
    [string]$ExpectedOrigin = "",
    [switch]$NoRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$defaultRemote = "git@github.com:nirecom/agent-sessions.git"

# Canonical allowlist patterns (detail.md A2), shared verbatim with the bash
# installer and tests/fixtures/session-sync-remote-url-patterns.txt. Capturing
# groups only: a non-capturing group is legal in .NET and rejected by POSIX ERE,
# so it is the one construct that could make the two installers disagree.
$UrlReScheme = '^(https|ssh|git)://([^/@]+@)?(\[[0-9A-Fa-f:]*[0-9A-Fa-f][0-9A-Fa-f:]*\]|[A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]+)?(/.*)?$'
$UrlReScp = '^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*:[^:].*$'

function Test-AllowedRemoteUrl {
    param([string]$Url)
    if (-not $Url) { return $false }
    return (($Url -match $UrlReScheme) -or ($Url -match $UrlReScp))
}

# Installer output reaches CI logs and install transcripts, so the userinfo
# password never appears in it (ASVS V8).
function Get-RedactedUrl {
    param([string]$Url)
    if (-not $Url) { return "" }
    return [regex]::Replace($Url, '^([A-Za-z0-9+.-]+://[^/@]*):[^/@]*@', '$1:***@')
}

# Resolve-RealPath — the fully reparse-point-resolved, `..`-normalized location a
# path denotes, whether or not it exists yet. Every component is resolved, not
# just the last one: an escape hiding in an intermediate junction must be
# expanded too.
function Resolve-RealPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $null }
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not $root) { return $null }
    $rest = $full.Substring($root.Length)
    $current = $root
    foreach ($seg in @($rest -split '\\' | Where-Object { $_ })) {
        $current = [System.IO.Path]::Combine($current, $seg)
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            $target = $null
            if ($item.PSObject.Properties['LinkTarget'] -and $item.LinkTarget) {
                $target = "$($item.LinkTarget)"
            } elseif ($item.PSObject.Properties['Target'] -and $item.Target) {
                $target = "$(@($item.Target)[0])"
            }
            if ($target) {
                if ($target.StartsWith('\??\')) { $target = $target.Substring(4) }
                if (-not [System.IO.Path]::IsPathRooted($target)) {
                    $target = [System.IO.Path]::Combine((Split-Path -Parent $current), $target)
                }
                $resolved = Resolve-RealPath $target
                if (-not $resolved) { return $null }
                $current = $resolved
            }
        }
    }
    $trimmed = $current.TrimEnd('\')
    if (-not $trimmed) { return $current }
    return $trimmed
}

# Test-PathInside — separator-aware containment. A bare StartsWith would admit
# "<profile>-sibling", which shares the prefix but is not a descendant.
function Test-PathInside {
    param([string]$Child, [string]$Parent, [switch]$AllowEqual)
    if (-not $Child -or -not $Parent) { return $false }
    $c = $Child.TrimEnd('\')
    $p = $Parent.TrimEnd('\')
    if ($c -eq $p) { return [bool]$AllowEqual }
    return $c.StartsWith(($p + '\'), [System.StringComparison]::OrdinalIgnoreCase)
}

# Move-NoClobber <From> <To> — rename only onto a free destination. Success is
# the post-condition "From gone AND To present", never the absence of an
# exception: a declining provider or a silent no-op is the .NET counterpart of
# GNU `mv -n` exiting 0 without moving anything.
function Move-NoClobber {
    param([string]$From, [string]$To)
    if (-not $From -or -not $To) { return $false }
    if (Test-Path -LiteralPath $To) { return $false }
    try {
        $fromParent = Split-Path -Parent $From
        $toParent = Split-Path -Parent $To
        if ($fromParent -eq $toParent) {
            Rename-Item -LiteralPath $From -NewName (Split-Path -Leaf $To) -ErrorAction Stop | Out-Null
        } else {
            Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop | Out-Null
        }
    } catch {
        # Deliberately swallowed: the post-condition below is the verdict.
    }
    if (Test-Path -LiteralPath $From) { return $false }
    if (-not (Test-Path -LiteralPath $To)) { return $false }
    return $true
}

# Invoke-GitRootMigration <Src> <Dst> — move the git root and its two seed files
# as a transaction (detail.md D): Phase 0 refuses to start over stale staging
# paths, 1a stages Dst's incumbents aside, 1b moves Src's copies in under a
# temporary name, 2 promotes them onto the bare names, 3 deletes the staged
# incumbents best-effort. Any earlier failure rolls back and returns $false.
# Staging uses `.old.<pid>` / `.migrate-tmp.<pid>`, never `.bak` — deliberately
# overriding rules/coding.md, since `.bak` is not a terminal state here.
function Invoke-GitRootMigration {
    param([string]$Src, [string]$Dst)
    $names = @(".git", ".gitignore", ".gitattributes")
    $stamp = $PID
    $stagedOld = @()
    $movedTmp = @()
    $promoted = @()

    # A nested function, not a scriptblock variable: the transaction suite lifts
    # this body out with the AST and runs it as an unbound scriptblock, where
    # invoking a stored scriptblock has no session state to run in.
    function Restore-MigrationState {
        foreach ($n in @($promoted)) {
            try { Move-Item -LiteralPath (Join-Path $Dst $n) -Destination (Join-Path $Dst "$n.migrate-tmp.$stamp") -ErrorAction Stop | Out-Null } catch { }
        }
        foreach ($n in @($movedTmp)) {
            try { Move-Item -LiteralPath (Join-Path $Dst "$n.migrate-tmp.$stamp") -Destination (Join-Path $Src $n) -ErrorAction Stop | Out-Null } catch { }
        }
        foreach ($n in @($stagedOld)) {
            try { Move-Item -LiteralPath (Join-Path $Dst "$n.old.$stamp") -Destination (Join-Path $Dst $n) -ErrorAction Stop | Out-Null } catch { }
        }
    }

    try {
        # Phase 0 — a leftover staging name means a crashed run, a recycled PID or
        # a concurrent installer. Fail closed and leave the evidence in place.
        foreach ($dir in @($Src, $Dst)) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $stale = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '\.(old|migrate-tmp)\.[0-9]+$' })
            if ($stale.Count -gt 0) {
                Write-Warning "Migration aborted: stale staging path $(Join-Path $dir $stale[0].Name)"
                return $false
            }
        }

        # Phase 1a — stage the destination's own incumbents aside.
        foreach ($n in $names) {
            if (-not (Test-Path -LiteralPath (Join-Path $Dst $n))) { continue }
            if (Move-NoClobber (Join-Path $Dst $n) (Join-Path $Dst "$n.old.$stamp")) {
                $stagedOld += $n
            } else {
                Restore-MigrationState
                Write-Warning "Migration aborted: could not stage $(Join-Path $Dst $n)"
                return $false
            }
        }

        # Phase 1b — move the incoming copies in under a temporary name.
        foreach ($n in $names) {
            if (-not (Test-Path -LiteralPath (Join-Path $Src $n))) { continue }
            if (Move-NoClobber (Join-Path $Src $n) (Join-Path $Dst "$n.migrate-tmp.$stamp")) {
                $movedTmp += $n
            } else {
                Restore-MigrationState
                Write-Warning "Migration aborted: could not move $(Join-Path $Src $n)"
                return $false
            }
        }

        # Phase 2 — promote onto the bare final names.
        foreach ($n in @($movedTmp)) {
            if (Move-NoClobber (Join-Path $Dst "$n.migrate-tmp.$stamp") (Join-Path $Dst $n)) {
                $promoted += $n
            } else {
                Restore-MigrationState
                Write-Warning "Migration aborted: could not promote $(Join-Path $Dst $n)"
                return $false
            }
        }
    } catch {
        # A terminating filesystem error (a sharing violation on an open .git, a
        # scanner holding a handle) must unwind exactly like a refused rename.
        Restore-MigrationState
        Write-Warning "Migration aborted: $($_.Exception.Message)"
        return $false
    }

    # Phase 3 — best-effort cleanup; its failure never changes the verdict.
    foreach ($n in @($stagedOld)) {
        try { Remove-Item -LiteralPath (Join-Path $Dst "$n.old.$stamp") -Recurse -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    return $true
}

# Set-RepoHardening — neutralize the repo-supplied code paths git would otherwise
# run on our behalf. It must be applied before the first git command that touches
# the worktree: a migrated repo carries its own hooks, fsmonitor command and
# filter definitions, and a checkout is enough to execute them. Returns $false on
# a failed write: an external git command does not throw, so an unchecked call
# would leave the untrusted repo's hooks live for the checkout that follows.
function Set-RepoHardening {
    param([Parameter(Mandatory)][string]$Repo)
    git -C $Repo config core.hooksPath NUL 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    git -C $Repo config core.fsmonitor false 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    return $true
}

# Restore-MissingTracked — bring back the tracked files the git-root move made
# look deleted, without overwriting anything already present at the destination:
# only paths git reports as missing are checked out. The work-tree is the OLD
# root: the index paths are still relative to it, so any other work-tree would
# recreate them one level too deep.
# The `projects` pathspec is what keeps the restore from re-scattering the old
# root: only session files under projects/<enc>/ belong at the new location,
# while .gitignore/.gitattributes and top-level *.jsonl never did.
function Restore-MissingTracked {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$WorkTree
    )
    $gitDir = Join-Path $Repo ".git"
    # core.quotePath=false plus a UTF-8 console: git's default C-style quoting and
    # the OEM code page each turn a non-ASCII path into one that matches no file.
    $prevEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $missing = @(git -C $WorkTree --git-dir=$gitDir --work-tree=$WorkTree -c core.quotePath=false ls-files --deleted -- projects 2>$null)
    } finally {
        [Console]::OutputEncoding = $prevEncoding
    }
    for ($i = 0; $i -lt $missing.Count; $i += 200) {
        $batch = @($missing[$i..([Math]::Min($i + 199, $missing.Count - 1))])
        if ($batch.Count -eq 0) { continue }
        try { git -C $WorkTree --git-dir=$gitDir --work-tree=$WorkTree checkout -- @batch 2>&1 | Out-Null } catch { }
    }
}

# Resolve remote URL: -RemoteUrl > .env > built-in default.
$RemoteUrlEnvFile = ""
if (-not $NoRemote -and -not $RemoteUrl) {
    $envFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ".env"
    if (Test-Path $envFile) {
        $envLine = Get-Content $envFile | Where-Object { $_ -match '^SESSION_SYNC_REMOTE_URL=' } | Select-Object -First 1
        if ($envLine) {
            $RemoteUrl = ($envLine -split '=', 2)[1].Trim('"').Trim("'")
            if ($RemoteUrl) { $RemoteUrlEnvFile = $envFile }
        }
    }
    if (-not $RemoteUrl) { $RemoteUrl = $defaultRemote }
}

if (-not $NoRemote -and $RemoteUrl) {
    if (-not (Test-AllowedRemoteUrl $RemoteUrl)) {
        Write-Warning "Refusing remote URL outside the allowlist: $(Get-RedactedUrl $RemoteUrl)"
        Write-Warning "Only https/ssh/git URLs and the SCP-like user@host:path form are accepted."
        exit 1
    }
}

# Two-stage containment, both fail-closed before the first filesystem write.
$resolvedHome = Resolve-RealPath $env:USERPROFILE
$resolvedClaude = Resolve-RealPath $ClaudeDir
if (-not $resolvedHome -or -not $resolvedClaude) {
    Write-Warning "Refusing to continue: unable to resolve the user profile or the claude dir."
    exit 1
}
if (-not (Test-PathInside -Child $resolvedClaude -Parent $resolvedHome -AllowEqual)) {
    Write-Warning "Refusing a claude dir outside the user profile: $resolvedClaude"
    exit 1
}
$ClaudeDir = $resolvedClaude

# Stage 2 is measured against the RESOLVED claude dir, not the profile: a
# junction at <claude dir>\projects pointing elsewhere in the profile would still
# redirect every write the migration makes. Equality is a rejection too.
$resolvedProjects = Resolve-RealPath (Join-Path $ClaudeDir "projects")
if (-not (Test-PathInside -Child $resolvedProjects -Parent $ClaudeDir)) {
    $shown = if ($resolvedProjects) { $resolvedProjects } else { "<unresolvable>" }
    Write-Warning "Refusing a projects dir outside the claude dir: $shown"
    exit 1
}
$ProjectsDir = $resolvedProjects

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning "Git is required for session sync."
    exit 1
}

# Provenance (detail.md A1): an unidentified repo under the claude dir may be the
# user's own unrelated work, so migration needs a positive origin match.
# Expected origin: explicit -ExpectedOrigin > the validated remote URL > absent,
# and absent is fail-closed. Evaluated before the first write.
$expected = $ExpectedOrigin
if (-not $expected -and -not $NoRemote) {
    # A `.env` sitting inside the very tree whose trustworthiness is being judged
    # cannot authorize its own migration, so it is dropped as a provenance source
    # while still standing as the remote-URL source.
    $envOriginTrusted = $true
    if ($RemoteUrlEnvFile) {
        $resolvedEnvFile = Resolve-RealPath $RemoteUrlEnvFile
        if ($resolvedEnvFile -and (Test-PathInside -Child $resolvedEnvFile -Parent $ClaudeDir -AllowEqual)) {
            $envOriginTrusted = $false
        }
    }
    if ($envOriginTrusted) { $expected = $RemoteUrl }
}

$oldGitRoot = Join-Path $ClaudeDir ".git"
if (Test-Path $oldGitRoot) {
    if (-not $expected) {
        Write-Warning "Refusing to migrate ${oldGitRoot}: no expected origin to verify it against."
        Write-Warning "Re-run with -ExpectedOrigin <url> if this really is the session-sync repo."
        exit 1
    }
    $oldOrigin = ""
    try { $oldOrigin = "$(git -C $ClaudeDir remote get-url origin 2>$null)".Trim() } catch { $oldOrigin = "" }
    if (-not $oldOrigin) {
        Write-Warning "Refusing to migrate ${oldGitRoot}: it has no origin to verify."
        exit 1
    }
    if ($oldOrigin -ne $expected) {
        Write-Warning "Refusing to migrate ${oldGitRoot}: origin $(Get-RedactedUrl $oldOrigin) is not the expected one."
        exit 1
    }
    # The destination loses its own .git to this migration, so a destination that
    # is a repository in its own right — a linked worktree or submodule, or a repo
    # published to some other origin — is refused instead of consumed.
    $dstGit = Join-Path $ProjectsDir ".git"
    if (Test-Path -LiteralPath $dstGit) {
        if (-not (Test-Path -LiteralPath $dstGit -PathType Container)) {
            Write-Warning "Refusing to migrate onto ${ProjectsDir}: its .git is not a plain repo directory (linked worktree or submodule)."
            exit 1
        }
        # A matching origin is the only accepted proof. An origin-less repo is not
        # "nothing contradicting us": it is the user's own unpublished work.
        $dstOrigin = ""
        try { $dstOrigin = "$(git -C $ProjectsDir remote get-url origin 2>$null)".Trim() } catch { $dstOrigin = "" }
        if (-not $dstOrigin) {
            Write-Warning "Refusing to migrate onto ${ProjectsDir}: it is a repo with no origin to identify it as the session-sync repo."
            exit 1
        }
        if ($dstOrigin -ne $expected) {
            Write-Warning "Refusing to migrate onto ${ProjectsDir}: it is an independent repo with origin $(Get-RedactedUrl $dstOrigin)."
            exit 1
        }
    }
}

if (-not (Test-Path $ProjectsDir)) { New-Item -ItemType Directory -Path $ProjectsDir -Force | Out-Null }

$_changed = $false

if (Test-Path $oldGitRoot) {
    Write-Host "Migrating git root from $ClaudeDir to $ProjectsDir..."
    if (-not (Invoke-GitRootMigration $ClaudeDir $ProjectsDir)) {
        Write-Warning "Migration failed; $ClaudeDir was left as it was."
        exit 1
    }
    # Hardening first: the restore below is a checkout, and the repo that just
    # arrived is the untrusted one, so its hooks and filters must already be
    # neutralized before git is allowed to touch the worktree.
    if (-not (Set-RepoHardening $ProjectsDir)) {
        Write-Warning "Refusing to continue: could not harden the migrated repo in $ProjectsDir."
        exit 1
    }
    # The repo moved, so its tracked files now read as deleted; restore them
    # under the old worktree root. Best-effort: an empty history has none.
    try { Restore-MissingTracked $ProjectsDir $ClaudeDir } catch { }
    $_changed = $true
}

if (-not (Test-Path (Join-Path $ProjectsDir ".git"))) {
    Write-Host "Initializing git repo in $ProjectsDir..."
    git init $ProjectsDir
    $_changed = $true
} else {
    Write-Host "Git repo already exists in $ProjectsDir." -ForegroundColor DarkGray
}
if (-not (Set-RepoHardening $ProjectsDir)) {
    Write-Warning "Refusing to continue: could not harden the repo in $ProjectsDir."
    exit 1
}

$gitattributesContent = @"
# All files under this repo are machine-generated by Claude Code
* text eol=lf
*.jsonl merge=union
"@
$_attrsPath = Join-Path $ProjectsDir ".gitattributes"
$_attrsNormalized = ($gitattributesContent -replace "`r`n", "`n") + "`n"
$_existingAttrs = if (Test-Path $_attrsPath) { [System.IO.File]::ReadAllText($_attrsPath) } else { $null }
if ($_existingAttrs -ne $_attrsNormalized) {
    [System.IO.File]::WriteAllText($_attrsPath, $_attrsNormalized)
    $_changed = $true
}

$gitignoreContent = "/workflow/*.tmp`n"
$_ignorePath = Join-Path $ProjectsDir ".gitignore"
$_existingIgnore = if (Test-Path $_ignorePath) { [System.IO.File]::ReadAllText($_ignorePath) } else { $null }
if ($_existingIgnore -ne $gitignoreContent) {
    [System.IO.File]::WriteAllText($_ignorePath, $gitignoreContent)
    $_changed = $true
}

if (-not $NoRemote) {
    $existingRemotes = git -C $ProjectsDir remote 2>$null
    if ($existingRemotes -contains "origin") {
        $currentUrl = git -C $ProjectsDir remote get-url origin 2>$null
        if ($currentUrl -ne $RemoteUrl) {
            git -C $ProjectsDir remote set-url origin $RemoteUrl
            Write-Host "Remote updated to $(Get-RedactedUrl $RemoteUrl)" -ForegroundColor Green
            $_changed = $true
        }
    } else {
        git -C $ProjectsDir remote add origin $RemoteUrl
        Write-Host "Remote set to $(Get-RedactedUrl $RemoteUrl)" -ForegroundColor Green
        $_changed = $true
    }
}

if ($_changed) {
    Write-Host "Session sync initialized." -ForegroundColor Green
} else {
    Write-Host "Session sync already up to date." -ForegroundColor DarkGray
}

exit 0
