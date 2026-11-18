# npm.ps1 - Update npm itself to latest. Never fails the installer: every path exits 0.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# install.ps1 runs this in-process; a native non-zero exit must not throw (same as codex.ps1).
$PSNativeCommandUseErrorActionPreference = $false

$SCRIPT_CHECKOUT_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$_npmManual = "Run manually: npm install -g npm@latest"

function Test-DirWritable([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    $probe = Join-Path $Dir (".npm-write-probe-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType File -Path $probe -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

try {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue) -and (Get-Command fnm -ErrorAction SilentlyContinue)) {
        try { fnm env --shell powershell | Out-String | Invoke-Expression } catch { Write-Warning "fnm env failed: $($_.Exception.Message)" }
    }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Warning "npm not found. npm update skipped."
        exit 0
    }

    # Pre-check A: skip unwritable installs (e.g. Program Files managed Node).
    $_root = (& npm root -g 2>$null | Out-String).Trim()
    $_prefix = (& npm prefix -g 2>$null | Out-String).Trim()
    if (-not ($_root -and $_prefix -and (Test-DirWritable $_root) -and (Test-DirWritable (Join-Path $_root "npm")) -and (Test-DirWritable $_prefix))) {
        Write-Warning "npm global location is not writable; skipping update. $_npmManual"
        exit 0
    }

    # Pre-check B: the incoming npm must support the current Node.
    $global:LASTEXITCODE = 0
    $_range = (& npm view npm@latest engines.node 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not read the latest npm requirements; skipping update. $_npmManual"
        exit 0
    }
    & node "$SCRIPT_CHECKOUT_ROOT\install\lib\npm-engine-check.js" $_range
    if ($LASTEXITCODE -eq 1) {
        Write-Warning "Latest npm does not support the current Node ($_range); skipping update. $_npmManual"
        exit 0
    } elseif ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not verify npm/Node compatibility; skipping update. $_npmManual"
        exit 0
    }

    Write-Host "Updating npm (latest)..."
    & npm install -g npm@latest
    if ($LASTEXITCODE -eq 0) {
        Write-Host "npm is up to date." -ForegroundColor Green
    } else {
        Write-Warning "npm update failed (exit code: $LASTEXITCODE); keeping the installed version. $_npmManual"
    }
} catch {
    Write-Warning "npm update skipped: $($_.Exception.Message). $_npmManual"
}
exit 0
