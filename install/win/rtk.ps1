# rtk.ps1 - Install RTK (Rust Token Killer) when RTK is on; validate config with
# 'rtk config' and migrate only an invalid config via 'rtk config --create'.

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

if (Get-Command rtk -ErrorAction SilentlyContinue) {
    Write-Host "RTK is already installed." -ForegroundColor DarkGray
} else {
    Write-Host "Installing RTK..."
    winget install rtk-ai.rtk --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "RTK installation failed (exit code: $LASTEXITCODE). Re-run to retry."
        $global:LASTEXITCODE = 0
        return
    }
    Write-Host "RTK installed." -ForegroundColor Green
}

# Resolve the rtk binary after install. 'winget install' can spawn a child
# installer that returns before rtk.exe lands (installer.md "Async completion"),
# and it does not refresh this process's PATH, so Get-Command can miss it.
# Poll the WinGet candidate locations with a bounded timeout (10x, 1s).
# WinGet candidate paths — keep in sync with winCandidates in hooks/rtk-rewrite.js
$rtkExe = $null
$cmd = Get-Command rtk -ErrorAction SilentlyContinue
# Use .Source only when it resolves to a real path; aliases and shell functions
# return a non-null cmd object but have an empty .Source.
if ($cmd -and $cmd.Source) {
    $rtkExe = $cmd.Source
}
# When $rtkExe is still unset (alias/function/async-install), poll WinGet paths.
if (-not $rtkExe) {
    if ($env:LOCALAPPDATA) {
        $winCandidates = @(
            (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\rtk.exe"),
            (Join-Path $env:LOCALAPPDATA "Programs\rtk-ai\rtk\rtk.exe")
        )
        for ($i = 0; $i -lt 10; $i++) {
            foreach ($cand in $winCandidates) {
                if (Test-Path $cand) { $rtkExe = $cand; break }
            }
            if ($rtkExe) { break }
            Start-Sleep -Seconds 1
        }
    }
    if (-not $rtkExe) {
        Write-Warning "RTK binary not found after install (non-fatal)."
    }
}

# Validate config via the RTK binary; migrate only an existing-but-invalid config.
# rtk config exits 0 when the config is absent/empty (built-in defaults) or valid,
# and non-zero only when a config exists but the binary cannot parse it — the sole
# case that warrants 'rtk config --create' to migrate to RTK's current default.
if ($rtkExe) {
    try {
        $global:LASTEXITCODE = 0
        & $rtkExe config *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Existing RTK config is invalid; migrating via 'rtk config --create'..."
            $global:LASTEXITCODE = 0
            & $rtkExe config --create *> $null
            if ($LASTEXITCODE -ne 0) { Write-Warning "rtk config --create failed (non-fatal)." }
        }
    } catch {
        Write-Warning "rtk config verification failed (non-fatal)."
    }
}
# else: $rtkExe unresolved — Step 2b already emitted the not-found warning; skip verification.

# Reset exit code — all failures above are non-fatal warnings; the step must not fail.
exit 0
