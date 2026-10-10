# codegraph.ps1 - Reconcile CodeGraph to the state CODEGRAPH asks for (install+register / unregister)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$SCRIPT_CHECKOUT_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# The telemetry pair in install/codegraph-constants.txt is NOT assigned here:
# install.ps1 runs this script in-process, so DO_NOT_TRACK would leak into the
# caller's shell and stop `claude` Remote Control. codegraph-mcp.js passes it on.

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    fnm env --shell powershell | Out-String | Invoke-Expression
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warning "node not found. CodeGraph step skipped."
    return
}

# CODEGRAPH is opt-in (default off): exit 1 means explicit ON; every other exit
# (off / unset / unrecognized / internal failure) resolves to OFF.
$_cgOn = $false
try {
    $global:LASTEXITCODE = 0
    & "$SCRIPT_CHECKOUT_ROOT\bin\get-config-var.ps1" -IsOff CODEGRAPH off *> $null
    if ($LASTEXITCODE -eq 1) { $_cgOn = $true }
} catch {
    $_cgOn = $false
}

if (-not $_cgOn) {
    Write-Host "CODEGRAPH is off (default)." -ForegroundColor DarkGray
    node "$SCRIPT_CHECKOUT_ROOT\install\codegraph-mcp.js" unregister
    return
}

# Pinned to 1.6.0: 1.6.1 regressed with Windows console flicker (#2456).
# An installed binary is kept when the update fails.
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Host "Installing CodeGraph 1.6.0..."
    npm install -g --ignore-scripts "@colbymchenry/codegraph@1.6.0"
    $_npmExit = $LASTEXITCODE
    if ($_npmExit -eq 0) {
        Write-Host "CodeGraph is up to date." -ForegroundColor Green
    } elseif (Get-Command codegraph -ErrorAction SilentlyContinue) {
        Write-Warning "CodeGraph could not be updated (npm missing or failed, exit code: $_npmExit); keeping the installed version."
    } else {
        Write-Warning "CodeGraph installation failed (exit code: $_npmExit). Re-run to retry."
        return
    }
} elseif (Get-Command codegraph -ErrorAction SilentlyContinue) {
    Write-Warning "CodeGraph could not be updated (npm missing or failed); keeping the installed version."
} else {
    Write-Warning "npm not found. Run: fnm install --lts"
    return
}

node "$SCRIPT_CHECKOUT_ROOT\install\codegraph-mcp.js" register
