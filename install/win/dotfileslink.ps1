# dotfileslink.ps1 - Create ~/.claude/ symlinks, set git hooksPath, write profile snippet
# Usage: Called by install.ps1, or run manually in PowerShell

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# test affordance — do not set DOTFILESLINK_HOME_OVERRIDE / DOTFILESLINK_SKIP_PRIV_CHECK / DOTFILESLINK_FAIL_AT_INDEX in production
$EffectiveHome = if ($env:DOTFILESLINK_HOME_OVERRIDE) { $env:DOTFILESLINK_HOME_OVERRIDE } else { $HOME }

$AgentsRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))

# Check Developer Mode / Admin for symlink capability
$regKey = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock -ErrorAction SilentlyContinue
$devMode = if ($regKey -and ($regKey.PSObject.Properties.Name -contains "AllowDevelopmentWithoutDevLicense")) {
    $regKey.AllowDevelopmentWithoutDevLicense
} else { $false }
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$canSymlink = $devMode -or $isAdmin

if (-not $canSymlink) {
    if (-not $env:DOTFILESLINK_SKIP_PRIV_CHECK) {
        Write-Warning "Cannot create symlinks: Developer Mode not enabled and not running as Administrator."
        exit 1
    }
}

function Write-Launcher {
    param([string]$Path, [string]$Content, [string]$Label)
    $existingItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($existingItem -and ($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $Path -Force
    }
    if ((Test-Path $Path) -and ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::ASCII) -eq $Content)) {
        Write-Host "Already generated: $Label" -ForegroundColor DarkGray
    } else {
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::ASCII)
        Write-Host "Generated: $Label" -ForegroundColor Green
    }
}

# --- ~/.claude/ symlinks ---
$ClaudeDir = "$EffectiveHome\.claude"
if (-not (Test-Path $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }

$oldCommands = "$ClaudeDir\commands"
if ((Test-Path $oldCommands) -and (Get-Item $oldCommands -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    Write-Host "Removing obsolete symlink: $oldCommands" -ForegroundColor Yellow
    Remove-Item $oldCommands -Force
}

$links = @(
    @{ Source = "CLAUDE.md";            Dest = "$ClaudeDir\CLAUDE.md";            IsDir = $false }
    @{ Source = "skills";                Dest = "$ClaudeDir\skills";               IsDir = $true }
    @{ Source = "rules";                 Dest = "$ClaudeDir\rules";                IsDir = $true }
    @{ Source = "agents";                Dest = "$ClaudeDir\agents";               IsDir = $true }
    # /wf-init alias for /workflow-init (#1743): intra-repo symlink so autocomplete
    # picks up a short name — /workflow-launch-exec (an unowned built-in) otherwise
    # wins the `/wor` completion. Not a native Skill alias field (none exists);
    # this is a second directory name resolving to the same SKILL.md.
    @{ Source = "skills\workflow-init"; Dest = "$AgentsRoot\skills\wf-init";       IsDir = $true }
)

# Transactional symlink loop. Per-link failure logged + counted; loop continues to next link.
# Symmetric to install/linux/dotfileslink.sh _link_one contract (rules/core-principles.md CPR-ORTH).
$linkFailed = 0
$_failAfterN = if ($env:DOTFILESLINK_FAIL_AT_INDEX -match '^\d+$') { [int]$env:DOTFILESLINK_FAIL_AT_INDEX } else { -1 }
$_linkIdx = 0
foreach ($link in $links) {
    $source = Join-Path $AgentsRoot $link.Source
    $dest = $link.Dest
    if (-not (Test-Path $source)) { Write-Warning "Source not found: $source (skipping)"; continue }
    $rollback = "none"   # none | restore-symlink | restore-file
    $oldTarget = $null
    $oldLinkType = $null
    $backup = "$dest.bak"
    $tmpBackup = "$dest.bak.tmp.$PID"
    $item = Get-Item $dest -Force -ErrorAction SilentlyContinue
    $oldLinkType = if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $item.LinkType } else { $null }
    if ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $target = $item.Target
            if ($target -and [System.IO.Path]::GetFullPath($target) -eq [System.IO.Path]::GetFullPath($source)) { Write-Host "Already linked: $dest" -ForegroundColor DarkGray; continue }
            Write-Host "Relinking: $dest" -ForegroundColor Yellow
            $oldTarget = $target
            $rollback = "restore-symlink"
            Remove-Item $dest -Force
        } else {
            Write-Host "Backing up: $dest -> $backup" -ForegroundColor Yellow
            Rename-Item $dest $tmpBackup
            $rollback = "restore-file"
        }
    }
    $_curIdx = $_linkIdx; $_linkIdx++
    try {
        if ($_failAfterN -ge 0 -and $_curIdx -ge $_failAfterN) {
            throw [System.IO.IOException]::new("DOTFILESLINK_FAIL_AT_INDEX=$_failAfterN test injection at index $_curIdx")
        }
        New-Item -ItemType SymbolicLink -Path $dest -Target $source -ErrorAction Stop | Out-Null
    } catch {
        switch ($rollback) {
            "restore-symlink" {
                if ($oldTarget -and $oldLinkType) {
                    try { New-Item -ItemType $oldLinkType -Path $dest -Target $oldTarget -ErrorAction SilentlyContinue | Out-Null } catch {}
                }
            }
            "restore-file" {
                try { Rename-Item $tmpBackup $dest -ErrorAction SilentlyContinue } catch {}
            }
        }
        Write-Warning "Failed to create symlink: $dest (rollback applied)"
        $linkFailed++
        continue
    }
    # New-Item succeeded — promote the new backup transactionally so the old .bak
    # survives any failure of the final Rename-Item (HIGH-2 from codex review).
    if ($rollback -eq "restore-file") {
        $oldBackup = "$backup.old.$PID"
        $hadOldBackup = Test-Path -LiteralPath $backup
        if ($hadOldBackup) { Rename-Item $backup $oldBackup -ErrorAction Stop }
        try {
            Rename-Item $tmpBackup $backup -ErrorAction Stop
            if ($hadOldBackup) { Remove-Item -Recurse -Force $oldBackup -ErrorAction SilentlyContinue }
        } catch {
            if ($hadOldBackup) { Rename-Item $oldBackup $backup -ErrorAction SilentlyContinue }
            Write-Warning "Backup promotion failed: $dest (old .bak retained at $backup)"
            $linkFailed++
            continue
        }
    }
    Write-Host "Linked: $dest -> $source" -ForegroundColor Green
}
if ($linkFailed -gt 0) {
    Write-Warning "Symlink failures: $linkFailed"
    exit 1
}
# Test affordance — see tests/feature-697-dotfileslink-link-one.Tests.ps1
if ($env:DOTFILESLINK_LINKS_ONLY -eq "1") { exit 0 }

# --- Assemble ~/.claude/settings.json from base + extension ---
# Remove stale symlink that used to point settings.json directly into agents/
$staleSettings = "$ClaudeDir\settings.json"
$staleItem = Get-Item $staleSettings -Force -ErrorAction SilentlyContinue
if ($staleItem -and ($staleItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    Remove-Item $staleSettings -Force
    Write-Host "Removed stale symlink: $staleSettings" -ForegroundColor Yellow
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "node not found. Install fnm and run: fnm install --lts"
}
& node (Join-Path $AgentsRoot "install\assemble-settings.js")
if ($LASTEXITCODE -ne 0) { throw "assemble-settings.js failed (exit $LASTEXITCODE)" }

# --- git core.hooksPath ---
$_hooksPath = "$AgentsRoot\hooks"
$_currentHooksPath = git config --file "$EffectiveHome\.gitconfig" core.hooksPath 2>$null
if ($_currentHooksPath -eq $_hooksPath) {
    Write-Host "core.hooksPath already set: $_hooksPath" -ForegroundColor DarkGray
} else {
    git config --file "$EffectiveHome\.gitconfig" core.hooksPath $_hooksPath
    Write-Host "core.hooksPath -> $_hooksPath" -ForegroundColor Green
}

# --- ~/.local/bin/doc-append.cmd launcher ---
$LocalBin = "$EffectiveHome\.local\bin"
New-Item -ItemType Directory -Force -Path $LocalBin | Out-Null
$cmdContent = @"
@echo off
set "_ARG1=%~1"
if "%~1"=="" goto nopath
if "%_ARG1:~0,1%"=="-" goto nopath
goto haspath
:nopath
uv run "$AgentsRoot\bin\doc-append.py" docs/history.md %*
goto end
:haspath
uv run "$AgentsRoot\bin\doc-append.py" %*
:end
"@
Write-Launcher "$LocalBin\doc-append.cmd" $cmdContent "doc-append.cmd"

# --- ~/.local/bin/doc-append-plain.cmd launcher ---
$dapCmdContent = "@echo off`r`nuv run `"$AgentsRoot\bin\doc-append-plain.py`" %*`r`n"
Write-Launcher "$LocalBin\doc-append-plain.cmd" $dapCmdContent "doc-append-plain.cmd"

# --- ~/.local/bin/repo-visibility.cmd launcher ---
$rvCmdContent = "@echo off`r`nuv run `"$AgentsRoot\bin\repo-visibility.py`" %*`r`n"
Write-Launcher "$LocalBin\repo-visibility.cmd" $rvCmdContent "repo-visibility.cmd"

# Convert AgentsRoot Windows path to bash-compatible Unix path
$agentsDrive = $AgentsRoot[0].ToString().ToLower()
$agentsUnixPath = "/$agentsDrive" + $AgentsRoot.Substring(2).Replace('\', '/')

# --- BEGIN temporary: cc-session-title launcher cleanup ---
# Remove stale launchers from the cc-session-title removal (PRs #303, #313, #331).
# Idempotent: Remove-Item -ErrorAction SilentlyContinue tolerates absent files.
# Safe to delete this block after all developer machines have run dotfileslink.ps1 once.
foreach ($stale in @("$LocalBin\cc-session-title", "$LocalBin\cc-session-title.cmd", "$LocalBin\cc-session-title.py")) {
    if (Test-Path -LiteralPath $stale) {
        Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
        Write-Host "Removed stale launcher: $stale" -ForegroundColor Yellow
    }
}
# --- END temporary: cc-session-title launcher cleanup ---

# --- PATH-exposed bin/ commands (cmd + bash shim) ---
# The command set is declared once in install/path-exposed-commands.txt and looped over
# here; install/linux/dotfileslink.sh consumes the same file (CPR-SSOT single source of truth,
# CPR-ORTH both platforms expose the same set). Do NOT hand-write a launcher pair below —
# add the command name to the list file instead.
# Write-Launcher registers every list entry (review-code-codex, review-env-example, ...)
# as a .cmd launcher plus a bash shim.
$PathExposedList = Join-Path $AgentsRoot "install\path-exposed-commands.txt"
$pathExposedCommands = @()
if (Test-Path -LiteralPath $PathExposedList) {
    $pathExposedCommands = @(
        Get-Content -LiteralPath $PathExposedList |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and (-not $_.StartsWith("#")) }
    )
} else {
    Write-Warning "Command list not found: $PathExposedList (skipping)"
}
foreach ($command in $pathExposedCommands) {
    $cmdContentLine = "@echo off`r`nwsl bash -c ""$command %*""`r`n"
    Write-Launcher (Join-Path $LocalBin "$command.cmd") $cmdContentLine "$command.cmd"
    $shimContent = "#!/usr/bin/env bash`nexec bash `"$agentsUnixPath/bin/$command`" `"`$@`"`n"
    Write-Launcher (Join-Path $LocalBin $command) $shimContent "$command (bash shim)"
}
