param(
    [switch]$Develop,
    [switch]$Full,
    [switch]$Base,      # kept for backward compat — treated as -Develop
    [switch]$Toolchain  # kept for backward compat — treated as -Develop
)

# Agents framework installer for Windows (PowerShell)
# Usage: .\install.ps1 [-Develop] [-Full]
#   -Develop : also install Codex CLI + Gemini CLI + Mermaid CLI (mmdc)

if ($IsWindows -eq $false) {
    Write-Host "Error: install.ps1 must not run on Linux/macOS. Use install.sh instead." -ForegroundColor Red
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$AgentsRoot = $PSScriptRoot

Write-Host "=== agents installer ===" -ForegroundColor Cyan

Write-Host ""
Write-Host "--- Creating symlinks ---"
& "$AgentsRoot\install\win\dotfileslink.ps1"

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

Write-Host ""
Write-Host "--- Installing Claude Code ---"
& "$AgentsRoot\install\win\claude-code.ps1"

if ($Develop -or $Full -or $Base -or $Toolchain) {
    Write-Host ""
    Write-Host "--- Installing Codex ---"
    & "$AgentsRoot\install\win\codex.ps1"

    Write-Host ""
    Write-Host "--- Installing Gemini CLI + Mermaid CLI ---"
    & "$AgentsRoot\install\win\gemini.ps1"
}

Write-Host ""
Write-Host "--- Initializing Claude Code session sync ---"
if (Get-Command claude -ErrorAction SilentlyContinue) {
    & "$AgentsRoot\install\win\session-sync-init.ps1"
} else {
    Write-Host "Claude Code not found. Session sync skipped." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "--- Adding profile sourcing ---"
$_snippetPath = "$AgentsRoot\profile-snippet.ps1"
$_marker = "# --- BEGIN agents profile sourcing ---"
$_profileContent = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { "" }
$_needRestart = $false
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
Remove-Variable _snippetPath, _marker, _profileContent, _updated -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "--- Configuring VS Code settings (GitHub Copilot / Claude Code) ---"
& "$AgentsRoot\install\win\vscode-settings.ps1"

Write-Host ""
Write-Host "--- Setting up global gitignore (WORKTREE_NOTES.md) ---"
& "$AgentsRoot\install\win\global-gitignore.ps1"

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
if ($_needRestart) {
    Write-Host "Restart PowerShell to apply profile changes." -ForegroundColor Yellow
}
