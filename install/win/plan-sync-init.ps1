# plan-sync-init.ps1 - install.ps1 step wrapper for bin/plan-sync-init
# Usage: Called by install.ps1 through Invoke-InstallStep (which runs a script path).
# The CLI owns every decision: an empty PLAN_SYNC_REMOTE_URL prints "not configured"
# and exits 0. Missing node skips the step; a non-zero exit is reported by the caller.
# Design: docs/architecture/claude-code/plan-sync.md.

Set-StrictMode -Version Latest

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "node not found. Plan sync skipped." -ForegroundColor Yellow
    $global:LASTEXITCODE = 0
    return
}

$cli = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "bin\plan-sync-init"
& node $cli
