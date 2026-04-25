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
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Add the following to your PowerShell profile:" -ForegroundColor Yellow
Write-Host "  . `"`$HOME\.agents_profile.ps1`"" -ForegroundColor Yellow
