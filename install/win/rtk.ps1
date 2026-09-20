# rtk.ps1 - Install RTK (Rust Token Killer) and deploy its config when RTK is on

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$AgentsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# RTK is opt-in (default off): exit 1 means explicit ON; every other exit
# (off / unset / unrecognized / internal failure) resolves to OFF.
$_rtkOn = $false
try {
    $global:LASTEXITCODE = 0
    & "$AgentsRoot\bin\get-config-var.ps1" -IsOff RTK off *> $null
    if ($LASTEXITCODE -eq 1) { $_rtkOn = $true }
} catch {
    $_rtkOn = $false
}

if (-not $_rtkOn) {
    Write-Host "RTK is off (default)." -ForegroundColor DarkGray
    return
}

# Deploy config.toml first, before any binary check. Non-destructive/idempotent.
if (Get-Command node -ErrorAction SilentlyContinue) {
    node "$AgentsRoot\install\lib\rtk-config-deploy.js"
} else {
    Write-Warning "node not found. RTK config deploy skipped."
}

if (Get-Command rtk -ErrorAction SilentlyContinue) {
    Write-Host "RTK is already installed." -ForegroundColor DarkGray
} else {
    Write-Host "Installing RTK..."
    winget install rtk-ai.rtk --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "RTK installation failed (exit code: $LASTEXITCODE). Re-run to retry."
        return
    }
    Write-Host "RTK installed." -ForegroundColor Green
}

# Non-destructive verification: a failure is a warning, never fatal.
if (Get-Command rtk -ErrorAction SilentlyContinue) {
    try {
        rtk config *> $null
        if ($LASTEXITCODE -ne 0) { Write-Warning "rtk config verification failed (non-fatal)." }
    } catch {
        Write-Warning "rtk config verification failed (non-fatal)."
    }
}
