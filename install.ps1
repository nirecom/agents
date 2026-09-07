param(
    [switch]$Develop,
    [switch]$Full,
    [switch]$Base,      # kept for backward compat — treated as -Develop
    [switch]$Toolchain  # kept for backward compat — treated as -Develop
)

# Agents framework installer for Windows (PowerShell)
# Usage: .\install.ps1 [-Develop] [-Full]
#   -Develop : also install Codex CLI

if ($IsWindows -eq $false) {
    Write-Host "Error: install.ps1 must not run on Linux/macOS. Use install.sh instead." -ForegroundColor Red
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$AgentsRoot = $PSScriptRoot

$script:FailedSteps = @()

# Sub-scripts signal failure two ways, and neither reaches the caller on its own:
# `exit N` is not a terminating error, so $ErrorActionPreference="Stop" never sees
# it, and `throw` would abort the whole installer at the first failure. Both land
# here instead, so every remaining step still runs and the summary reports the set.
function Invoke-InstallStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )
    Write-Host ""
    Write-Host "--- $Name ---"
    $global:LASTEXITCODE = 0
    try {
        & $Path
    } catch {
        Write-Host "$Name failed: $($_.Exception.Message)" -ForegroundColor Red
        $script:FailedSteps += $Name
        return
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "$Name failed (exit code: $LASTEXITCODE)." -ForegroundColor Red
        $script:FailedSteps += $Name
    }
}

Write-Host "=== agents installer ===" -ForegroundColor Cyan

Write-Host ""
Write-Host "--- Checking Node.js (fnm) ---"
if (-not (Get-Command fnm -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Installing fnm..."
        winget install --id Schniz.fnm --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "fnm installation failed (exit code: $LASTEXITCODE)."
        }
    } else {
        Write-Warning "winget not found. Install fnm manually: https://github.com/Schniz/fnm"
    }
    Write-Host ""
    Write-Host "Restart your terminal and re-run install.ps1." -ForegroundColor Yellow
    exit 1
}

Invoke-InstallStep "Creating symlinks" "$AgentsRoot\install\win\dotfileslink.ps1"

Invoke-InstallStep "Installing Claude Code" "$AgentsRoot\install\win\claude-code.ps1"

if ($Develop -or $Full -or $Base -or $Toolchain) {
    Invoke-InstallStep "Installing Codex" "$AgentsRoot\install\win\codex.ps1"
}

# --- BEGIN session-sync gate ---
# One-time idempotent bootstrap (git init, .gitattributes/.gitignore write, remote
# add/set-url) — runs unconditionally whenever Claude Code is present, independent of
# the SESSION_SYNC toggle, which gates only *automatic* sync (see profile-snippet.ps1).
# Manual `session-sync push/pull/status/reset` depends on this bootstrap having run.
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "Claude Code not found. Session sync skipped." -ForegroundColor Yellow
} else {
    Invoke-InstallStep "Initializing Claude Code session sync" "$AgentsRoot\install\win\session-sync-init.ps1"
}
# --- END session-sync gate ---

Write-Host ""
Write-Host "--- Adding profile sourcing ---"
$_needRestart = $false
try {
    $_snippetPath = "$AgentsRoot\profile-snippet.ps1"
    $_marker = "# --- BEGIN agents profile sourcing ---"
    $_profileContent = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { "" }
    if ($_profileContent -notlike "*$_marker*") {
        if (-not (Test-Path (Split-Path $PROFILE))) { New-Item -ItemType Directory -Force (Split-Path $PROFILE) | Out-Null }
        Add-Content -Path $PROFILE -Value "`n$_marker`n. `"$_snippetPath`"`n# --- END agents profile sourcing ---"
        Write-Host "Added profile sourcing to $PROFILE" -ForegroundColor Green
        $_needRestart = $true
    } else {
        $_updated = $_profileContent -replace '(?m)^\. ".*profile-snippet\.ps1"', ". `"$_snippetPath`""
        [System.IO.File]::WriteAllText($PROFILE, $_updated)
        Write-Host "Profile sourcing already present in $PROFILE (path updated if needed)" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "Adding profile sourcing failed: $($_.Exception.Message)" -ForegroundColor Red
    $script:FailedSteps += "Adding profile sourcing"
}
Remove-Variable _snippetPath, _marker, _profileContent, _updated -ErrorAction SilentlyContinue

Invoke-InstallStep "Configuring VS Code settings (GitHub Copilot / Claude Code)" "$AgentsRoot\install\win\vscode-settings.ps1"

Invoke-InstallStep "Setting up global gitignore (WORKTREE_NOTES.md)" "$AgentsRoot\install\win\global-gitignore.ps1"

Invoke-InstallStep "Installing gh (GitHub CLI)" "$AgentsRoot\install\win\gh.ps1"

Invoke-InstallStep "Installing jq" "$AgentsRoot\install\win\jq.ps1"

Invoke-InstallStep "Installing shellcheck" "$AgentsRoot\install\win\shellcheck.ps1"

Invoke-InstallStep "Configuring CodeGraph" "$AgentsRoot\install\win\codegraph.ps1"

Write-Host ""
if ($script:FailedSteps.Count -gt 0) {
    Write-Host "=== Failed ($($script:FailedSteps.Count) step(s)) ===" -ForegroundColor Red
    foreach ($_step in $script:FailedSteps) { Write-Host "  - $_step" -ForegroundColor Red }
    Write-Host "Fix the cause and re-run install.ps1; every step is idempotent." -ForegroundColor Yellow
    exit 1
}
Write-Host "=== Done ===" -ForegroundColor Cyan
if ($_needRestart) {
    Write-Host "Restart PowerShell to apply profile changes." -ForegroundColor Yellow
}
