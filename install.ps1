# Agents framework installer for Windows (PowerShell)
# Usage: .\install.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AgentsRoot = $PSScriptRoot

Write-Host "=== agents installer ===" -ForegroundColor Cyan

Write-Host ""
Write-Host "--- Creating symlinks ---"
& "$AgentsRoot\install\win\dotfileslink.ps1"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "--- Initializing Claude Code session sync ---"
    & "$AgentsRoot\install\win\session-sync-init.ps1"
} else {
    Write-Host "Claude Code not found. Install it and re-run to enable session sync." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "--- Adding profile sourcing ---"
$_snippetPath = "$AgentsRoot\profile-snippet.ps1"
$_marker = "# --- BEGIN agents profile sourcing ---"
$_profileContent = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { "" }
if ($_profileContent -notlike "*$_marker*") {
    if (-not (Test-Path (Split-Path $PROFILE))) { New-Item -ItemType Directory -Force (Split-Path $PROFILE) | Out-Null }
    Add-Content -Path $PROFILE -Value "`n$_marker`n. `"$_snippetPath`"`n# --- END agents profile sourcing ---"
    Write-Host "Added profile sourcing to $PROFILE" -ForegroundColor Green
} else {
    $_updated = $_profileContent -replace '(?m)^\. ".*profile-snippet\.ps1"', ". `"$_snippetPath`""
    [System.IO.File]::WriteAllText($PROFILE, $_updated)
    Write-Host "Profile sourcing already present in $PROFILE (path updated if needed)" -ForegroundColor Green
}
Remove-Variable _snippetPath, _marker, _profileContent, _updated -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Restart PowerShell to apply profile changes." -ForegroundColor Yellow
