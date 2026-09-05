# codegraph.ps1 - Reconcile CodeGraph to the state CODEGRAPH asks for (install+register / unregister)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$AgentsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# install/codegraph-constants.txt is the single source of truth for the pinned
# version and the telemetry env pair; install/linux/codegraph.sh reads the same file.
# Only the version is read here. The pair must NOT be assigned to this
# process's environment: install.ps1 invokes this script in-process, so the
# assignment would outlive it and leak the industry-wide DO_NOT_TRACK name into
# every program the caller's shell launches next — including `claude`, whose
# Remote Control refuses to start under it. Nothing here needs the pair anyway:
# `npm install --ignore-scripts` runs no upstream code, and
# codegraph-mcp.js / bin/codegraph-lifecycle.js each read the constants file
# themselves and hand the pair to their own children.
$CodegraphVersion = ""
foreach ($line in (Get-Content -Path "$AgentsRoot\install\codegraph-constants.txt")) {
    if ($line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { continue }
    if ($Matches[1] -eq "CODEGRAPH_VERSION") { $CodegraphVersion = $Matches[2] }
}

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
    & "$AgentsRoot\bin\get-config-var.ps1" -IsOff CODEGRAPH off *> $null
    if ($LASTEXITCODE -eq 1) { $_cgOn = $true }
} catch {
    $_cgOn = $false
}

if (-not $_cgOn) {
    Write-Host "CODEGRAPH is off (default)." -ForegroundColor DarkGray
    node "$AgentsRoot\install\codegraph-mcp.js" unregister
    return
}

if ([string]::IsNullOrEmpty($CodegraphVersion)) {
    Write-Warning "CODEGRAPH_VERSION missing from install/codegraph-constants.txt. CodeGraph step skipped."
    return
}

if (Get-Command npm -ErrorAction SilentlyContinue) {
    if (Get-Command codegraph -ErrorAction SilentlyContinue) {
        Write-Host "CodeGraph is already installed." -ForegroundColor DarkGray
    } else {
        Write-Host "Installing CodeGraph..."
        npm install -g --ignore-scripts "@colbymchenry/codegraph@$CodegraphVersion"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "CodeGraph installation failed (exit code: $LASTEXITCODE). Re-run to retry."
            return
        }
        Write-Host "CodeGraph installed." -ForegroundColor Green
    }
} else {
    Write-Warning "npm not found. Run: fnm install --lts"
    return
}

node "$AgentsRoot\install\codegraph-mcp.js" register
